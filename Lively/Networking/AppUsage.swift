import Foundation

/// Installation-local daily totals. Save each transition before trying the network:
/// an app can be suspended during the close request, then replay it on its next open.
@MainActor
final class AppUsage {
    static let shared = makeShared()

    private static func makeShared() -> AppUsage? {
        #if DEBUG
        return nil
        #else
        guard let broker = SonioxKeyProvider.brokerURL, !UserDefaults.standard.bool(forKey: "LivelyDemo") else { return nil }
        let session = URLSession(configuration: .ephemeral)
        return AppUsage(directory: URL.applicationSupportDirectory.appending(path: "AppUsage"), broker: broker) { request in
            let (_, response) = try await session.data(for: request, delegate: nil)
            return (response as? HTTPURLResponse)?.statusCode == 204
        }
        #endif
    }

    struct Day: Codable, Equatable {
        let day: Int
        var opens = 0
        var closes = 0
        var seconds = 0
    }

    private struct Store: Codable {
        var id = UUID()
        var days: [Int: Day] = [:]
        var pending: Set<Int> = []
    }

    private struct Batch: Encodable {
        let platform: String
        let days: [Day]
    }

    private let directory: URL
    private let broker: URL
    private let send: (URLRequest) async throws -> Bool
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private var cached: Store?
    private var started: TimeInterval?
    private var timer: Task<Void, Never>?
    private var syncing = false

    init(directory: URL, broker: URL, now: @escaping () -> Date = { .now },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         send: @escaping (URLRequest) async throws -> Bool) {
        self.directory = directory
        self.broker = broker
        self.now = now
        self.uptime = uptime
        self.send = send
    }

    func foreground(_ active: Bool) {
        guard active != (started != nil) else { return }
        let timestamp = uptime()
        let elapsed = started.map { max(0, Int(timestamp - $0)) }
        started = active ? timestamp : nil
        record { day in
            if let elapsed {
                day.closes += 1
                day.seconds += min(elapsed, 30 * 86_400)
            } else {
                day.opens += 1
            }
        }

        timer?.cancel()
        if active {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self else { return }
                    self.tick()
                }
            }
        }
        Task { await sync() }
    }

    // A session can span UTC midnight without another lifecycle transition.
    func tick() {
        guard started != nil else { return }
        record { _ in }
        Task { await sync() }
    }

    private var file: URL { directory.appending(path: "days.json") }

    private func read() throws -> Store {
        if let cached { return cached }
        let store: Store
        do {
            store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            var folder = directory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            store = Store()
        }
        cached = store
        return store
    }

    private func save(_ store: Store) throws {
        try JSONEncoder().encode(store).write(to: file, options: .atomic)
        cached = store
    }

    private func record(_ update: (inout Day) -> Void) {
        guard var store = try? read() else { return }
        let today = Int(now().timeIntervalSince1970 / 86_400)
        var row = store.days[today] ?? Day(day: today)
        update(&row)
        guard store.days[today] != row else { return }
        store.days = store.days.filter { (today - 29...today).contains($0.key) }
        store.days[today] = row
        store.pending.formIntersection(store.days.keys)
        store.pending.insert(today)
        try? save(store)
    }

    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif
        do {
            while true {
                let store = try read()
                let days = store.pending.sorted().compactMap { store.days[$0] }
                guard !days.isEmpty else { return }
                var request = URLRequest(url: broker.appending(path: "v1/app-usage"))
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(store.id.uuidString, forHTTPHeaderField: "Lively-Usage-ID")
                request.httpBody = try JSONEncoder().encode(Batch(platform: platform, days: days))
                guard try await send(request) else { return }
                // A close or the next open may have arrived during the upload.
                var latest = try read()
                guard latest.id == store.id else { return }
                for row in days where latest.days[row.day] == row { latest.pending.remove(row.day) }
                try save(latest)
            }
        } catch { /* Leave pending totals on disk for the next foreground retry. */ }
    }
}
