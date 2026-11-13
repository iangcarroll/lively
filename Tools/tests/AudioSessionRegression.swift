// The production enum is extracted verbatim; only its iOS compile condition changes.
// Stateful fakes deliberately keep externally observable API state and inject failures.
import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import os

nonisolated final class AVAudioSession: @unchecked Sendable {
    enum Category: Sendable { case ambient, playAndRecord, multiRoute }
    enum Mode: Sendable { case `default`, dualRoute, voiceChat }
    struct CategoryOptions: OptionSet, Sendable {
        let rawValue: Int
        static let allowBluetoothHFP = Self(rawValue: 1)
        static let defaultToSpeaker = Self(rawValue: 2)
        static let duckOthers = Self(rawValue: 4)
        static let mixWithOthers = Self(rawValue: 16)
    }
    struct SetActiveOptions: OptionSet, Sendable {
        let rawValue: Int
        static let notifyOthersOnDeactivation = Self(rawValue: 1)
    }
    enum Failure: Error { case category, duration, activation, deactivation }
    enum PortType: Sendable { case builtInMic, bluetoothHFP, headsetMic, other }
    struct Channel: Sendable {}
    struct Port: Sendable {
        let portType: PortType
        let channels: [Channel]?
        init(_ type: PortType, _ count: Int?) {
            portType = type
            channels = count.map { Array(repeating: Channel(), count: $0) }
        }
    }
    struct Route: Sendable { var inputs: [Port] = [] }
    struct State {
        var category = Category.ambient
        var mode = Mode.voiceChat
        var options = CategoryOptions()
        var duration: Double = 0
        var active = false
        var route = Route()
        var events: [String] = []
        var categoryFailures = 0
        var durationFailures = 0
        var activationFailures = 0
        var deactivationFailures = 0
        var categoryHook: (@Sendable () -> Void)?
        var activationHook: (@Sendable () -> Void)?
        var deactivationHook: (@Sendable () -> Void)?
    }
    private static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var category: Category { state.withLock { $0.category } }
    var mode: Mode { state.withLock { $0.mode } }
    var categoryOptions: CategoryOptions { state.withLock { $0.options } }
    var currentRoute: Route { state.withLock { $0.route } }
    func read() -> State { state.withLock { $0 } }
    func update(_ body: @Sendable (inout State) -> Void) { state.withLock(body) }
    func reset() { state.withLock { $0 = State() } }
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {
        let hook = state.withLock { $0.categoryHook }
        hook?()
        try state.withLock {
            $0.events.append("category:\(category):\(mode):\(options.rawValue)")
            if $0.categoryFailures > 0 { $0.categoryFailures -= 1; throw Failure.category }
            $0.category = category
            $0.mode = mode
            $0.options = options
            // AVAudioSession implicitly adds this for duckOthers (Apple API contract).
            if options.contains(.duckOthers) { $0.options.insert(.mixWithOthers) }
        }
    }
    func setPreferredIOBufferDuration(_ value: Double) throws {
        try state.withLock {
            $0.events.append("duration:\(value)")
            if $0.durationFailures > 0 { $0.durationFailures -= 1; throw Failure.duration }
            $0.duration = value
        }
    }
    func setActive(_ enabled: Bool, options: SetActiveOptions = []) throws {
        let hook = state.withLock { enabled ? $0.activationHook : $0.deactivationHook }
        hook?()
        try state.withLock {
            $0.events.append("active:\(enabled)")
            if enabled, $0.activationFailures > 0 { $0.activationFailures -= 1; throw Failure.activation }
            if !enabled, $0.deactivationFailures > 0 { $0.deactivationFailures -= 1; throw Failure.deactivation }
            $0.active = enabled
        }
    }
}

// INSERT_ACTUAL_AUDIO_SESSION_USERS

// Same-file private access supplies a barrier and deterministic clean state only.
extension AudioSessionUsers {
    static func flushForTest() { sessionQueue.sync {} }
    static func claimsForTest(_ user: User) -> Int { users.withLock { $0[user] ?? 0 } }
    static func blockQueueForTest(entered: DispatchSemaphore, release: DispatchSemaphore) {
        sessionQueue.async { entered.signal(); release.wait() }
    }
    static func resetForTest() {
        sessionQueue.sync {
            users.withLock { $0.removeAll() }
            directionalSpeech.withLock { $0 = false }
        }
        AVAudioSession.sharedInstance().reset()
    }
}

enum CaptureError: Error { case noInput }

// This is the actual production channel-selection block, applied to a real
// host AVAudioConverter. No AudioEngine, fake sample conversion, or microphone.
nonisolated func mappedConverter(_ inputFormat: AVAudioFormat) throws -> AVAudioConverter {
    let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
// INSERT_ACTUAL_INPUT_MAPPING
    return converter
}

@main
struct AudioSessionRegression {
    static var failures = 0
    static var checks = 0
    static let session = AVAudioSession.sharedInstance()
    static var dualSupported = true
    static let legacyOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers]

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if condition { print("ok   \(message)") }
        else { failures += 1; print("FAIL \(message)") }
    }
    static func reset() { AudioSessionUsers.resetForTest() }
    nonisolated static func attempt(_ body: () throws -> Void) -> Bool {
        do { try body(); return true } catch { return false }
    }
    static func begin(_ user: AudioSessionUsers.User) -> Bool { attempt { try AudioSessionUsers.begin(user) } }
    static func flush() { AudioSessionUsers.flushForTest() }
    static func isLegacy() -> Bool {
        let state = session.read()
        return state.category == .playAndRecord && state.mode == .default && state.options.contains(legacyOptions)
    }
    static func isDual() -> Bool {
        let state = session.read()
        return state.category == .multiRoute && state.mode == .dualRoute && state.options == [.allowBluetoothHFP]
    }

    static func main() {
        dualSupported = CommandLine.arguments.last == "ios26"
        print("Testing actual AudioSessionUsers: \(dualSupported ? "iOS 26.2+" : "legacy iOS")")
        configuration()
        restoration()
        failuresAndRecovery()
        ownership()
        overlappingPlayersAndReactivation()
        concurrency()
        inputMapping()
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    static func configuration() {
        reset()
        check(begin(.mic), "default activation succeeds")
        check(isLegacy(), "disabled directional policy establishes legacy category/mode and required options")
        check(session.read().duration == 0.02 && session.read().active, "activation sets 20 ms preferred duration and activates")
        let initialCalls = session.read().events.filter { $0.hasPrefix("category:") }.count
        check(begin(.mic), "repeated owner activation succeeds")
        check(session.read().events.filter { $0.hasPrefix("category:") }.count == initialCalls, "already correct category avoids a redundant category change")
        AudioSessionUsers.setDirectionalSpeechEnabled(true)
        flush()
        check(dualSupported ? isDual() : isLegacy(), "enabling directional policy applies supported category/mode/options")
        AudioSessionUsers.setDirectionalSpeechEnabled(false)
        flush()
        check(isLegacy(), "disabling directional policy restores legacy category/mode/options")
        AudioSessionUsers.end(.mic)
        flush()
        reset()
        AudioSessionUsers.setDirectionalSpeechEnabled(true)
        flush()
        check(session.read().events.isEmpty, "idle directional toggle does not touch the session")
        check(begin(.speech), "speech alone can establish a directional session")
        check(dualSupported ? isDual() : isLegacy(), "next activation honors an idle toggle")
        reset()
    }

    static func restoration() {
        for directional in [false, true] {
            reset()
            AudioSessionUsers.setDirectionalSpeechEnabled(directional)
            flush()
            check(begin(.mic), "setup before corrupted category test")
            session.update { $0.category = .ambient; $0.mode = .voiceChat; $0.options = [] }
            check(begin(.speech), "activation repairs externally changed category/mode")
            check(directional && dualSupported ? isDual() : isLegacy(), "full category/mode corruption is restored")
            session.update { $0.options.remove(.allowBluetoothHFP) }
            check(begin(.mic), "activation with missing required option succeeds")
            check(directional && dualSupported ? isDual() : isLegacy(), "missing required category option is restored")
        }
        reset()
    }

    static func failuresAndRecovery() {
        for stage in ["category", "duration", "activation"] {
            reset()
            session.update {
                if stage == "category" { $0.categoryFailures = 1 }
                if stage == "duration" { $0.durationFailures = 1 }
                if stage == "activation" { $0.activationFailures = 1 }
            }
            check(!begin(.speech), "\(stage) failure propagates")
            flush()
            check(AudioSessionUsers.current.isEmpty && !session.read().active, "\(stage) failure removes new ownership and leaves session inactive")
            check(begin(.speech) && AudioSessionUsers.current == [.speech] && session.read().active, "next begin recovers after \(stage) failure")
        }
        reset()
        _ = begin(.mic)
        session.update { $0.activationFailures = 1 }
        check(!begin(.speech), "new speech activation failure is reported alongside mic")
        flush()
        check(AudioSessionUsers.current == [.mic] && session.read().active, "failed speech activation preserves active mic ownership")
        session.update { $0.activationFailures = 1 }
        check(!begin(.mic), "existing owner reactivation failure is reported")
        flush()
        check(AudioSessionUsers.current == [.mic], "existing owner is preserved after reactivation failure")
        if dualSupported {
            session.update { $0.categoryFailures = 1 }
            AudioSessionUsers.setDirectionalSpeechEnabled(true)
            flush()
            check(isLegacy(), "failed asynchronous policy update leaves old category observable")
            check(begin(.speech) && isDual(), "activation retries a failed asynchronous policy update")
        }
        reset()
    }

    static func ownership() {
        reset()
        check(begin(.mic) && begin(.speech), "mic and speech can share the session")
        AudioSessionUsers.end(.mic)
        flush()
        check(AudioSessionUsers.current == [.speech] && session.read().active, "stopping mic preserves active speech")
        AudioSessionUsers.end(.mic)
        flush()
        check(session.read().active, "duplicate mic end cannot deactivate speech")
        AudioSessionUsers.end(.speech)
        flush()
        check(AudioSessionUsers.current.isEmpty && !session.read().active, "last user deactivates")
        let deactivations = session.read().events.filter { $0 == "active:false" }.count
        AudioSessionUsers.end(.speech)
        flush()
        check(session.read().events.filter { $0 == "active:false" }.count == deactivations, "duplicate last-user end does not repeat deactivation")
        _ = begin(.speech)
        session.update { $0.deactivationFailures = 1 }
        AudioSessionUsers.end(.speech)
        flush()
        check(AudioSessionUsers.current.isEmpty, "deactivation API failure cannot resurrect released ownership")
        check(begin(.mic), "a fresh activation can recover after failed deactivation")
        AudioSessionUsers.end(.mic)
        flush()
        check(!session.read().active, "next final release retries deactivation successfully")
        reset()
    }

    static func overlappingPlayersAndReactivation() {
        reset()
        check(begin(.speech) && begin(.speech), "old and new speech players can each acquire ownership")
        check(AudioSessionUsers.claimsForTest(.speech) == 2, "overlapping players own two independent claims")
        AudioSessionUsers.end(.speech)
        flush()
        check(AudioSessionUsers.current == [.speech] && session.read().active, "old player cleanup preserves new player playback")
        AudioSessionUsers.end(.speech)
        flush()
        check(AudioSessionUsers.current.isEmpty && !session.read().active, "new player cleanup releases the last speech claim")

        reset()
        _ = begin(.mic)
        let reactivationsSucceeded = (0..<100).allSatisfy { _ in attempt { try AudioSessionUsers.reactivate() } }
        check(reactivationsSucceeded, "100 successive mic route reset reactivations succeed")
        check(AudioSessionUsers.claimsForTest(.mic) == 1, "100 route reset reactivations do not acquire more ownership")
        session.update { $0.activationFailures = 1 }
        check(!attempt { try AudioSessionUsers.reactivate() }, "failed route reset activation propagates")
        check(AudioSessionUsers.claimsForTest(.mic) == 1, "failed route reset preserves the existing ownership")
        check(attempt { try AudioSessionUsers.reactivate() }, "route reset can recover after failed activation")
        AudioSessionUsers.end(.mic)
        flush()
        check(AudioSessionUsers.current.isEmpty && !session.read().active, "one mic release deactivates after repeated reactivation")
        reset()
    }

    static func concurrency() {
        reset()
        _ = begin(.mic)
        let queueBlocked = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        AudioSessionUsers.blockQueueForTest(entered: queueBlocked, release: releaseQueue)
        check(queueBlocked.wait(timeout: .now() + 2) == .success, "controlled barrier holds session operations before pending deactivation")
        AudioSessionUsers.end(.mic)
        let replacementDone = DispatchSemaphore(value: 0)
        let replacementSucceeded = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global().async {
            let success = attempt { try AudioSessionUsers.begin(.speech) }
            replacementSucceeded.withLock { $0 = success }
            replacementDone.signal()
        }
        let pendingDeadline = Date().addingTimeInterval(2)
        while AudioSessionUsers.current != [.speech], Date() < pendingDeadline { Thread.sleep(forTimeInterval: 0.001) }
        check(AudioSessionUsers.current == [.speech], "new speech claim registers before pending deactivation executes")
        releaseQueue.signal()
        check(replacementDone.wait(timeout: .now() + 2) == .success, "replacement activation after queued deactivation completes")
        flush()
        check(replacementSucceeded.withLock { $0 } && session.read().active, "queued last-user deactivation preserves registered replacement")
        check(!session.read().events.contains("active:false"), "pending deactivation rechecks ownership before calling the API")

        reset()
        _ = begin(.mic)
        let deactivating = DispatchSemaphore(value: 0)
        let releaseDeactivation = DispatchSemaphore(value: 0)
        session.update { $0.deactivationHook = { deactivating.signal(); releaseDeactivation.wait() } }
        AudioSessionUsers.end(.mic)
        check(deactivating.wait(timeout: .now() + 2) == .success, "controlled deactivation reaches API")
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global().async {
            let success = attempt { try AudioSessionUsers.begin(.speech) }
            result.withLock { $0 = success }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(2)
        while AudioSessionUsers.current != [.speech], Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        check(AudioSessionUsers.current == [.speech], "new user registers while old deactivation is in flight")
        releaseDeactivation.signal()
        check(done.wait(timeout: .now() + 2) == .success, "new activation completes after deactivation")
        flush()
        check(result.withLock { $0 } && session.read().active, "serialized activation wins over already in-flight deactivation")
        check(session.read().events.suffix(2) == ["duration:0.02", "active:true"], "API operation order ends with activation")
        reset()

        // A synchronous API notification may end an owner or toggle the policy.
        // Neither operation may wait on the session queue that sent it.
        session.update { $0.categoryHook = {
            AudioSessionUsers.setDirectionalSpeechEnabled(false)
            AudioSessionUsers.end(.speech)
        } }
        check(begin(.mic), "synchronous configuration notification can update policy/end another user without deadlock")
        flush()
        check(AudioSessionUsers.current == [.mic] && session.read().active, "notification reentry preserves the live mic")
        reset()

        // Two physical capture/player instances share the same enum identity.
        // Force the earlier activation to fail only after the newer begin registers.
        let activating = DispatchSemaphore(value: 0)
        let releaseActivation = DispatchSemaphore(value: 0)
        let activationCount = OSAllocatedUnfairLock(initialState: 0)
        session.update { state in
            state.activationFailures = 1
            state.activationHook = {
                let first = activationCount.withLock { value in value += 1; return value == 1 }
                if first { activating.signal(); releaseActivation.wait() }
            }
        }
        let firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        let firstResult = OSAllocatedUnfairLock(initialState: true)
        let secondResult = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global().async {
            firstResult.withLock { $0 = attempt { try AudioSessionUsers.begin(.mic) } }
            firstDone.signal()
        }
        check(activating.wait(timeout: .now() + 2) == .success, "first overlapping activation reaches controlled failure")
        DispatchQueue.global().async {
            let success = attempt { try AudioSessionUsers.begin(.mic) }
            secondResult.withLock { $0 = success }
            secondDone.signal()
        }
        // Observe the second claim directly; no scheduler-delay assumption.
        let registeredDeadline = Date().addingTimeInterval(2)
        while AudioSessionUsers.claimsForTest(.mic) < 2, Date() < registeredDeadline { Thread.sleep(forTimeInterval: 0.001) }
        check(AudioSessionUsers.claimsForTest(.mic) == 2, "second overlapping begin registers before the controlled first failure")
        releaseActivation.signal()
        check(firstDone.wait(timeout: .now() + 2) == .success && secondDone.wait(timeout: .now() + 2) == .success,
              "overlapping failure and success both complete")
        flush()
        check(!firstResult.withLock { $0 } && secondResult.withLock { $0 }, "controlled overlap has one failed and one successful begin")
        check(AudioSessionUsers.current == [.mic] && session.read().active, "earlier begin failure cannot discard/deactivate a newer successful owner")
        AudioSessionUsers.end(.mic)
        flush()
        check(AudioSessionUsers.current.isEmpty && !session.read().active, "successful overlapping claim can release without leaving failed ownership behind")
        reset()
    }

    static func inputMapping() {
        reset()
        session.update { $0.mode = .dualRoute }
        guard dualSupported else {
            session.update { $0.route.inputs = [.init(.bluetoothHFP, 1)] }
            let format = inputFormat(channels: 1)
            check(attempt { _ = try mappedConverter(format) }, "legacy iOS does not require a built-in dual-route input")
            return
        }
        let scenarios: [(String, [AVAudioSession.Port], Int, Int?)] = [
            ("built-in only without headset", [.init(.builtInMic, 1)], 1, 0),
            ("stereo built-in only without headset", [.init(.builtInMic, 2)], 2, 0),
            ("built-in first", [.init(.builtInMic, 1), .init(.bluetoothHFP, 1)], 2, 0),
            ("AirPods first", [.init(.bluetoothHFP, 1), .init(.builtInMic, 1)], 2, 1),
            ("multichannel headset before stereo built-in", [.init(.headsetMic, 2), .init(.builtInMic, 2)], 4, 2),
            // Missing metadata cannot establish a port's channel count, even
            // when the sum of known channels happens to equal the format.
            ("unknown input before built-in with matching known total", [.init(.other, nil), .init(.builtInMic, 1)], 1, nil),
            ("unknown input after built-in with matching known total", [.init(.builtInMic, 1), .init(.other, nil)], 1, nil),
            ("empty input before built-in with matching known total", [.init(.other, 0), .init(.builtInMic, 1)], 1, nil),
            ("empty input after built-in with matching known total", [.init(.builtInMic, 1), .init(.other, 0)], 1, nil),
            ("empty input route", [], 1, nil),
            ("built-in absent", [.init(.bluetoothHFP, 1)], 1, nil),
            ("built-in nil channels", [.init(.builtInMic, nil), .init(.bluetoothHFP, 1)], 1, nil),
            ("built-in zero channels", [.init(.builtInMic, 0), .init(.bluetoothHFP, 1)], 1, nil),
            ("built-in offset beyond engine format", [.init(.bluetoothHFP, 2), .init(.builtInMic, 1)], 2, nil),
            ("incomplete route metadata versus engine format", [.init(.bluetoothHFP, nil), .init(.builtInMic, 1)], 2, nil),
            ("stale engine format versus complete route metadata", [.init(.builtInMic, 1), .init(.bluetoothHFP, 1)], 3, nil),
        ]
        for (label, ports, channels, target) in scenarios {
            session.update { $0.route.inputs = ports }
            let format = inputFormat(channels: channels)
            do {
                let converter = try mappedConverter(format)
                check(target != nil, "\(label): \(target == nil ? "inconsistent input route is rejected" : "valid built-in input is accepted")")
                guard let target else { continue }
                check(converter.channelMap == [NSNumber(value: target)], "\(label): map selects the independently expected hardware channel")
                check(convertedLevel(converter, selectedChannel: target) == 0.1, "\(label): real converter outputs built-in signal without headset mix")
            } catch {
                check(target == nil, "\(label): rejects an absent or unverifiable built-in input")
            }
        }
        // Negative control: removing the production map must produce a different
        // signal when the first hardware channel is the headset.
        let format = inputFormat(channels: 2)
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let unselected = AVAudioConverter(from: format, to: output)!
        check(convertedLevel(unselected, selectedChannel: 1) != 0.1, "negative control: default converter does not isolate second-channel built-in input")
        reset()
    }

    static func inputFormat(channels: Int) -> AVAudioFormat {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        return AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
    }

    static func convertedLevel(_ converter: AVAudioConverter, selectedChannel: Int) -> Double {
        let frameCount: AVAudioFrameCount = 4_800
        nonisolated(unsafe) let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: frameCount)!
        input.frameLength = frameCount
        for channel in 0..<Int(converter.inputFormat.channelCount) {
            let amplitude: Float = channel == selectedChannel ? 0.1 : 0.7
            for frame in 0..<Int(frameCount) { input.floatChannelData![channel][frame] = amplitude }
        }
        let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 1_700)!
        let consumed = OSAllocatedUnfairLock(initialState: false)
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            let first = consumed.withLock { value in defer { value = true }; return !value }
            if !first { status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil, output.frameLength > 100 else { return -1 }
        let start = Int(output.frameLength) / 2
        let samples = output.int16ChannelData![0]
        let level = (start..<Int(output.frameLength)).map { Double(samples[$0]) / 32768 }.reduce(0, +)
            / Double(Int(output.frameLength) - start)
        return (level * 1_000).rounded() / 1_000
    }
}
