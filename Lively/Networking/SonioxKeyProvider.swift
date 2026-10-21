import Foundation

/// Gets short-lived, single-use Soniox keys from Lively's key broker
/// (`Server/key-broker`), so the app never holds a long-lived key.
///
/// One spare key is kept ready and replaced about every 50 s while
/// listening, so a reconnect on a flaky network never waits on the broker.
/// The broker identifies this install by a random ID kept in the Keychain and
/// rate-limits by it.
final class SonioxKeyProvider {
    /// Nil when the build has no `LivelyKeyBrokerURL`, so Soniox needs a key
    /// entered in Settings.
    static let shared: SonioxKeyProvider? = brokerURL.map { SonioxKeyProvider(brokerURL: $0) }

    private static var brokerURL: URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "LivelyKeyBrokerURL") as? String,
              !string.isEmpty else { return nil }
        return URL(string: string)
    }

    private struct TemporaryKey {
        let value: String
        let fetchedAt: Date
        let expiresAt: Date

        /// Soniox needs the key only to open the socket, so a few seconds is enough.
        var isFresh: Bool { expiresAt.timeIntervalSinceNow > 5 }
    }

    private static let refreshInterval: TimeInterval = 50

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
    }

    /// Keeps a fresh spare key while listening.
    func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let due = self.spare.map { $0.fetchedAt.addingTimeInterval(Self.refreshInterval) } ?? .now
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

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// A key for one connection. Keys are single-use, so each call returns a
    /// different one and starts fetching the next spare.
    func takeKey() async throws -> String {
        for _ in 0..<3 {
            if let key = spare, key.isFresh {
                spare = nil
                Task { try? await fillSpare() }
                return key.value
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

        let started = Date.now
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(BrokerError.self, from: data))?.message
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
            switch http.statusCode {
            // A per-minute limit clears quickly; reconnecting with backoff gets past it.
            case 429 where retryAfter <= 60: throw URLError(.resourceUnavailable)
            case 400, 403, 429, 503:
                throw SocketSetupError.fail(message ?? "Lively's key service turned down the request.")
            default: throw URLError(.badServerResponse)
            }
        }

        let body = try JSONDecoder().decode(BrokerKey.self, from: data)
        // Time the key by this device's clock, from when it was requested.
        return TemporaryKey(
            value: body.api_key,
            fetchedAt: started,
            expiresAt: started.addingTimeInterval(TimeInterval(body.expires_in_seconds))
        )
    }

    /// A random ID for this install. It names no person or device, and the
    /// broker only sees a hash of it.
    private static let installID: String = {
        let account = "lively-install-id"
        if let id = Keychain.read(account: account) { return id }
        let id = UUID().uuidString
        Keychain.write(id, account: account)
        return id
    }()

    private struct BrokerKey: Decodable {
        let api_key: String
        let expires_in_seconds: Int
    }

    private struct BrokerError: Decodable {
        let message: String
    }
}
