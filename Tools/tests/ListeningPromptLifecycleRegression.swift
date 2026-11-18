// Test-only clock/sensor/timer boundaries for the actual visibility controller.
// Timers deliberately ignore cancellation to exercise its stale-work guards.
import Foundation
import Observation

enum PromptTestClock { static var now: TimeInterval = 0 }
final class PromptTestTask {
    private(set) var isCancelled = false
    private let operation: _Concurrency.Task<Void, Never>
    static var tasks: [PromptTestTask] = []
    init(operation: @escaping @MainActor () async -> Void) {
        self.operation = _Concurrency.Task { await operation() }
        Self.tasks.append(self)
    }
    nonisolated func cancel() { MainActor.assumeIsolated { isCancelled = true } }
}
enum PromptTestSleep {
    struct Pending { let duration: Duration; let continuation: CheckedContinuation<Void, any Error> }
    static var pending: [Pending] = []
    static func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { pending.append(Pending(duration: duration, continuation: $0)) }
    }
    static func complete(_ index: Int = 0) { pending.remove(at: index).continuation.resume() }
}
nonisolated struct PromptTestVector { var x = 0.0; var y = 0.0; var z = 0.0 }
nonisolated struct PromptTestQuaternion { var w = 1.0; var x = 0.0; var y = 0.0; var z = 0.0 }
nonisolated struct PromptTestAttitude { var quaternion = PromptTestQuaternion() }
nonisolated struct CMDeviceMotion {
    var attitude = PromptTestAttitude()
    var rotationRate = PromptTestVector()
    var userAcceleration = PromptTestVector()
    var timestamp: TimeInterval
}
nonisolated enum CMAttitudeReferenceFrame { case xArbitraryZVertical }
final class CMMotionManager {
    static var available = true
    static var instances: [CMMotionManager] = []
    var isDeviceMotionAvailable: Bool { Self.available }
    var deviceMotionUpdateInterval: TimeInterval = 0
    private(set) var stops = 0
    private(set) var callbacks: [(CMDeviceMotion?, (any Error)?) -> Void] = []
    init() { Self.instances.append(self) }
    func startDeviceMotionUpdates(using frame: CMAttitudeReferenceFrame, to queue: OperationQueue,
                                  withHandler callback: @escaping (CMDeviceMotion?, (any Error)?) -> Void) {
        callbacks.append(callback)
    }
    nonisolated func stopDeviceMotionUpdates() { MainActor.assumeIsolated { stops += 1 } }
}

// INSERT_VISIBILITY_CONTROLLER

enum ScenePhase { case active, inactive, background }
final class PromptTestStore {
    enum ConnectionStatus: Equatable { case idle, connecting, live, reconnecting, offline, failed(String) }
    var isListening = true
    var status = ConnectionStatus.live
}
struct PromptTestScreen {
    var scenePhase = ScenePhase.active
    let store = PromptTestStore()
    var showSettings = false
    var showOnboarding = false
    var showAddress = false
    var showPro = false
    var voiceOverEnabled = false
    let listeningPrompt = ListeningPromptVisibility()
    // INSERT_SCREEN_GATES
    // INSERT_SCREEN_ACTIVITY
    // INSERT_SCREEN_DISAPPEAR
}

@main struct ListeningPromptLifecycleRegression {
    static var assertions = 0
    static var failures = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { failures += 1; print("FAIL: \(message)") }
    }
    static func flush() async { for _ in 0..<30 { await _Concurrency.Task.yield() } }
    static func scheduled(_ count: Int, _ message: String) async {
        for _ in 0..<100 where PromptTestSleep.pending.count < count { await _Concurrency.Task.yield() }
        check(PromptTestSleep.pending.count == count, message)
    }
    static func completeTimers() async {
        await flush()
        while !PromptTestSleep.pending.isEmpty { PromptTestSleep.complete(); await flush() }
    }
    static func sample(_ yaw: Double = 0, at timestamp: TimeInterval? = nil,
                       rate: PromptTestVector = PromptTestVector(),
                       acceleration: PromptTestVector = PromptTestVector()) -> CMDeviceMotion {
        let half = yaw * .pi / 360
        return CMDeviceMotion(attitude: PromptTestAttitude(quaternion: PromptTestQuaternion(w: cos(half), z: sin(half))),
                              rotationRate: rate, userAcceleration: acceleration, timestamp: timestamp ?? PromptTestClock.now)
    }
    static func timersWithoutSensors() async {
        CMMotionManager.available = false
        PromptTestClock.now = 0
        let owner = ListeningPromptVisibility()
        owner.setActive(true)
        await scheduled(1, "active cue gets a timer without motion hardware")
        check(PromptTestSleep.pending[0].duration == .seconds(5), "actual timer waits the full readable five-second window")
        check(owner.isVisible, "no-sensor listening still starts with guidance")
        check(CMMotionManager.instances.last!.callbacks.isEmpty, "unavailable sensors are not started")
        PromptTestClock.now = 5
        PromptTestSleep.complete()
        await flush()
        check(!owner.isVisible, "no-sensor active cue still hides on time")
        owner.setActive(false)
        check(owner.isVisible, "stopping restores persistent guidance")
        CMMotionManager.available = true
    }
    static func currentAndStaleCallbacks() async {
        PromptTestClock.now = 100
        let owner = ListeningPromptVisibility()
        let manager = CMMotionManager.instances.last!
        owner.setActive(true)
        await scheduled(1, "one owner starts one timer")
        check(manager.callbacks.count == 1, "one owner starts one sensor stream")
        check(manager.deviceMotionUpdateInterval == 0.1, "handoff sampling is limited to ten hertz")
        let first = manager.callbacks[0]
        first(sample(), nil)
        owner.setActive(true)
        await flush()
        check(manager.callbacks.count == 1, "unchanged activity cannot duplicate streams")
        check(PromptTestSleep.pending.count == 1, "unchanged activity cannot duplicate timers")
        PromptTestClock.now = 105
        PromptTestSleep.complete()
        await flush()
        check(!owner.isVisible, "actual timer callback hides the active cue")
        let stops = manager.stops
        owner.setActive(false)
        check(manager.stops == stops + 1, "deactivation stops sensor updates")
        check(owner.isVisible, "deactivation restores persistent guidance")
        PromptTestClock.now = 106
        owner.setActive(true)
        await scheduled(1, "resuming owns a fresh timer")
        let second = manager.callbacks.last!
        second(sample(), nil)
        PromptTestClock.now = 111
        PromptTestSleep.complete()
        await flush()
        check(!owner.isVisible, "resumed session fades independently")
        first(sample(180), nil)
        check(!owner.isVisible, "previous-session sensor callback cannot reveal the new session")
        second(sample(180, at: 110), nil)
        check(!owner.isVisible, "stale sensor timestamps are rejected")
        second(sample(180, at: 112), nil)
        check(!owner.isVisible, "future sensor timestamps are rejected")
        second(sample(180), nil)
        check(owner.isVisible, "current portrait yaw handoff reveals the shared cue")
        await scheduled(1, "current handoff schedules one hide timer")
        let task = PromptTestTask.tasks.last!
        owner.setActive(false)
        check(task.isCancelled, "deactivation cancels the handoff timer")
        first(sample(acceleration: PromptTestVector(z: 2)), nil)
        second(sample(acceleration: PromptTestVector(z: 2)), nil)
        await flush()
        check(owner.isVisible, "stale stopped callbacks preserve stopped guidance")
        check(PromptTestSleep.pending.count == 1, "stale stopped callbacks cannot add timers")
        await completeTimers()
    }
    static func staleDeadlineCannotTakeOwnership() async {
        PromptTestClock.now = 200
        let owner = ListeningPromptVisibility()
        owner.setActive(true)
        await scheduled(1, "old timer is pending")
        let old = PromptTestTask.tasks.last!
        owner.setActive(false)
        check(old.isCancelled, "stop requests cancellation of the old timer")
        PromptTestClock.now = 202
        owner.setActive(true)
        await scheduled(2, "new timer coexists with an uncooperative obsolete timer")
        let current = PromptTestTask.tasks.last!
        PromptTestClock.now = 205
        PromptTestSleep.complete(0)
        await flush()
        check(owner.isVisible, "old deadline cannot hide the new session cue")
        owner.setActive(false)
        check(current.isCancelled, "obsolete completion cannot clear ownership of the current timer")
        await completeTimers()
    }
    static func refreshedDeadlineCannotTakeOwnership() async {
        PromptTestClock.now = 250
        let owner = ListeningPromptVisibility()
        owner.setActive(true)
        await scheduled(1, "initial reminder owns one timer")
        let callback = CMMotionManager.instances.last!.callbacks.last!
        callback(sample(), nil)
        let old = PromptTestTask.tasks.last!
        PromptTestClock.now = 253
        callback(sample(180), nil)
        await scheduled(2, "handoff extends a deadline even before its original timer completes")
        let current = PromptTestTask.tasks.last!
        check(old.isCancelled, "extending a cue cancels its prior timer")
        PromptTestClock.now = 255
        PromptTestSleep.complete(0)
        await flush()
        check(owner.isVisible, "same-session old deadline cannot hide a refreshed cue")
        owner.setActive(false)
        check(current.isCancelled, "same-session obsolete timer cannot clear the replacement timer")
        await completeTimers()
    }
    static func sensorVectorConversion() async {
        for axis in 0..<3 {
            for isAcceleration in [false, true] {
                PromptTestClock.now = 500 + Double(axis * 20) + (isAcceleration ? 10 : 0)
                let start = PromptTestClock.now
                let owner = ListeningPromptVisibility()
                owner.setActive(true)
                await scheduled(1, "vector conversion fixture starts one timer")
                let callback = CMMotionManager.instances.last!.callbacks.last!
                callback(sample(), nil)
                PromptTestClock.now = start + 5
                PromptTestSleep.complete()
                await flush()
                check(!owner.isVisible, "vector conversion starts after the cue fades")
                let magnitude = isAcceleration ? 0.8 : 3.2
                let vector = PromptTestVector(x: axis == 0 ? magnitude : 0,
                                              y: axis == 1 ? magnitude : 0,
                                              z: axis == 2 ? magnitude : 0)
                callback(sample(rate: isAcceleration ? PromptTestVector() : vector,
                                acceleration: isAcceleration ? vector : PromptTestVector()), nil)
                check(owner.isVisible, "actual sensor conversion detects \(isAcceleration ? "acceleration" : "rotation") axis \(axis)")
                await scheduled(1, "sensor movement owns one replacement timer")
                owner.setActive(false)
                await completeTimers()
            }
        }
    }
    static func screenBoundaries() async {
        PromptTestClock.now = 300
        var screen = PromptTestScreen()
        check(screen.listeningPromptIsActive, "foreground live conversation activates the cue")
        screen.activityChanged(screen.listeningPromptIsActive)
        await scheduled(1, "actual screen activity starts its cue timer")
        PromptTestClock.now = 305
        PromptTestSleep.complete()
        await flush()
        check(!screen.showsListeningPrompt, "actual screen gate hides expired live guidance")
        screen.voiceOverEnabled = true
        check(screen.showsListeningPrompt, "VoiceOver retains readable live instructions")
        check(!screen.listeningPromptIsActive, "VoiceOver needs no redundant motion sensing")
        screen.voiceOverEnabled = false
        for state in [PromptTestStore.ConnectionStatus.idle, .connecting, .reconnecting, .offline, .failed("failure")] {
            screen.store.status = state
            check(!screen.listeningPromptIsActive, "nonlive state does not sense motion: \(state)")
            check(screen.showsListeningPrompt, "nonlive guidance remains visible: \(state)")
        }
        screen.store.status = .live
        screen.store.isListening = false
        check(!screen.listeningPromptIsActive, "stopped live-status store does not sense motion")
        check(screen.showsListeningPrompt, "stopped instructions remain visible")
        screen.store.isListening = true
        for phase in [ScenePhase.inactive, .background] {
            screen.scenePhase = phase
            check(!screen.listeningPromptIsActive, "nonactive scene does not sense motion: \(phase)")
            screen.activityChanged(screen.listeningPromptIsActive)
            check(screen.showsListeningPrompt, "background reset restores an expired cue")
        }
        screen.scenePhase = .active
        for modal in 0..<4 {
            screen.showSettings = modal == 0; screen.showOnboarding = modal == 1
            screen.showAddress = modal == 2; screen.showPro = modal == 3
            check(!screen.listeningPromptIsActive, "covering sheet stops handoff sensing: \(modal)")
        }
        screen.showSettings = false; screen.showOnboarding = false
        screen.showAddress = false; screen.showPro = false
        screen.activityChanged(screen.listeningPromptIsActive)
        await scheduled(1, "returning to visible conversation starts a fresh cue")
        let task = PromptTestTask.tasks.last!
        let manager = CMMotionManager.instances.last!
        let stops = manager.stops
        screen.screenDisappeared()
        check(task.isCancelled, "actual screen disappearance cancels its timer")
        check(manager.stops == stops + 1, "actual disappearance stops motion sensing")
        check(screen.showsListeningPrompt, "disappearance cannot leave a hidden cue on return")
        await completeTimers()
    }
    static func releasesOwner() async {
        PromptTestClock.now = 400
        var owner: ListeningPromptVisibility? = ListeningPromptVisibility()
        weak var reference = owner
        let manager = CMMotionManager.instances.last!
        owner!.setActive(true)
        await scheduled(1, "released owner has a timer")
        let task = PromptTestTask.tasks.last!
        let stops = manager.stops
        owner = nil
        check(reference == nil, "timer and sensor callbacks cannot retain their owner")
        check(task.isCancelled, "releasing the owner cancels its timer")
        check(manager.stops == stops + 1, "releasing the owner stops sensors")
        await completeTimers()
    }
    static func main() async {
        await timersWithoutSensors()
        await currentAndStaleCallbacks()
        await staleDeadlineCannotTakeOwnership()
        await refreshedDeadlineCannotTakeOwnership()
        await sensorVectorConversion()
        await screenBoundaries()
        await releasesOwner()
        print("\(failures == 0 ? "PASS" : "FAIL"): \(assertions) actual listening prompt lifecycle assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
