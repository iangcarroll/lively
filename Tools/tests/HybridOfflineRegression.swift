import Foundation

struct Language: Equatable, Sendable {}

final class FakeSpeechEngine: SpeechEngine {
    var onEvent: (SpeechEvent) -> Void = { _ in }
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    var networkAvailable = true {
        didSet {
            if networkAvailable, !oldValue {
                onNetworkRestored?()
                if let pathStatus { onStatus(pathStatus) }
            } else if !networkAvailable, oldValue {
                onNetworkLost?()
            }
        }
    }
    var starts = 0
    var resumes = 0
    var prewarms = 0
    var pauses = 0
    var stops = 0
    var pathChanges = 0
    var turnEnds = 0
    var chunks: [Data] = []
    /// Models the cloud socket's accepted backlog. A hard start/stop clears
    /// it; path suspension and a properly paused resume retain it.
    var pendingAudio: [Data] = []
    var isPaused = false
    var startStatus: SpeechEngineStatus?
    var resumeStatus: SpeechEngineStatus?
    var startEvent: SpeechEvent?
    var pathStatus: SpeechEngineStatus?
    var textLag = Duration.zero
    var drainsTextOnPause = false
    var onStart: (() -> Void)?
    var onNetworkRestored: (() -> Void)?
    var onNetworkLost: (() -> Void)?
    func start() {
        starts += 1
        pendingAudio.removeAll()
        isPaused = false
        onStart?()
        if let startStatus { onStatus(startStatus) }
        if let startEvent { onEvent(startEvent) }
    }
    func resume() {
        resumes += 1
        if !isPaused { pendingAudio.removeAll() }
        isPaused = false
        if let resumeStatus { onStatus(resumeStatus) }
    }
    func prewarm() { prewarms += 1; isPaused = true; if let startStatus { onStatus(startStatus) } }
    func pause() { pauses += 1; isPaused = true }
    func stop() { stops += 1; pendingAudio.removeAll(); onStatus(.idle) }
    func send(_ chunk: Data) { chunks.append(chunk); pendingAudio.append(chunk) }
    func networkPathChanged() { pathChanges += 1 }
    func endTurn() { turnEnds += 1 }
}

@main struct HybridOfflineRegression {
    static var failures = 0
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { failures += 1; print("FAIL: " + message) }
    }
    static func name(_ source: HybridSpeechEngine.Source) -> String { source == .cloud ? "cloud" : "local" }
    static func text(_ event: SpeechEvent) -> String? {
        switch event {
        case .text(let text), .replaceText(let text, _): text
        case .sessionReset: "reset"
        case .turnEnded: "end"
        default: nil
        }
    }
    static func main() {
        let first = Data(repeating: 1, count: 2560), second = Data(repeating: 2, count: 2560)
        let third = Data(repeating: 3, count: 2560), fourth = Data(repeating: 4, count: 2560)
        let local = FakeSpeechEngine(), cloud = FakeSpeechEngine()
        local.startStatus = .failed("No downloaded language models")
        cloud.startStatus = .connecting
        cloud.textLag = .milliseconds(600)
        cloud.drainsTextOnPause = true
        let online = HybridSpeechEngine(local: local, cloud: cloud)
        var events: [String] = [], statuses: [SpeechEngineStatus] = [], order: [String] = []
        online.onSourceChange = { source, _ in order.append(name(source)) }
        online.onEvent = { if let value = text($0) { events.append(value); order.append(value) } }
        online.onStatus = { statuses.append($0) }
        cloud.startEvent = .text("cloud-first-event")
        online.start()
        check(local.starts == 0 && local.prewarms == 0 && local.stops == 0, "online startup never invokes fixed-locale recognition")
        check(cloud.starts == 1 && online.activeSource == .cloud, "online startup selects automatic cloud recognition immediately")
        check(order == ["cloud", "cloud-first-event"], "cloud source is published before synchronous transcript events")
        check(online.textLag == .milliseconds(600), "first turn uses cloud boundary timing instead of local timing")
        check(online.drainsTextOnPause, "online mode forwards the cloud raw-text drain capability")
        online.send(first)
        check(cloud.chunks == [first] && local.chunks.isEmpty, "first PCM reaches cloud while it is still connecting")
        cloud.onStatus(.reconnecting)
        online.send(second)
        check(cloud.chunks == [first, second] && local.starts == 0, "online retries retain automatic recognition and receive fresh PCM")
        check(statuses.last == .reconnecting, "online reconnect status is forwarded unchanged")
        cloud.onStatus(.failed("Service credentials rejected"))
        check(statuses.last == .failed("Service credentials rejected") && local.starts == 0, "terminal online errors never activate an offline recognizer")
        online.stop()
        check(local.stops == 0, "hard cleanup does not instantiate unused local recognition")

        let fallbackLocal = FakeSpeechEngine(), fallbackCloud = FakeSpeechEngine()
        fallbackCloud.drainsTextOnPause = true
        fallbackLocal.startStatus = .live
        fallbackLocal.startEvent = .text("explicit-offline-first-event")
        let network = HybridSpeechEngine(local: fallbackLocal, cloud: fallbackCloud)
        var networkEvents: [String] = [], networkOrder: [String] = [], replayed: [Double] = []
        network.onSourceChange = { source, seconds in
            networkOrder.append(name(source)); replayed.append(seconds)
            if source == .cloud, seconds > 0 { network.send(fourth) }
        }
        network.onEvent = { if let value = text($0) { networkEvents.append(value); networkOrder.append(value) } }
        var cloudWasSelectedBeforePathRestore = false
        fallbackCloud.onNetworkRestored = {
            cloudWasSelectedBeforePathRestore = network.activeSource == .cloud && networkOrder.last == "cloud"
            fallbackCloud.onEvent(.text("restored-cloud-event"))
        }
        network.start(); network.send(first)
        let oldCloudEvent = fallbackCloud.onEvent, oldCloudStatus = fallbackCloud.onStatus
        network.networkAvailable = false
        check(fallbackCloud.stops == 0 && fallbackLocal.starts == 1 && network.activeSource == .local,
              "actual path loss suspends cloud and starts explicit offline recognition")
        check(fallbackCloud.pendingAudio == [first], "path loss preserves audio already accepted by the cloud socket")
        check(!network.drainsTextOnPause, "offline mode forwards the local raw-text drain capability")
        check(Array(networkOrder.suffix(3)) == ["reset", "local", "explicit-offline-first-event"],
              "offline translator/source is selected before its first event")
        network.send(second); network.send(third)
        check(fallbackCloud.chunks == [first] && fallbackLocal.chunks == [second, third], "offline audio reaches only the explicit recognizer")
        oldCloudStatus(.live); oldCloudEvent(.text("obsolete-cloud"))
        check(!networkEvents.contains("obsolete-cloud") && network.activeSource == .local, "old cloud readiness and text cannot replace offline mode")
        let oldLocalEvent = fallbackLocal.onEvent, oldLocalStatus = fallbackLocal.onStatus
        network.networkAvailable = true
        check(network.activeSource == .cloud && fallbackCloud.starts == 1 && fallbackCloud.resumes == 0 && fallbackLocal.stops == 1,
              "restored path returns to retained cloud recognition without rebuilding its backlog")
        check(network.drainsTextOnPause, "cloud restoration restores the cloud raw-text drain capability")
        check(cloudWasSelectedBeforePathRestore && networkEvents.contains("restored-cloud-event"),
              "cloud source is selected before restoring a socket that can synchronously emit events")
        check(fallbackCloud.chunks == [first, second, third, fourth], "offline replay precedes fresh input supplied by source callback")
        check(fallbackCloud.pendingAudio == [first, second, third, fourth], "pre-outage cloud audio survives before the replayed offline interval")
        check(abs((replayed.last ?? 0) - 0.16) < 0.000001, "cloud handoff reports the actual offline replay window")
        let calls = networkOrder.count
        fallbackCloud.onStatus(.live)
        network.networkAvailable = true
        check(fallbackCloud.chunks == [first, second, third, fourth] && networkOrder.count == calls,
              "readiness or repeated path notifications cannot replay audio twice")
        oldLocalEvent(.text("obsolete-local")); oldLocalStatus(.failed("obsolete failure"))
        oldCloudEvent(.text("old-cloud-after-reconnect"))
        check(!networkEvents.contains("obsolete-local") && !networkEvents.contains("old-cloud-after-reconnect"), "saved callbacks cannot enter a replacement source session")
        network.networkPathChanged(); network.endTurn()
        check(fallbackCloud.pathChanges == 1 && fallbackCloud.turnEnds == 1 && fallbackLocal.turnEnds == 0,
              "live path and turn commands reach only current cloud recognition")
        network.stop()
        let warmLocal = FakeSpeechEngine(), warmCloud = FakeSpeechEngine()
        warmCloud.startStatus = .connecting
        warmCloud.resumeStatus = .live
        let warm = HybridSpeechEngine(local: warmLocal, cloud: warmCloud)
        var warmEvents: [String] = []
        warm.onEvent = { if let value = text($0) { warmEvents.append(value) } }
        warm.prewarm(); warm.prewarm()
        check(warmCloud.prewarms == 1 && warmCloud.starts == 0 && warmLocal.starts == 0, "prewarm opens only one cloud session")
        warm.start(); warm.send(first)
        check(warmCloud.resumes == 1 && warmCloud.starts == 0 && warmCloud.chunks == [first], "first listen resumes prewarmed cloud without rebuilding it")
        let warmTail = warmCloud.onEvent
        let oldWarmStatus = warmCloud.onStatus
        warm.pause(); warm.pause()
        warm.send(second); warm.networkPathChanged(); warm.endTurn(); warm.prewarm()
        warmTail(.text("accepted-cloud-tail")); warmTail(.turnEnded)
        check(warmCloud.pauses == 1 && warmCloud.stops == 0 && warmEvents == ["accepted-cloud-tail", "end"],
              "cloud pause retains final tokens and warm session after microphone release")
        check(warmCloud.chunks == [first] && warmCloud.pathChanges == 0 && warmCloud.turnEnds == 0,
              "paused input and path commands cannot upload fresh audio or reconnect")
        warm.resume()
        check(warmCloud.resumes == 2 && warmCloud.starts == 0 && warmLocal.starts == 0, "warm microphone resume preserves automatic cloud mode")
        warm.pause()
        warm.networkAvailable = false
        warmTail(.text("accepted-suspension-close"))
        check(warmEvents.contains("accepted-suspension-close"), "current paused cloud closure can finish accepted speech during suspension")
        let stoppedAt = warmCloud.stops
        warm.networkAvailable = true
        check(warm.networkAvailable && !warmCloud.networkAvailable && warmCloud.starts == 0 && warmCloud.stops == stoppedAt,
              "restored path stays deferred in a paused cloud socket")
        warm.resume()
        check(warmCloud.starts == 0 && warmCloud.resumes == 3 && warmLocal.starts == 0,
              "resume after paused network loss resumes the retained automatic cloud session")
        check(warmCloud.chunks == [first] && warmCloud.pendingAudio == [first], "resume retains accepted audio without resending it twice")
        warm.stop(); warm.start()
        warmTail(.text("stale-after-fresh-start"))
        let freshCloudStops = warmCloud.stops
        oldWarmStatus(.failed("obsolete warm failure"))
        check(!warmEvents.contains("stale-after-fresh-start") && warmCloud.stops == freshCloudStops,
              "old cloud events and failures stay invalid after a fresh session starts")
        warm.stop()

        let coldLocal = FakeSpeechEngine(), coldCloud = FakeSpeechEngine()
        coldCloud.startStatus = .connecting
        let cold = HybridSpeechEngine(local: coldLocal, cloud: coldCloud)
        var coldEvents: [String] = []
        var coldStatus: SpeechEngineStatus?
        cold.onEvent = { if let value = text($0) { coldEvents.append(value) } }
        cold.onStatus = { coldStatus = $0 }
        cold.start(); cold.send(first); cold.pause()
        coldCloud.onStatus(.reconnecting)
        check(coldCloud.stops == 0 && coldLocal.starts == 0 && coldStatus == .reconnecting && coldCloud.pendingAudio == [first],
              "paused connect retries keep only the socket's authorized accepted-audio drain")
        cold.send(second); cold.networkPathChanged(); cold.endTurn(); cold.prewarm()
        check(coldCloud.chunks == [first] && coldCloud.starts == 1 && coldCloud.resumes == 0 && coldCloud.pathChanges == 0,
              "a paused retry cannot receive fresh audio or new session commands")
        coldCloud.onStatus(.live); coldCloud.onEvent(.text("final from initial connection")); coldCloud.onEvent(.turnEnded)
        check(coldCloud.pauses == 1 && coldCloud.stops == 0 && coldEvents == ["final from initial connection", "end"],
              "connecting cloud pause keeps accepted speech callbacks instead of hard stopping")
        cold.networkAvailable = false; cold.networkAvailable = true
        check(coldCloud.starts == 1, "path recovery cannot restart a paused failed connection")
        cold.resume()
        check(coldCloud.starts == 1 && coldCloud.resumes == 1 && coldCloud.pendingAudio == [first],
              "an explicit listen resumes the retained paused cloud session")
        let afterStopEvent = coldCloud.onEvent
        let countBeforeStop = coldEvents.count
        cold.stop(); afterStopEvent(.text("after-hard-stop"))
        check(coldEvents.count == countBeforeStop, "hard stop rejects final tokens immediately")

        let expiredLocal = FakeSpeechEngine(), expiredCloud = FakeSpeechEngine()
        let expired = HybridSpeechEngine(local: expiredLocal, cloud: expiredCloud)
        expired.start(); expired.send(first); expired.pause()
        expiredCloud.onStatus(.reconnecting); expiredCloud.onStatus(.idle)
        expired.resume()
        check(expiredCloud.starts == 2 && expiredCloud.resumes == 0 && expiredLocal.starts == 0,
              "the socket's expired drain starts cleanly on a later explicit listen")
        expired.stop()

        let offlineLocal = FakeSpeechEngine(), offlineCloud = FakeSpeechEngine()
        offlineLocal.startStatus = .live
        let offline = HybridSpeechEngine(local: offlineLocal, cloud: offlineCloud)
        offline.networkAvailable = false
        offline.prewarm(); offline.start(); offline.send(first)
        check(offlineLocal.starts == 1 && offlineCloud.starts == 0 && offlineCloud.prewarms == 0, "cold offline mode starts only explicit local recognition")
        let pausedOfflineEvent = offlineLocal.onEvent
        offline.pause(); offline.networkAvailable = true; offline.send(second)
        check(offlineCloud.starts == 0 && offlineLocal.chunks == [first], "paused offline audio is never replayed on path recovery")
        var offlineReplay = -1.0
        offline.onSourceChange = { source, seconds in if source == .cloud { offlineReplay = seconds } }
        offline.resume()
        check(offline.activeSource == .cloud && offlineCloud.starts == 1 && offlineCloud.chunks.isEmpty && offlineReplay == 0,
              "online resume discards paused offline replay and restores automatic recognition")
        var escapedOffline = false
        offline.onEvent = { if case .text("stale-offline") = $0 { escapedOffline = true } }
        pausedOfflineEvent(.text("stale-offline"))
        check(!escapedOffline, "a prior offline callback cannot change an online resumed turn")
        offline.networkAvailable = false; offline.send(third); offline.networkAvailable = true
        check(offlineCloud.chunks == [third], "a later outage cannot resurrect the offline audio discarded by pause")
        offline.stop()

        let replacedLocal = FakeSpeechEngine(), replacedCloud = FakeSpeechEngine()
        let replaced = HybridSpeechEngine(local: replacedLocal, cloud: replacedCloud)
        replaced.networkAvailable = false
        var replacedText = 0
        replaced.onEvent = { if case .text = $0 { replacedText += 1 } }
        replaced.start()
        let oldExplicitCallback = replacedLocal.onEvent
        let oldExplicitStatus = replacedLocal.onStatus
        var staleLocalStatus = false
        replaced.onStatus = { if case .failed = $0 { staleLocalStatus = true } }
        replaced.stop(); replaced.start()
        oldExplicitCallback(.text("stale old explicit session"))
        oldExplicitStatus(.failed("obsolete local failure"))
        check(replacedText == 0 && replacedLocal.starts == 2 && !staleLocalStatus,
              "a saved local callback stays invalid after a new offline session starts")
        replaced.stop()

        let cappedLocal = FakeSpeechEngine(), cappedCloud = FakeSpeechEngine()
        let capped = HybridSpeechEngine(local: cappedLocal, cloud: cappedCloud)
        capped.networkAvailable = false; capped.start()
        for _ in 0..<500 { capped.send(first) }
        for _ in 0..<500 { capped.send(Data()) }
        capped.networkAvailable = true
        check(cappedCloud.chunks.count >= 374 && cappedCloud.chunks.count <= 375 && cappedLocal.chunks.count == 500,
              "offline replay is bounded to thirty seconds and excludes empty chunks")
        capped.stop()

        let cappedMissingLocal = FakeSpeechEngine(), cappedRetainedCloud = FakeSpeechEngine()
        cappedMissingLocal.startStatus = .failed("No offline assets")
        let cappedMissing = HybridSpeechEngine(local: cappedMissingLocal, cloud: cappedRetainedCloud)
        cappedMissing.start(); cappedMissing.send(first); cappedMissing.networkAvailable = false
        for _ in 0..<500 { cappedMissing.send(second) }
        cappedMissing.networkAvailable = true
        check(cappedRetainedCloud.pendingAudio.count >= 375 && cappedRetainedCloud.pendingAudio.count <= 376 && cappedMissingLocal.chunks.isEmpty,
              "a long outage with no offline assets keeps the cloud interval and bounds additional replay to thirty seconds")
        cappedMissing.stop()

        let idleLocal = FakeSpeechEngine(), idleCloud = FakeSpeechEngine()
        let idle = HybridSpeechEngine(local: idleLocal, cloud: idleCloud)
        idle.prewarm(); idleCloud.onStatus(.idle); idle.stop()
        check(idleCloud.stops == 1 && idleLocal.stops == 0,
              "hard stop cleans a used transcriber's ancillary resources even after its socket became idle")

        let cancelledLocal = FakeSpeechEngine(), cancelledCloud = FakeSpeechEngine()
        let cancelled = HybridSpeechEngine(local: cancelledLocal, cloud: cancelledCloud)
        cancelled.onSourceChange = { _, _ in cancelled.stop() }
        cancelled.start()
        check(cancelledCloud.starts == 0 && cancelledLocal.starts == 0, "synchronous hard stop during source setup prevents native startup")

        let cancelledReplayLocal = FakeSpeechEngine(), cancelledReplayCloud = FakeSpeechEngine()
        let cancelledReplay = HybridSpeechEngine(local: cancelledReplayLocal, cloud: cancelledReplayCloud)
        cancelledReplay.networkAvailable = false; cancelledReplay.start(); cancelledReplay.send(first)
        cancelledReplay.onSourceChange = { source, _ in if source == .cloud { cancelledReplay.stop() } }
        cancelledReplay.networkAvailable = true
        check(cancelledReplayCloud.starts == 0 && cancelledReplayCloud.chunks.isEmpty,
              "synchronous hard stop during reconnection prevents replay upload")

        let deniedLocal = FakeSpeechEngine(), deniedCloud = FakeSpeechEngine()
        let denied = HybridSpeechEngine(local: deniedLocal, cloud: deniedCloud)
        denied.networkAvailable = false; denied.start(); denied.send(first)
        deniedCloud.startStatus = .failed("Rejected before replay")
        denied.networkAvailable = true
        check(deniedCloud.chunks.isEmpty, "synchronous terminal cloud failure invalidates its replay transition")
        denied.send(second)
        check(deniedCloud.chunks.isEmpty && deniedLocal.chunks == [first], "failed recognition rejects further microphone chunks until explicit retry")
        denied.stop()

        let missingLocal = FakeSpeechEngine(), retainedCloud = FakeSpeechEngine()
        missingLocal.startStatus = .failed("Offline language is not installed")
        let recoverable = HybridSpeechEngine(local: missingLocal, cloud: retainedCloud)
        var recoverableStatuses: [SpeechEngineStatus] = []
        recoverable.onStatus = { recoverableStatuses.append($0) }
        recoverable.onSourceChange = { source, seconds in
            if source == .local { recoverable.send(second) }
            else if seconds > 0 { recoverable.send(fourth) }
        }
        recoverable.start(); recoverable.send(first); recoverable.networkAvailable = false
        check(retainedCloud.stops == 0 && retainedCloud.pendingAudio == [first] && recoverableStatuses.last == .reconnecting,
              "a missing offline pack during path loss preserves the accepted cloud turn and stays recoverable")
        check(!recoverableStatuses.contains { if case .failed = $0 { true } else { false } } && missingLocal.chunks.isEmpty,
              "offline setup failure neither ends listening nor sends reentrant PCM to the failed recognizer")
        recoverable.send(third); recoverable.networkAvailable = true
        check(retainedCloud.starts == 1 && retainedCloud.resumes == 0 && retainedCloud.pendingAudio == [first, second, third, fourth],
              "path recovery translates buffered microphone input after missing local assets without losing the earlier cloud interval")
        recoverable.stop()

        let pausedMissingLocal = FakeSpeechEngine(), pausedRetainedCloud = FakeSpeechEngine()
        pausedMissingLocal.startStatus = .failed("Missing offline models")
        let pausedMissing = HybridSpeechEngine(local: pausedMissingLocal, cloud: pausedRetainedCloud)
        pausedMissing.start(); pausedMissing.send(first); pausedMissing.networkAvailable = false
        pausedMissing.send(second); pausedMissing.pause(); pausedMissing.send(third)
        pausedMissing.networkAvailable = true
        check(pausedRetainedCloud.pauses == 1 && pausedRetainedCloud.stops == 0 && !pausedRetainedCloud.networkAvailable,
              "pausing an unavailable local fallback also bounds the retained cloud drain and defers path restoration")
        pausedMissing.resume()
        check(pausedRetainedCloud.starts == 1 && pausedRetainedCloud.resumes == 1 && pausedRetainedCloud.pendingAudio == [first],
              "resuming retains pre-outage accepted cloud audio without uploading discarded offline or paused input")
        pausedMissing.stop()

        let lostLocal = FakeSpeechEngine(), lostCloud = FakeSpeechEngine()
        let failedRestore = HybridSpeechEngine(local: lostLocal, cloud: lostCloud)
        failedRestore.start(); failedRestore.send(first); failedRestore.networkAvailable = false; failedRestore.send(second)
        lostCloud.pathStatus = .failed("Retained cloud credentials expired")
        failedRestore.networkAvailable = true
        failedRestore.send(third)
        check(lostCloud.chunks == [first] && lostCloud.stops == 1,
              "a terminal failure while restoring retained cloud audio invalidates both replay and later microphone chunks")
        failedRestore.stop()

        let closingLocal = FakeSpeechEngine(), closingCloud = FakeSpeechEngine()
        let closing = HybridSpeechEngine(local: closingLocal, cloud: closingCloud)
        var closureOrder: [String] = []
        closing.onSourceChange = { source, _ in closureOrder.append(name(source)) }
        closing.onEvent = { event in
            switch event {
            case .segment(let segment) where segment.isClosed: closureOrder.append("close:" + segment.source)
            case .sessionReset: closureOrder.append("reset")
            default: break
            }
        }
        closingCloud.onNetworkLost = {
            closingCloud.onEvent(.segment(SpeechSegment(id: 7, source: "", translation: "", stableTranslation: "", language: nil, isClosed: true)))
            closingCloud.onEvent(.sessionReset)
        }
        closing.start(); closing.networkAvailable = false
        check(closureOrder == ["cloud", "close:", "reset", "reset", "local"],
              "synchronous cloud suspension forwards its corrective empty closure before switching recognition source")
        closing.stop()

        let interruptedLocal = FakeSpeechEngine(), interruptedCloud = FakeSpeechEngine()
        let interrupted = HybridSpeechEngine(local: interruptedLocal, cloud: interruptedCloud)
        interrupted.onEvent = { if case .turnEnded = $0 { interrupted.stop() } }
        interruptedCloud.onNetworkLost = { interruptedCloud.onEvent(.turnEnded) }
        interrupted.start(); interrupted.networkAvailable = false
        check(interruptedLocal.starts == 0 && interruptedCloud.stops == 1,
              "a hard stop from the cloud suspension callback cannot start local recognition afterward")

        let endedLocal = FakeSpeechEngine(), endedCloud = FakeSpeechEngine()
        let endedOffline = HybridSpeechEngine(local: endedLocal, cloud: endedCloud)
        endedOffline.start(); endedOffline.send(first); endedOffline.networkAvailable = false; endedOffline.send(second)
        endedCloud.onStatus(.idle)
        endedOffline.networkAvailable = true
        check(endedCloud.starts == 2 && endedCloud.resumes == 0 && endedCloud.chunks == [first, second],
              "a retained socket that expires while offline is rebuilt before replay instead of silently losing new input")
        endedOffline.stop()

        let unavailableLocal = FakeSpeechEngine(), unavailableCloud = FakeSpeechEngine()
        unavailableLocal.startStatus = .failed("Download languages first")
        let unavailable = HybridSpeechEngine(local: unavailableLocal, cloud: unavailableCloud)
        unavailable.networkAvailable = false
        var failure: SpeechEngineStatus?
        unavailable.onStatus = { failure = $0 }
        unavailable.start()
        check(failure == .failed("Download languages first") && unavailableCloud.starts == 0,
              "missing explicit offline assets fail honestly without cloud startup")
        unavailable.stop()

        let originalLocal = FakeSpeechEngine(), changingCloud = FakeSpeechEngine()
        var selectedInput = "en"
        var createdInputs: [String] = []
        var createdLocals: [FakeSpeechEngine] = []
        let changingInput = HybridSpeechEngine(local: originalLocal, cloud: changingCloud, makeLocal: {
            createdInputs.append(selectedInput)
            let local = FakeSpeechEngine()
            local.startStatus = .live
            createdLocals.append(local)
            return local
        })
        changingInput.start()
        check(createdInputs.isEmpty && originalLocal.starts == 0,
              "online recognition does not start an unused offline session")
        selectedInput = "ja"
        changingInput.networkAvailable = false
        check(createdInputs == ["ja"] && createdLocals[0].starts == 1 && originalLocal.starts == 0,
              "the first outage uses the input language selected during the online conversation")
        guard createdLocals.count == 1 else { exit(1) }
        changingInput.send(first)
        changingInput.pause(); changingInput.resume()
        check(createdInputs == ["ja"] && createdLocals[0].resumes == 1 && createdLocals[0].chunks == [first],
              "a warm offline resume preserves the current recognizer instead of rebuilding it")
        let obsoleteLocalEvent = createdLocals[0].onEvent
        var refreshedEvents: [String] = []
        changingInput.onEvent = { if let value = text($0) { refreshedEvents.append(value) } }
        changingInput.networkAvailable = true
        selectedInput = "es"
        changingInput.networkAvailable = false
        check(createdInputs == ["ja", "es"] && createdLocals[1].starts == 1 && createdLocals[0].stops == 1,
              "a later outage refreshes offline settings and cleans up the prior local recognizer")
        let eventCount = refreshedEvents.count
        obsoleteLocalEvent(.text("stale Japanese result"))
        check(refreshedEvents.count == eventCount,
              "callbacks from the replaced offline recognizer cannot enter the new session")
        changingInput.stop()
        print("Hybrid online/offline regression: \(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
