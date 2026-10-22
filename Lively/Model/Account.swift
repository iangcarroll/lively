import Foundation
import Observation

/// Optional sign-in with an emailed code, through Lively's key broker
/// (`Server/key-broker/src/auth.ts`). A signed-in app sends its session token
/// with key requests and gets a per-account listening budget instead of the
/// per-install one.
///
/// The token and email are kept in the Keychain. Some accounts get Lively Pro
/// for free (`hasFreePro`); the broker sets that, and the app reads it back
/// at sign-in and at launch.
@Observable
final class Account {
    /// Nil when the build has no `LivelyKeyBrokerURL`.
    static let shared: Account? = SonioxKeyProvider.brokerURL.map { Account(brokerURL: $0) }

    private(set) var email: String?
    @ObservationIgnored private(set) var token: String?
    private(set) var hasFreePro: Bool {
        didSet { UserDefaults.standard.set(hasFreePro, forKey: Self.freeProKey) }
    }

    var isSignedIn: Bool { email != nil }

    private let brokerURL: URL
    private let session: URLSession

    private static let tokenAccount = "lively-session-token"
    private static let emailAccount = "lively-account-email"
    private static let freeProKey = "LivelyAccountFreePro"

    private init(brokerURL: URL) {
        self.brokerURL = brokerURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
        token = Keychain.read(account: Self.tokenAccount)
        email = token == nil ? nil : Keychain.read(account: Self.emailAccount)
        hasFreePro = token != nil && UserDefaults.standard.bool(forKey: Self.freeProKey)
    }

    /// Demo mode (`-LivelyDemo YES`) never reaches the broker: any email
    /// gets a code, and the code is 123456.
    private var isDemo: Bool { UserDefaults.standard.bool(forKey: "LivelyDemo") }

    /// Emails a 6-digit code to `email`.
    func sendCode(to email: String) async throws {
        if isDemo {
            try await Task.sleep(for: .milliseconds(600))
            return
        }
        _ = try await post("v1/auth/email/start", ["email": email], as: Empty.self)
    }

    func signIn(email: String, code: String) async throws {
        if isDemo {
            try await Task.sleep(for: .milliseconds(600))
            guard code == "123456" else { throw AccountError(message: "That code didn't work. Try again.") }
            self.email = email
            return
        }
        let body = try await post("v1/auth/email/verify", ["email": email, "code": code], as: SignedIn.self)
        Keychain.write(body.token, account: Self.tokenAccount)
        Keychain.write(body.user.email, account: Self.emailAccount)
        token = body.token
        self.email = body.user.email
        setFreePro(body.user.free_pro ?? false)
    }

    /// Rereads the account from the broker, which may have granted or taken
    /// away free Pro. Signs out if the session has ended.
    func refresh() async {
        guard let token, !isDemo else { return }
        var request = URLRequest(url: brokerURL.appending(path: "v1/auth/me"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 {
            tokenWasRejected(token)
        } else if http.statusCode == 200, let body = try? JSONDecoder().decode(Me.self, from: data) {
            setFreePro(body.user.free_pro ?? false)
        }
    }

    /// Deletes the account on the broker, then signs out here.
    func deleteAccount() async throws {
        if let token, !isDemo {
            var request = URLRequest(url: brokerURL.appending(path: "v1/auth/delete"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            // 401: the session, and so maybe the account, is already gone.
            guard http.statusCode == 200 || http.statusCode == 401 else {
                let message = (try? JSONDecoder().decode(BrokerError.self, from: data))?.message
                throw AccountError(message: message ?? "Couldn't delete your account. Try again.")
            }
        }
        forget()
    }

    private func setFreePro(_ value: Bool) {
        guard value != hasFreePro else { return }
        hasFreePro = value
        SonioxKeyProvider.shared?.dropSpare()
    }

    func signOut() {
        if let token {
            var request = URLRequest(url: brokerURL.appending(path: "v1/auth/logout"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            Task { [session] in _ = try? await session.data(for: request) }
        }
        forget()
    }

    /// The broker no longer accepts the token, so sign out locally.
    func tokenWasRejected(_ rejected: String) {
        guard token == rejected else { return }
        forget()
    }

    private func forget() {
        Keychain.write(nil, account: Self.tokenAccount)
        Keychain.write(nil, account: Self.emailAccount)
        token = nil
        email = nil
        setFreePro(false)
    }

    private func post<Response: Decodable>(_ path: String, _ body: [String: String], as: Response.Type) async throws -> Response {
        var request = URLRequest(url: brokerURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(BrokerError.self, from: data))?.message
            throw AccountError(message: message ?? "Something went wrong. Try again.")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    struct AccountError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Empty: Decodable {}

    private struct User: Decodable {
        let email: String
        /// Missing from brokers older than Lively Pro.
        let free_pro: Bool?
    }

    private struct SignedIn: Decodable {
        let token: String
        let user: User
    }

    private struct Me: Decodable {
        let user: User
    }

    private struct BrokerError: Decodable {
        let message: String
    }
}
