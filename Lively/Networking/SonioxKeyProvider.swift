import Foundation

/// Gets short-lived, single-use Soniox keys from Lively's key broker
/// (`Server/key-broker`), so the app never holds a long-lived key.
///
/// One spare key is kept ready while listening, so a reconnect on a flaky
/// network never waits on the broker. Keys live 5 min and the spare is
/// replaced after 4, so it outlasts minutes of broker trouble.
/// The broker identifies this install by a random ID kept in the Keychain and
/// rate-limits by it, by the account when signed in (`Account`), or by the
/// subscription with Lively Pro (`Pro`).
///
/// Keys are region-scoped: each works only on its own region's WebSocket
/// host, which comes with it. `regions` picks the region to ask for, and the
/// spare is dropped when that changes.
final class SonioxKeyProvider {
    /// Nil when the build has no `LivelyKeyBrokerURL`, so Soniox needs a key
    /// entered in Settings.
    static let shared: SonioxKeyProvider? = brokerURL.map { SonioxKeyProvider(brokerURL: $0) }

    static var brokerURL: URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "LivelyKeyBrokerURL") as? String,
              !string.isEmpty else { return nil }
        return URL(string: string)
    }

    /// A key and where to use it.
    struct Key {
        let value: String
        let region: String
        let websocketURL: URL
    }

    private struct TemporaryKey {
        let key: Key
        /// The region asked for, or nil to let the broker pick. The broker
        /// may hand out another region if it can't mint in this one.
        let requestedRegion: String?
        let fetchedAt: Date
        let expiresAt: Date

        /// Soniox needs the key only to open the socket, so a few seconds is enough.
        var isFresh: Bool { expiresAt.timeIntervalSinceNow > 5 }

        /// Four fifths of the way through its life: 240 s for a 300 s key,
        /// leaving a minute for a broker hiccup to clear.
        var refreshAt: Date {
            fetchedAt.addingTimeInterval(expiresAt.timeIntervalSince(fetchedAt) * 0.8)
        }
    }

    /// For a broker that doesn't send `websocket_url` yet.
    private static let usWebsocketURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    let regions = RegionProber()

    private let endpoint: URL
    private let session: URLSession
    private var spare: TemporaryKey?
    /// The fetch filling `spare`, shared by everyone waiting on it.
    private var filling: Task<Void, Error>?
    private var refreshTask: Task<Void, Never>?

    private init(brokerURL: URL) {
        endpoint = brokerURL.appending(path: "v1/soniox/key")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
        regions.onChoiceChange = { [weak self] in
            guard let self else { return }
            // A spare minted for the old region won't work in the new one.
            let hadSpare = self.spare != nil
            self.spare = nil
            if self.refreshTask != nil || hadSpare { Task { try? await self.fillSpare() } }
        }
    }

    /// Keeps a fresh spare key while listening.
    func startRefreshing() {
        regions.startPeriodicProbing()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let due = self.spare?.refreshAt ?? .now
                if due > .now {
                    try? await Task.sleep(for: .seconds(due.timeIntervalSinceNow))
                    continue
                }
                do {
                    try await self.fillSpare()
                } catch {
                    // The spare stays if it's still fresh; `takeKey` reports errors.
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    /// Fetches a spare ahead of the first connect, unless one is on hand with
    /// a minute or more to live. Each key counts against the daily allowance,
    /// so this runs when the app comes forward, never on a timer.
    func prefetch() {
        if let spare, spare.requestedRegion == regions.choice, spare.expiresAt.timeIntervalSinceNow > 60 { return }
        Task { try? await fillSpare() }
    }

    /// Forgets the spare, for when the plan changes: its session limit is the old plan's.
    func dropSpare() {
        guard spare != nil else { return }
        spare = nil
        if refreshTask != nil { Task { try? await fillSpare() } }
    }

    func stopRefreshing() {
        regions.stopPeriodicProbing()
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// A key for one connection. Keys are single-use, so each call returns a
    /// different one and starts fetching the next spare.
    func takeKey() async throws -> Key {
        for _ in 0..<3 {
            if let key = spare, key.isFresh, key.requestedRegion == regions.choice {
                spare = nil
                Task { try? await fillSpare() }
                return key.key
            }
            // Another caller can take the key this fill brings, so check again.
            try await fillSpare()
        }
        throw URLError(.cannotLoadFromNetwork)
    }

    private func fillSpare() async throws {
        if let filling { return try await filling.value }
        let task = Task {
            defer { filling = nil }
            spare = try await requestKey()
        }
        filling = task
        try await task.value
    }

    private func requestKey() async throws -> TemporaryKey {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(Self.installID, forHTTPHeaderField: "Lively-Install-ID")
        let requestedRegion = regions.choice
        if let requestedRegion { request.setValue(requestedRegion, forHTTPHeaderField: "Lively-Region") }
        let token = Account.shared?.token
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let subscription = Pro.shared.signedTransaction {
            request.setValue(subscription, forHTTPHeaderField: "Lively-Subscription")
        }

        let started = Date.now
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        // A signed-out or expired session: drop it and ask again anonymously.
        if http.statusCode == 401, let token {
            Account.shared?.tokenWasRejected(token)
            return try await requestKey()
        }

        guard http.statusCode == 200 else {
            let brokerError = try? JSONDecoder().decode(BrokerError.self, from: data)
            let message = brokerError?.message
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
            switch http.statusCode {
            // A per-minute limit clears quickly; reconnecting with backoff gets past it.
            case 429 where retryAfter <= 60: throw URLError(.resourceUnavailable)
            case 429 where brokerError?.plan == "free":
                Pro.shared.freeLimitReached = true
                throw SocketSetupError.fail(message ?? "Today's free translation time is used up.")
            case 400, 403, 429, 503:
                throw SocketSetupError.fail(message ?? "Lively's key service turned down the request.")
            default: throw URLError(.badServerResponse)
            }
        }

        let body = try JSONDecoder().decode(BrokerKey.self, from: data)
        regions.update(regions: (body.regions ?? [:]).compactMapValues(URL.init(string:)))
        // Time the key by this device's clock, from when it was requested.
        return TemporaryKey(
            key: Key(
                value: body.api_key,
                region: body.region ?? "us",
                websocketURL: body.websocket_url.flatMap(URL.init(string:)) ?? Self.usWebsocketURL
            ),
            requestedRegion: requestedRegion,
            fetchedAt: started,
            expiresAt: started.addingTimeInterval(TimeInterval(body.expires_in_seconds))
        )
    }

    /// A random ID for this install. It names no person or device, and the
    /// broker only sees a hash of it. `BrokerTranslator` sends it too.
    static let installID: String = {
        let account = "lively-install-id"
        if let id = Keychain.read(account: account) { return id }
        let id = UUID().uuidString
        Keychain.write(id, account: account)
        return id
    }()

    private struct BrokerKey: Decodable {
        let api_key: String
        let expires_in_seconds: Int
        let region: String?
        let websocket_url: String?
        /// Every region the broker can mint in, with its WebSocket URL.
        let regions: [String: String]?
    }

    private struct BrokerError: Decodable {
        let message: String
        /// On a daily limit: "free" or "pro".
        let plan: String?
    }
}
