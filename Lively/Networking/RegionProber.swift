import Foundation

/// Picks the Soniox region with the shortest round trip from this network.
///
/// Soniox regions are separate projects, and a temporary key works only in
/// its own region, so the broker mints keys for whichever region the app asks
/// for. This measures each region the broker offers and keeps the best one in
/// `choice`. A change applies to the next connection only; a healthy socket is
/// never torn down to move it.
///
/// A probe is three unauthenticated `GET https://stt-rt.<region>.soniox.com/`
/// on one connection. Each returns a 404 from the regional origin through
/// Cloudflare, the same path audio takes. The first request pays for the TCP
/// and TLS handshakes, so the RTT is the faster of the other two. Probes are
/// free and use no key. See `Tools/probe/ASIA_LATENCY.md` §6.2.
final class RegionProber {
    /// The region to ask the broker for. Nil until the broker has listed its
    /// regions; the broker then picks one from the caller's country.
    private(set) var choice: String? {
        didSet {
            guard choice != oldValue else { return }
            defaults.set(choice, forKey: Self.choiceKey)
            onChoiceChange()
        }
    }

    var onChoiceChange: () -> Void = {}

    private struct Stats {
        /// Smoothed RTT in milliseconds. Nil until a probe succeeds.
        var rtt: Double?
        /// Smoothed share of probes and connects that failed, 0...1.
        var failureRate = 0.0
        var connectFailuresInARow = 0

        var score: Double? { rtt.map { $0 + RegionProber.failurePenaltyMs * failureRate } }

        mutating func record(success: Bool) {
            failureRate = failureRate * (1 - RegionProber.smoothing) + (success ? 0 : RegionProber.smoothing)
        }
    }

    private static let smoothing = 0.3
    /// What a region that always fails costs, in ms of RTT.
    private static let failurePenaltyMs = 500.0
    /// Switch only to a region at least this much better, so close regions don't flap.
    private static let minimumGain = 0.25
    private static let minimumGainMs = 40.0
    private static let connectFailuresBeforeFallback = 2
    private static let listeningInterval: Duration = .seconds(600)
    private static let choiceKey = "sonioxRegion"
    private static let regionsKey = "sonioxRegions"

    private let defaults: UserDefaults
    /// Region → WebSocket URL, as last listed by the broker.
    private var regions: [String: URL]
    private var stats: [String: Stats] = [:]
    private var probing: Task<Void, Never>?
    private var lastProbe: Date?
    private var periodic: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.regionsKey) as? [String: String] ?? [:]
        regions = stored.compactMapValues(URL.init(string:))
        choice = defaults.string(forKey: Self.choiceKey).flatMap { stored[$0] == nil ? nil : $0 }
    }

    /// Takes the regions the broker offers, from each key it hands out.
    func update(regions offered: [String: URL]) {
        guard !offered.isEmpty, offered != regions else { return }
        regions = offered
        defaults.set(offered.mapValues(\.absoluteString), forKey: Self.regionsKey)
        stats = stats.filter { offered[$0.key] != nil }
        if let choice, offered[choice] == nil { self.choice = nil }
        probe(minimumInterval: 0)
    }

    /// Measures every region, unless a probe is running or one finished
    /// within `minimumInterval` seconds.
    func probe(minimumInterval: TimeInterval = 60) {
        guard probing == nil, regions.count > 0 else { return }
        if let lastProbe, Date.now.timeIntervalSince(lastProbe) < minimumInterval { return }
        let targets = regions
        probing = Task { [weak self] in
            let results = await withTaskGroup(of: (String, Double?).self) { group in
                for (region, url) in targets {
                    group.addTask { (region, await Self.measure(url)) }
                }
                var results: [(String, Double?)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard let self else { return }
            for (region, rtt) in results where self.regions[region] != nil {
                var entry = self.stats[region] ?? Stats()
                if let rtt {
                    entry.rtt = entry.rtt.map { $0 * (1 - Self.smoothing) + rtt * Self.smoothing } ?? rtt
                }
                entry.record(success: rtt != nil)
                self.stats[region] = entry
            }
            self.lastProbe = .now
            self.probing = nil
            self.choose()
        }
    }

    /// Probes every ~10 min while listening. Never on a timer otherwise.
    func startPeriodicProbing() {
        periodic?.cancel()
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.listeningInterval)
                guard !Task.isCancelled else { return }
                self?.probe(minimumInterval: 0)
            }
        }
    }

    func stopPeriodicProbing() {
        periodic?.cancel()
        periodic = nil
    }

    func connectSucceeded(region: String) {
        stats[region, default: Stats()].connectFailuresInARow = 0
        stats[region]?.record(success: true)
    }

    /// After a couple of failed connects in a row, moves to the next-best
    /// region right away and probes again.
    func connectFailed(region: String) {
        var entry = stats[region] ?? Stats()
        entry.record(success: false)
        entry.connectFailuresInARow += 1
        let fallBack = entry.connectFailuresInARow >= Self.connectFailuresBeforeFallback
        if fallBack { entry.connectFailuresInARow = 0 }
        stats[region] = entry
        guard fallBack else { return }

        let others = regions.keys.filter { $0 != region }
        if let next = others.min(by: { (stats[$0]?.score ?? .infinity) < (stats[$1]?.score ?? .infinity) }) {
            choice = next
        }
        probe(minimumInterval: 0)
    }

    private func choose() {
        let scored = regions.keys.compactMap { region in stats[region]?.score.map { (region, $0) } }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else { return }
        guard let current = choice, let currentScore = stats[current]?.score else {
            choice = best.0
            return
        }
        let gain = currentScore - best.1
        if best.0 != current, gain >= currentScore * Self.minimumGain, gain >= Self.minimumGainMs {
            choice = best.0
        }
    }

    /// The region's RTT in ms, or nil if it couldn't be reached.
    private static func measure(_ websocketURL: URL) async -> Double? {
        guard let host = websocketURL.host(), let url = URL(string: "https://\(host)/") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var samples: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<3 {
            let started = clock.now
            // Any HTTP response counts; the origin answers `/` with a 404.
            guard (try? await session.data(from: url)) != nil else { return nil }
            let elapsed = clock.now - started
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return samples.dropFirst().min()
    }
}
