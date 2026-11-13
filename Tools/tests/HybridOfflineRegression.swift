import Foundation

struct Language: Sendable {}

final class FakeSpeechEngine: SpeechEngine {
    var onEvent: (SpeechEvent) -> Void = { _ in }
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    var networkAvailable = true
    var starts = 0
    var stops = 0
    var chunks: [Data] = []
    var startStatus: SpeechEngineStatus?

    func start() {
        starts += 1
        if let startStatus { onStatus(startStatus) }
    }
    func stop() { stops += 1; onStatus(.idle) }
    func send(_ chunk: Data) { chunks.append(chunk) }
}

@main struct HybridOfflineRegression {
    static var failures = 0
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures += 1; print("FAIL: " + message) }
    }

    static func main() {
        let local = FakeSpeechEngine()
        let cloud = FakeSpeechEngine()
        let hybrid = HybridSpeechEngine(local: local, cloud: cloud)
        var events: [String] = []
        var statuses: [SpeechEngineStatus] = []
        var sources: [String] = []
        hybrid.onEvent = {
            switch $0 {
            case .text(let text): events.append(text)
            case .sessionReset: events.append("reset")
            default: break
            }
        }
        hybrid.onStatus = { statuses.append($0) }
        hybrid.onSourceChange = { source, _ in
            switch source { case .local: sources.append("local"); case .cloud: sources.append("cloud") }
        }
        hybrid.start()
        check(local.starts == 1 && cloud.starts == 1, "online startup starts both engines")
        local.onStatus(.live)
        check(statuses.last == .live, "local readiness makes stopgap live")
        let initial = Data(repeating: 1, count: 2560)
        hybrid.send(initial)
        local.onEvent(.text("local"))
        check(local.chunks == [initial] && cloud.chunks.isEmpty, "stopgap receives startup audio alone")
        check(events.last == "local", "local transcript is forwarded before handoff")
        cloud.onStatus(.live)
        check(sources == ["cloud"] && local.stops == 1, "cloud readiness hands off once")
        check(cloud.chunks == [initial], "startup audio is replayed to cloud")
        local.onEvent(.text("stale-local"))
        check(events.last == "reset", "stopped local engine cannot emit into cloud turn")

        hybrid.networkAvailable = false
        check(sources.last == "local" && local.starts == 2, "known network loss immediately starts local recognition")
        check(cloud.stops == 1, "known network loss stops the cloud session")
        check(!cloud.networkAvailable, "network availability reaches cloud engine")
        local.onStatus(.live)
        let offline = Data(repeating: 2, count: 2560)
        hybrid.send(offline)
        check(local.chunks == [initial, offline], "offline audio reaches local recognition")
        check(cloud.chunks == [initial], "offline audio is not sent to cloud")
        let stoppedLocal = local.stops
        let sourceCount = sources.count
        cloud.onStatus(.live)
        cloud.onEvent(.text("late-cloud"))
        check(local.stops == stoppedLocal && sources.count == sourceCount, "late cloud readiness cannot replace offline recognition")
        check(events.last != "late-cloud", "late cloud transcript is ignored while offline")
        local.onEvent(.text("offline-local"))
        check(events.last == "offline-local", "offline local transcript remains visible")
        hybrid.networkAvailable = false
        check(cloud.stops == 1 && local.starts == 2, "repeated unavailable path does not churn engines")

        hybrid.networkAvailable = true
        check(cloud.starts == 2, "restored network starts a fresh cloud session")
        cloud.onStatus(.live)
        check(sources.last == "cloud" && cloud.chunks == [initial, offline], "reconnected cloud receives the buffered local window once")
        let countBeforeStop = events.count
        hybrid.stop()
        local.onEvent(.text("after-stop"))
        cloud.onEvent(.text("after-stop"))
        check(events.count == countBeforeStop, "stopped hybrid ignores both engines")
        let startsBeforePath = cloud.starts
        hybrid.networkAvailable = false
        hybrid.networkAvailable = true
        check(cloud.starts == startsBeforePath, "path updates do not restart stopped hybrid")

        let offlineLocal = FakeSpeechEngine()
        let offlineCloud = FakeSpeechEngine()
        let offlineStart = HybridSpeechEngine(local: offlineLocal, cloud: offlineCloud)
        offlineStart.networkAvailable = false
        offlineStart.start()
        check(offlineLocal.starts == 1 && offlineCloud.starts == 0, "cold offline startup never starts cloud")
        var offlineStatus: SpeechEngineStatus?
        offlineStart.onStatus = { offlineStatus = $0 }
        offlineLocal.onStatus(.failed("Download languages first"))
        check(offlineStatus == .failed("Download languages first"), "missing models fail without waiting for a nonexistent cloud connection")
        offlineStart.stop()

        let synchronousLocal = FakeSpeechEngine()
        let synchronousCloud = FakeSpeechEngine()
        synchronousLocal.startStatus = .live
        let synchronous = HybridSpeechEngine(local: synchronousLocal, cloud: synchronousCloud)
        var synchronousStatus: SpeechEngineStatus?
        synchronous.onStatus = { synchronousStatus = $0 }
        synchronous.start()
        synchronousCloud.onStatus(.live)
        synchronous.networkAvailable = false
        check(synchronousStatus == .live, "synchronous local readiness is not overwritten by connecting")
        synchronous.stop()

        let retryLocal = FakeSpeechEngine()
        let retryCloud = FakeSpeechEngine()
        retryLocal.startStatus = .failed("Temporarily unavailable")
        retryCloud.startStatus = .live
        let retry = HybridSpeechEngine(local: retryLocal, cloud: retryCloud)
        var retryStatus: SpeechEngineStatus?
        retry.onStatus = { retryStatus = $0 }
        retry.start()
        check(retryStatus == .live, "cloud can recover from initial local failure")
        retryLocal.startStatus = .connecting
        retry.networkAvailable = false
        check(retryLocal.starts == 2 && retryStatus == .connecting,
              "new local attempt is not failed by the previous attempt's state")
        retryLocal.onStatus(.live)
        check(retryStatus == .live, "restarted local recognition becomes live")
        retry.stop()

        let cancelledLocal = FakeSpeechEngine()
        let cancelledCloud = FakeSpeechEngine()
        let cancelled = HybridSpeechEngine(local: cancelledLocal, cloud: cancelledCloud)
        cancelled.onStatus = { if $0 == .connecting { cancelled.stop() } }
        cancelled.start()
        check(cancelledLocal.starts == 0 && cancelledCloud.starts == 0, "synchronous stop during startup prevents both starts")

        print("Hybrid offline regression: \(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
