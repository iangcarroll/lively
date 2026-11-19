#if os(iOS)
import AdServices
import Foundation
import StoreKit

/// An install-scoped purchase reference, independent of Lively accounts and usage limits.
final class AppleAdsAttribution {
    static let shared = AppleAdsAttribution(
        directory: URL.applicationSupportDirectory.appending(path: "AppleAds", directoryHint: .isDirectory)
    )

    private struct Install: Codable {
        let id: UUID
        var attributed: Bool?
    }

    private let directory: URL
    private var collecting = false

    init(directory: URL) { self.directory = directory }

    private var file: URL { directory.appending(path: "install.json") }

    private func install() throws -> Install {
        if FileManager.default.fileExists(atPath: file.path) {
            return try JSONDecoder().decode(Install.self, from: Data(contentsOf: file))
        }
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A backup restored on another device should start a separate install.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let install = Install(id: UUID(), attributed: nil)
        try save(install)
        return install
    }

    private func save(_ install: Install) throws {
        try JSONEncoder().encode(install).write(to: file, options: .atomic)
    }

    /// A checkout can finish before attribution does. Apple's signed original
    /// transaction will still carry the same UUID when its notification arrives.
    var purchaseOptions: Set<Product.PurchaseOption> {
        guard let install = try? install(), install.attributed != false else { return [] }
        return [.appAccountToken(install.id)]
    }

    func collect() async {
        guard let broker = SonioxKeyProvider.brokerURL else { return }
        await collect(broker: broker, token: {
            guard case .verified(let app) = try await AppTransaction.shared, app.environment == .production else {
                throw CancellationError()
            }
            return try await Task.detached(priority: .utility) { try AAAttribution.attributionToken() }.value
        }, send: { try await URLSession.shared.data(for: $0) })
    }

    func collect(broker: URL, token: () async throws -> String,
                 send: (URLRequest) async throws -> (Data, URLResponse),
                 sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        guard !collecting, var install = try? install(), install.attributed == nil else { return }
        collecting = true
        defer { collecting = false }
        struct Result: Decodable { let attributed: Bool }
        do {
            var request = URLRequest(url: broker.appending(path: "v1/apple-ads/attribution"))
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            request.setValue(install.id.uuidString, forHTTPHeaderField: "Lively-Attribution-ID")
            request.httpBody = Data(try await token().utf8)
            for attempt in 1...3 {
                try Task.checkCancellation()
                let (data, response) = try await send(request)
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 200 {
                    install.attributed = try JSONDecoder().decode(Result.self, from: data).attributed
                    try save(install)
                    return
                }
                guard attempt < 3, http.statusCode == 503,
                      http.value(forHTTPHeaderField: "Retry-After") == "5" else { return }
                try await sleep(.seconds(5))
            }
        } catch {
            // An unfinished lookup retries with a fresh token on the next foreground.
        }
    }
}
#endif
