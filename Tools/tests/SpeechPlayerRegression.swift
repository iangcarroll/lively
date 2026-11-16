// Used by test_speech_player.py. These mocks inject engine failures and record
// scheduled audio; the runner inserts the actual SpeechPlayer.swift below.

@preconcurrency import Foundation
typealias AVAudioFrameCount = UInt32
extension Notification.Name {
    nonisolated static let AVAudioEngineConfigurationChange = Notification.Name("MockAudioEngineConfigurationChange")
}
nonisolated final class AVAudioFormat: @unchecked Sendable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    init?(standardFormatWithSampleRate: Double, channels: Int) {
        sampleRate = standardFormatWithSampleRate
        channelCount = AVAudioChannelCount(channels)
    }
}
typealias AVAudioChannelCount = UInt32
nonisolated final class AVAudioOutputNode: @unchecked Sendable {
    let audioUnit: AudioUnit? = 1
    func inputFormat(forBus: Int) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 24_000,
                      channels: max(1, AVAudioSession.sharedInstance().maximumOutputNumberOfChannels))!
    }
    func outputFormat(forBus: Int) -> AVAudioFormat { inputFormat(forBus: forBus) }
}
nonisolated final class AVAudioMixerNode: @unchecked Sendable {
    private let volume = OSAllocatedUnfairLock(initialState: Float(1))
    var outputVolume: Float {
        get { volume.withLock { $0 } }
        set { volume.withLock { $0 = newValue } }
    }
}
nonisolated final class AVAudioEngine: @unchecked Sendable {
    enum Failure: Error { case unavailable }
    nonisolated(unsafe) static var failNextStart = false
    nonisolated(unsafe) static var onStart: (@Sendable () -> Void)?
    nonisolated(unsafe) static var last: AVAudioEngine?
    var isRunning = false
    let mainMixerNode = AVAudioMixerNode()
    let outputNode = AVAudioOutputNode()
    init() { Self.last = self }
    func attach(_ node: AVAudioPlayerNode) {}
    func connect(_ node: AVAudioPlayerNode, to: AVAudioMixerNode, format: AVAudioFormat) {}
    func prepare() {}
    func start() throws {
        if Self.failNextStart {
            Self.failNextStart = false
            throw Failure.unavailable
        }
        isRunning = true
        Self.onStart?()
    }
    func stop() { isRunning = false }
}
nonisolated final class AVAudioPlayerNode: @unchecked Sendable {
    enum CallbackType { case dataPlayedBack }
    nonisolated(unsafe) static var last: AVAudioPlayerNode?
    var isPlaying = false
    var buffers: [[Float]] = []
    var completions: [@Sendable (Int) -> Void] = []
    init() { Self.last = self }
    func stop() {
        isPlaying = false
        buffers.removeAll()
        completions.removeAll()
    }
    func completeAll() {
        let pending = completions
        completions.removeAll()
        buffers.removeAll()
        pending.forEach { $0(0) }
    }
    func play() { isPlaying = true }
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, completionCallbackType: CallbackType,
                        completionHandler: @escaping @Sendable (Int) -> Void) {
        buffers.append(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
        completions.append(completionHandler)
    }
}
nonisolated final class AVAudioPCMBuffer: @unchecked Sendable {
    let floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>?
    var frameLength: AVAudioFrameCount = 0
    init?(pcmFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount) {
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: Int(frameCapacity))
        samples.initialize(repeating: 0, count: Int(frameCapacity))
        let pointer = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
        pointer.initialize(to: samples)
        floatChannelData = UnsafePointer(pointer)
    }
    deinit {
        floatChannelData?[0].deallocate()
        floatChannelData?.deallocate()
    }
}
// These API-shaped route and AudioUnit mocks exercise the iOS routing branch
// in the host regression build; they never touch the machine's audio devices.
nonisolated final class AVAudioSession: @unchecked Sendable {
    struct Port: Hashable, Sendable {
        let rawValue: String
        static let builtInSpeaker = Port(rawValue: "speaker")
        static let headphones = Port(rawValue: "headphones")
        static let bluetoothHFP = Port(rawValue: "hfp")
        static let bluetoothLE = Port(rawValue: "le")
        static let bluetoothA2DP = Port(rawValue: "a2dp")
        static let headsetMic = Port(rawValue: "headsetMic")
        static let builtInMic = Port(rawValue: "builtInMic")
    }
    struct Category: Equatable, Sendable {
        let rawValue: String
        static let multiRoute = Category(rawValue: "multiRoute")
        static let playAndRecord = Category(rawValue: "playAndRecord")
    }
    struct Mode: Equatable, Sendable {
        let rawValue: String
        static let dualRoute = Mode(rawValue: "dualRoute")
        static let `default` = Mode(rawValue: "default")
    }
    enum RouteChangeReason: UInt { case unknown = 0, newDeviceAvailable = 1, oldDeviceUnavailable = 2 }
    static let routeChangeNotification = Notification.Name("MockRouteChange")
    static let singleton = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { singleton }
    var category = Category.multiRoute
    var mode = Mode.dualRoute
    var currentRoute = AVAudioSessionRouteDescription(outputs: [
        AVAudioSessionPortDescription(uid: "speaker", type: .builtInSpeaker, channels: 2),
        AVAudioSessionPortDescription(uid: "headset", type: .bluetoothHFP, channels: 1),
    ])
    var maximumOutputNumberOfChannels: Int { currentRoute.outputs.reduce(0) { $0 + ($1.channels?.count ?? 0) } }
}
nonisolated final class AVAudioSessionRouteDescription: @unchecked Sendable {
    var outputs: [AVAudioSessionPortDescription]
    init(outputs: [AVAudioSessionPortDescription]) { self.outputs = outputs }
}
nonisolated final class AVAudioSessionPortDescription: @unchecked Sendable {
    let uid: String
    let portType: AVAudioSession.Port
    let channels: [AVAudioSessionChannelDescription]?
    init(uid: String, type: AVAudioSession.Port, channels: Int) {
        self.uid = uid
        portType = type
        self.channels = (0..<channels).map { AVAudioSessionChannelDescription(channelNumber: $0, owningPortUID: uid) }
    }
}
nonisolated struct AVAudioSessionChannelDescription: Sendable {
    let channelNumber: Int
    let owningPortUID: String
}
typealias AudioUnit = Int
typealias OSStatus = Int32
nonisolated let noErr: OSStatus = 0
nonisolated let kAudioOutputUnitProperty_ChannelMap: UInt32 = 2002
nonisolated let kAudioUnitScope_Output: UInt32 = 2
nonisolated let AVAudioSessionRouteChangeReasonKey = "reason"
nonisolated let AVAudioSessionRouteChangePreviousRouteKey = "previousRoute"
nonisolated enum MockAudioUnit {
    nonisolated(unsafe) static var maps: [[Int32]] = []
    nonisolated(unsafe) static var failNextMap = false
}
nonisolated func AudioUnitSetProperty(_ unit: AudioUnit, _ property: UInt32, _ scope: UInt32,
                                     _ element: UInt32, _ data: UnsafeRawPointer?, _ size: UInt32) -> OSStatus {
    if MockAudioUnit.failNextMap {
        MockAudioUnit.failNextMap = false
        return -1
    }
    let count = Int(size) / MemoryLayout<Int32>.size
    let map = data.map { Array(UnsafeBufferPointer(start: $0.assumingMemoryBound(to: Int32.self), count: count)) } ?? []
    MockAudioUnit.maps.append(map)
    return noErr
}

nonisolated enum AudioSessionUsers {
    enum User: Hashable { case speech }
    enum Failure: Error { case activation }
    nonisolated(unsafe) static var users: Set<User> = []
    nonisolated(unsafe) static var onBegin: (@Sendable () -> Void)?
    private static let directionalSpeech = OSAllocatedUnfairLock(initialState: true)
    private static let directionalFailed = OSAllocatedUnfairLock(initialState: false)
    static var directionalSpeechEnabled: Bool {
        get { directionalSpeech.withLock { $0 } }
        set { directionalSpeech.withLock { $0 = newValue } }
    }
    static var directionalSpeechUnavailable: Bool {
        get { directionalFailed.withLock { $0 } }
        set { directionalFailed.withLock { $0 = newValue } }
    }
    private struct Activation {
        var failures = 0
        var ordinaryFailures = 0
        var attempts: [Bool] = []
    }
    private static let activation = OSAllocatedUnfairLock(initialState: Activation())
    static var activationFailures: Int {
        get { activation.withLock { $0.failures } }
        set { activation.withLock { $0.failures = newValue; $0.attempts.removeAll() } }
    }
    static var activationAttempts: [Bool] { activation.withLock { $0.attempts } }
    static var ordinaryActivationFailures: Int {
        get { activation.withLock { $0.ordinaryFailures } }
        set { activation.withLock { $0.ordinaryFailures = newValue } }
    }
    private static func activate() throws {
        let directional = directionalSpeechEnabled && !directionalSpeechUnavailable
        let session = AVAudioSession.sharedInstance()
        session.category = directional ? .multiRoute : .playAndRecord
        session.mode = directional ? .dualRoute : .default
        try activation.withLock {
            $0.attempts.append(directional)
            if $0.failures > 0 { $0.failures -= 1; throw Failure.activation }
            if !directional, $0.ordinaryFailures > 0 { $0.ordinaryFailures -= 1; throw Failure.activation }
        }
        onBegin?()
    }
    static func begin(_ user: User) throws { try activate(); users.insert(user) }
    static func reactivate() throws { try activate() }
    // INSERT_ACTUAL_DIRECTIONAL_RETRY
    static func markDirectionalSpeechUnavailable() { directionalSpeechUnavailable = true }
    static func end(_ user: User) {
        precondition(AVAudioEngine.last?.isRunning != true, "released session before stopping engine")
        users.remove(user)
    }
}

// INSERT_ACTUAL_SPEECH_PLAYER_SOURCE

@main struct SpeechPlayerRegression {
    @MainActor static func channelMaps() {
        typealias Routing = SpeechChannelRouting
        let ports = [
            Routing.Port(id: "speaker", kind: .speaker, channels: 2),
            Routing.Port(id: "headset", kind: .headphones, channels: 1),
        ]
        precondition(Routing.map(output: .speaker, ports: ports) == [0, 0, -1],
                     "outgoing speech reached headphone channels")
        precondition(Routing.map(output: .headphones, ports: ports) == [-1, -1, 0],
                     "incoming speech reached speaker channels")
        let reordered = [
            Routing.Port(id: "headset", kind: .headphones, channels: 2),
            Routing.Port(id: "unrelated", kind: .other, channels: 2),
            Routing.Port(id: "speaker", kind: .speaker, channels: 1),
        ]
        precondition(Routing.map(output: .headphones, ports: reordered) == [0, 0, -1, -1, -1],
                     "headphone map assumed a fixed hardware order")
        precondition(Routing.map(output: .speaker, ports: reordered) == [-1, -1, -1, -1, 0],
                     "speaker map assumed a fixed hardware order")
        precondition(Routing.map(output: .headphones, ports: [ports[0]]) == nil,
                     "missing headphones fell back to the speaker")
        precondition(Routing.map(output: .headphones, ports: [
            Routing.Port(id: "empty", kind: .headphones, channels: 0), ports[0],
        ]) == nil, "an empty headphone port was treated as playable")
        precondition(Routing.map(output: .speaker, ports: []) == nil,
                     "missing speaker had a playable map")
    }

    #if LIVELY_AUDIO_ROUTING_TEST
    @MainActor static func setRoute(headphones: Bool, notify: Bool = false) {
        var outputs = [AVAudioSessionPortDescription(uid: "speaker", type: .builtInSpeaker, channels: 2)]
        if headphones {
            outputs.append(AVAudioSessionPortDescription(uid: "headset", type: .bluetoothHFP, channels: 1))
        }
        AVAudioSession.sharedInstance().currentRoute = AVAudioSessionRouteDescription(outputs: outputs)
        if notify {
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
                                            object: AVAudioSession.sharedInstance())
        }
    }

    @MainActor static func directionalPlayback() async throws {
        precondition(SpeechPlayer.supportsDirectionalOutput)
        MockAudioUnit.maps.removeAll()
        setRoute(headphones: false)
        do {
            let player = SpeechPlayer()
            let ready = try await player.prepare(output: .headphones)
            precondition(!ready, "private speech accepted a speaker-only route")
            player.play(Data([1, 0]))
            precondition(AVAudioPlayerNode.last!.buffers.isEmpty, "failed private preparation permitted speaker playback")
        }
        precondition(AudioSessionUsers.users.isEmpty)

        setRoute(headphones: true)
        do {
            let player = SpeechPlayer()
            let ready = try await player.prepare(output: .speaker)
            precondition(ready && MockAudioUnit.maps.last == [0, 0, -1], "outgoing route was not speaker-only")
            player.play(Data([1, 0]))
            precondition(player.mutesMic, "speaker playback failed to mute mic while headphones were also connected")
            let node = AVAudioPlayerNode.last!
            let count = MockAudioUnit.maps.count
            let same = try await player.prepare(output: .speaker)
            precondition(same && MockAudioUnit.maps.count == count, "same direction unnecessarily changed output mapping")
            var switched = false
            let change = Task { @MainActor in
                let result = try await player.prepare(output: .headphones)
                switched = true
                return result
            }
            try await Task.sleep(for: .milliseconds(20))
            precondition(!switched && MockAudioUnit.maps.count == count, "route changed before queued speech finished playing")
            node.completeAll()
            let changed = try await change.value
            precondition(changed && MockAudioUnit.maps.last == [-1, -1, 0], "incoming route failed after playback drained")
            player.play(Data([2, 0]))
            // The previous speaker sentence may still have an echo tail.
            try await Task.sleep(for: .milliseconds(450))
            precondition(!player.mutesMic, "private headset playback unnecessarily muted the mic")
            setRoute(headphones: false)
            let mixer = AVAudioEngine.last!.mainMixerNode
            let postReturned = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
                                                object: AVAudioSession.sharedInstance())
                postReturned.signal()
            }
            precondition(postReturned.wait(timeout: .now() + 1) == .success,
                         "headphone disconnect notification waited for blocked main actor")
            precondition(mixer.outputVolume == 0,
                         "scheduled private audio was not muted before disconnect notification returned")
            for _ in 0..<100 {
                if node.buffers.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(node.buffers.isEmpty, "headphone disconnect retained private playback")
            player.play(Data([3, 0]))
            precondition(node.buffers.isEmpty, "private playback leaked after headphones disconnected")
            setRoute(headphones: true)
            let reconnected = try await player.prepare(output: .headphones)
            precondition(reconnected && mixer.outputVolume == 1,
                         "verified headphone reconnection did not restore playback volume")
        }
        precondition(AudioSessionUsers.users.isEmpty)

        setRoute(headphones: true)
        do {
            let player = SpeechPlayer()
            _ = try await player.prepare(output: .speaker)
            player.play(Data([1, 0]))
            let count = MockAudioUnit.maps.count
            let pending = Task { @MainActor in try await player.prepare(output: .headphones) }
            try await Task.sleep(for: .milliseconds(20))
            pending.cancel()
            do {
                _ = try await pending.value
                preconditionFailure("cancelled output preparation completed successfully")
            } catch is CancellationError {}
            precondition(MockAudioUnit.maps.count == count, "cancelled preparation changed route")
            precondition(AVAudioEngine.last!.isRunning, "cancelling a route waiter interrupted existing playback")
            player.stop()
        }
        precondition(AudioSessionUsers.users.isEmpty)

        do {
            let player = SpeechPlayer()
            _ = try await player.prepare(output: .speaker)
            player.play(Data([1, 0]))
            let count = MockAudioUnit.maps.count
            let pending = Task { @MainActor in try await player.prepare(output: .headphones) }
            try await Task.sleep(for: .milliseconds(20))
            player.stop()
            do {
                _ = try await pending.value
                preconditionFailure("stopped route preparation revived playback")
            } catch is CancellationError {}
            precondition(MockAudioUnit.maps.count == count, "stopped preparation changed route")
        }
        precondition(AudioSessionUsers.users.isEmpty)

        do {
            let player = SpeechPlayer()
            _ = try await player.prepare(output: .speaker)
            player.play(Data([1, 0]))
            let pending = Task { @MainActor in try await player.prepare(output: .headphones) }
            try await Task.sleep(for: .milliseconds(20))
            AVAudioEngine.last!.stop()
            AVAudioEngine.failNextStart = true
            player.play(Data([2, 0]))
            do {
                _ = try await pending.value
                preconditionFailure("failed engine restart left a route preparation alive")
            } catch is CancellationError {}
            precondition(AVAudioPlayerNode.last!.buffers.isEmpty, "failed restart retained queued speech")
            precondition(AudioSessionUsers.users.isEmpty, "failed restart retained the audio session")
        }

        do {
            let player = SpeechPlayer()
            MockAudioUnit.failNextMap = true
            // A failed map gives up on dual-route playback for this launch
            // and speaks through the ordinary route, as before it existed.
            let ready = try await player.prepare(output: .speaker)
            precondition(ready, "channel map failure didn't fall back to ordinary playback")
            precondition(!SpeechPlayer.supportsDirectionalOutput, "channel map failure left directional output on")
            precondition(AudioSessionUsers.users == [.speech], "prepared fallback lacks its verified active audio-session claim")
            player.play(Data([1, 0]))
            precondition(AVAudioPlayerNode.last!.buffers.count == 1, "fallback playback wasn't queued")
            player.stop()
            AudioSessionUsers.directionalSpeechUnavailable = false
        }
        precondition(AudioSessionUsers.users.isEmpty)
        print("PASS: private route availability, directional maps, playback drain, cancellation, stop invalidation, immediate disconnect muting, reconnection, map failure fallback")
    }

    @MainActor static func privateFallbackPlayback() async throws {
        let session = AVAudioSession.sharedInstance()
        let headphones = AVAudioSessionPortDescription(uid: "ordinary-airpods", type: .bluetoothA2DP, channels: 2)
        let speaker = AVAudioSessionPortDescription(uid: "phone", type: .builtInSpeaker, channels: 2)
        let invalidRoutes: [[AVAudioSessionPortDescription]] = [
            [], [speaker], [speaker, headphones],
            [AVAudioSessionPortDescription(uid: "empty-headset", type: .headphones, channels: 0)],
            [headphones, AVAudioSessionPortDescription(uid: "unknown", type: .builtInMic, channels: 1)],
        ]
        AudioSessionUsers.directionalSpeechUnavailable = true
        session.category = .playAndRecord
        session.mode = .default
        for route in invalidRoutes {
            session.currentRoute = AVAudioSessionRouteDescription(outputs: route)
            let player = SpeechPlayer()
            let accepted = try await player.prepare(output: .headphones)
            precondition(!accepted, "ordinary private fallback accepted an empty, public, mixed, or unverified output")
            player.play(Data([1, 0]))
            precondition(AVAudioPlayerNode.last!.buffers.isEmpty, "rejected private fallback scheduled PCM")
        }
        precondition(AudioSessionUsers.users.isEmpty)

        for failedMap in [false, true] {
            AudioSessionUsers.directionalSpeechUnavailable = !failedMap
            session.category = failedMap ? .multiRoute : .playAndRecord
            session.mode = failedMap ? .dualRoute : .default
            session.currentRoute = AVAudioSessionRouteDescription(outputs: [headphones])
            MockAudioUnit.failNextMap = failedMap
            do {
                let player = SpeechPlayer()
                let accepted = try await player.prepare(output: .headphones)
                precondition(accepted && !SpeechPlayer.supportsDirectionalOutput,
                             "private ordinary playback was not prepared after dual-route unavailability")
                let node = AVAudioPlayerNode.last!
                let mixer = AVAudioEngine.last!.mainMixerNode
                player.play(Data([1, 0])); player.play(Data([2, 0]))
                precondition(node.buffers.count == 2 && !player.mutesMic,
                             "verified A2DP fallback did not queue private audio without muting the mic")
                session.currentRoute = AVAudioSessionRouteDescription(outputs: [speaker])
                var preparing = false, prepareFinished = false, prepareCancelled = false
                let waitingPreparation = Task { @MainActor in
                    preparing = true
                    do { _ = try await player.prepare(output: .headphones) }
                    catch is CancellationError { prepareCancelled = true }
                    prepareFinished = true
                }
                for _ in 0..<100 {
                    if preparing { break }
                    await Task.yield()
                }
                precondition(preparing && !prepareFinished,
                             "reprepare did not wait for the already queued private PCM")
                let postReturned = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: session)
                    postReturned.signal()
                }
                precondition(postReturned.wait(timeout: .now() + 1) == .success,
                             "fallback disconnect notification waited for blocked main actor")
                precondition(mixer.outputVolume == 0,
                             "ordinary fallback left queued private PCM audible before the main actor handled disconnect")
                for _ in 0..<100 {
                    if prepareFinished { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                precondition(prepareFinished && prepareCancelled,
                             "muted private PCM left reprepare waiting indefinitely for a drain")
                _ = await waitingPreparation.result
                player.play(Data([3, 0]))
                precondition(node.buffers.isEmpty,
                             "ordinary fallback scheduled or retained private PCM on the phone speaker")
                for _ in 0..<10 { await Task.yield() }
                session.currentRoute = AVAudioSessionRouteDescription(outputs: [headphones])
                player.play(Data([4, 0]))
                precondition(node.buffers.isEmpty && mixer.outputVolume == 0,
                             "an unverified reconnect resumed private PCM automatically")
                let reconnected = try await player.prepare(output: .headphones)
                precondition(reconnected && mixer.outputVolume == 1,
                             "verified ordinary headphone reconnection did not restore playback")
                player.play(Data([5, 0]))
                precondition(node.buffers == [[Float(5) / 32768]],
                             "reconnected fallback retained old private PCM or failed to play new speech")
                // A replacement private device still needs its own verified
                // binding, even if a route-change notification was delayed.
                session.currentRoute = AVAudioSessionRouteDescription(outputs: [
                    AVAudioSessionPortDescription(uid: "replacement", type: .bluetoothA2DP, channels: 2),
                ])
                player.play(Data([6, 0]))
                precondition(node.buffers.isEmpty, "a changed private port bypassed route revalidation")
                player.stop()
            }
            precondition(AudioSessionUsers.users.isEmpty)
        }

        // Ordinary session activation may change the route without first
        // delivering a notification. Validate again after begin/start.
        AudioSessionUsers.directionalSpeechUnavailable = true
        session.currentRoute = AVAudioSessionRouteDescription(outputs: [headphones])
        do {
            let player = SpeechPlayer()
            let ready = try await player.prepare(output: .headphones)
            precondition(ready)
            AVAudioEngine.onStart = {
                session.currentRoute = AVAudioSessionRouteDescription(outputs: [speaker])
            }
            player.play(Data([7, 0]))
            AVAudioEngine.onStart = nil
            precondition(AVAudioPlayerNode.last!.buffers.isEmpty,
                         "session activation moved private fallback PCM onto a public route")
        }
        precondition(AudioSessionUsers.users.isEmpty)

        // Public replies retain the ordinary route fallback. Microphone echo
        // suppression follows that actual route rather than the requested one.
        session.currentRoute = AVAudioSessionRouteDescription(outputs: [headphones])
        do {
            let player = SpeechPlayer()
            let ready = try await player.prepare(output: .speaker)
            precondition(ready, "ordinary public fallback was rejected")
            player.play(Data([8, 0]))
            precondition(!player.mutesMic, "ordinary headphone output unnecessarily muted the mic")
            session.currentRoute = AVAudioSessionRouteDescription(outputs: [speaker])
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: session)
            player.play(Data([9, 0]))
            precondition(AVAudioPlayerNode.last!.buffers.count == 2 && player.mutesMic,
                         "ordinary public replies lost fallback playback or microphone echo suppression")
            player.stop()
        }
        precondition(AudioSessionUsers.users.isEmpty)
        AudioSessionUsers.directionalSpeechUnavailable = false
        session.category = .multiRoute
        session.mode = .dualRoute
        setRoute(headphones: true)
        print("PASS: private fallback rejects public/mixed routes, mutes queued audio off-main, drops disconnected PCM, revalidates reconnects and activation, and preserves ordinary public playback")
    }

    @MainActor static func concurrentMicFallback() async throws {
        let session = AVAudioSession.sharedInstance()
        let headphones = AVAudioSessionPortDescription(uid: "fallback-headphones", type: .bluetoothA2DP, channels: 2)
        for output: SpeechPlayer.Output in [.headphones, .speaker] {
            AudioSessionUsers.directionalSpeechEnabled = true
            AudioSessionUsers.directionalSpeechUnavailable = false
            AudioSessionUsers.activationFailures = 0
            setRoute(headphones: true)
            let activations = OSAllocatedUnfairLock(initialState: 0)
            let fallbackEntered = DispatchSemaphore(value: 0)
            let finishMicActivation = DispatchSemaphore(value: 0)
            let micFinished = DispatchSemaphore(value: 0)
            let micRecovered = OSAllocatedUnfairLock(initialState: false)
            AudioSessionUsers.onBegin = {
                let first = activations.withLock { count in count += 1; return count == 1 }
                if first {
                    // MicCapture can retry from its lifecycle queue after a
                    // failed reactivation. Use the actual retry implementation
                    // and pause its closure after it latches the ordinary mode,
                    // before the mic's activation reaches the session queue.
                    DispatchQueue.global().async {
                        let recovered = AudioSessionUsers.retryWithoutDirectionalSpeech {
                            fallbackEntered.signal()
                            finishMicActivation.wait()
                            try AudioSessionUsers.reactivate()
                        }
                        micRecovered.withLock { $0 = recovered }
                        micFinished.signal()
                    }
                    precondition(fallbackEntered.wait(timeout: .now() + 1) == .success,
                                 "mic fallback did not reach the controlled activation boundary")
                } else if session.category == .playAndRecord {
                    session.currentRoute = AVAudioSessionRouteDescription(outputs: [headphones])
                }
            }
            do {
                let player = SpeechPlayer()
                let ready = try await player.prepare(output: output)
                precondition(ready && session.category == .playAndRecord && session.mode == .default,
                             "concurrent mic fallback bound speech before ordinary session activation")
                precondition(AudioSessionUsers.activationAttempts == [true, false],
                             "concurrent mic fallback did not verify ordinary activation exactly once")
                player.play(Data([17, 0]))
                precondition(AVAudioPlayerNode.last!.buffers == [[Float(17) / 32768]],
                             "concurrent mic fallback did not play the new sentence")
                finishMicActivation.signal()
                precondition(micFinished.wait(timeout: .now() + 1) == .success && micRecovered.withLock { $0 },
                             "concurrent mic fallback did not finish its independent activation")
                AudioSessionUsers.onBegin = nil
                player.stop()
            }
            precondition(AudioSessionUsers.users.isEmpty)
        }
        AudioSessionUsers.directionalSpeechUnavailable = false
        setRoute(headphones: true)
        print("PASS: background mic fallback reactivates ordinary speech before readiness and playback")
    }

    @MainActor static func activationRecovery() async throws {
        let session = AVAudioSession.sharedInstance()
        let headphones = AVAudioSessionPortDescription(uid: "preview-headphones", type: .bluetoothA2DP, channels: 2)
        AudioSessionUsers.directionalSpeechEnabled = true
        for output: SpeechPlayer.Output in [.headphones, .speaker] {
            AudioSessionUsers.directionalSpeechUnavailable = false
            AudioSessionUsers.activationFailures = 2
            setRoute(headphones: true)
            do {
                let player = SpeechPlayer()
                var accepted = false, threw = false
                do { accepted = try await player.prepare(output: output) }
                catch { threw = true }
                player.play(Data([10, 0]))
                precondition(threw && !accepted && AVAudioPlayerNode.last!.buffers.isEmpty,
                             "failed dual and ordinary activation claimed readiness or queued PCM")
                precondition(SpeechPlayer.supportsDirectionalOutput && AudioSessionUsers.users.isEmpty,
                             "transient ordinary activation failure permanently disabled directional playback or leaked ownership")
                precondition(AudioSessionUsers.activationAttempts == [true, false],
                             "activation recovery did not try dual then ordinary exactly once")
                let recovered = try await player.prepare(output: output)
                player.play(Data([11, 0]))
                precondition(recovered && SpeechPlayer.supportsDirectionalOutput && AudioSessionUsers.activationAttempts == [true, false, true],
                             "healthy dual-route playback did not recover after transient activation failures")
                precondition(AVAudioPlayerNode.last!.buffers == [[Float(11) / 32768]],
                             "recovery reused failed PCM or did not queue the new directional sample")
                player.stop()
            }
            precondition(AudioSessionUsers.users.isEmpty)
        }

        // A channel-map error alone does not prove ordinary activation works.
        AudioSessionUsers.directionalSpeechUnavailable = false
        AudioSessionUsers.activationFailures = 0
        AudioSessionUsers.ordinaryActivationFailures = 1
        setRoute(headphones: true)
        do {
            let player = SpeechPlayer()
            MockAudioUnit.failNextMap = true
            var threw = false
            do { _ = try await player.prepare(output: .speaker) }
            catch { threw = true }
            player.play(Data([12, 0]))
            precondition(threw && SpeechPlayer.supportsDirectionalOutput && AVAudioPlayerNode.last!.buffers.isEmpty,
                         "map failure latched an unusable ordinary fallback")
            let recovered = try await player.prepare(output: .speaker)
            precondition(recovered && SpeechPlayer.supportsDirectionalOutput,
                         "map/ordinary activation failure prevented later directional recovery")
            player.stop()
        }
        precondition(AudioSessionUsers.users.isEmpty)

        // With speaking disabled, previews intentionally request an ordinary
        // session. This must not turn off directional playback for later use.
        AudioSessionUsers.activationFailures = 0
        AudioSessionUsers.directionalSpeechEnabled = false
        session.currentRoute = AVAudioSessionRouteDescription(outputs: [headphones])
        do {
            let player = SpeechPlayer()
            var previewReady = false
            do { previewReady = try await player.prepare(output: .headphones) }
            catch { preconditionFailure("ordinary private preview failed while directional speech was intentionally disabled") }
            precondition(previewReady && SpeechPlayer.supportsDirectionalOutput && AudioSessionUsers.activationAttempts == [false],
                         "ordinary preview latched directional capability off or skipped activation")
            player.play(Data([13, 0]))
            let node = AVAudioPlayerNode.last!
            precondition(node.buffers == [[Float(13) / 32768]], "ordinary private preview did not play")
            node.completeAll()
            AudioSessionUsers.directionalSpeechEnabled = true
            setRoute(headphones: true)
            let directionalReady = try await player.prepare(output: .headphones)
            precondition(directionalReady && SpeechPlayer.supportsDirectionalOutput && MockAudioUnit.maps.last == [-1, -1, 0],
                         "enabling spoken translations did not upgrade the existing preview player to dual-route output")
            player.play(Data([14, 0]))
            precondition(node.buffers == [[Float(14) / 32768]], "directional speech after preview retained the previous sample")
            player.stop()
        }
        precondition(AudioSessionUsers.users.isEmpty)

        AudioSessionUsers.directionalSpeechEnabled = false
        AudioSessionUsers.activationFailures = 1
        session.currentRoute = AVAudioSessionRouteDescription(outputs: [headphones])
        do {
            let player = SpeechPlayer()
            var threw = false
            do { _ = try await player.prepare(output: .headphones) }
            catch { threw = true }
            player.play(Data([15, 0]))
            precondition(threw && AVAudioPlayerNode.last!.buffers.isEmpty && SpeechPlayer.supportsDirectionalOutput,
                         "ordinary preview activation failure claimed readiness or disabled directional capability")
        }
        precondition(AudioSessionUsers.users.isEmpty)

        AudioSessionUsers.directionalSpeechEnabled = false
        AudioSessionUsers.activationFailures = 0
        session.currentRoute = AVAudioSessionRouteDescription(outputs: [headphones])
        do {
            let player = SpeechPlayer()
            let ready = try await player.prepare(output: .headphones)
            precondition(ready)
            player.play(Data([17, 0]))
            AVAudioPlayerNode.last!.completeAll()
            try await Task.sleep(for: .milliseconds(2_200))
            precondition(AudioSessionUsers.users.isEmpty, "idle fallback did not release its session")
            AudioSessionUsers.activationFailures = 1
            var threw = false
            do { _ = try await player.prepare(output: .headphones) }
            catch { threw = true }
            player.play(Data([18, 0]))
            precondition(threw && AVAudioPlayerNode.last!.buffers.isEmpty,
                         "expired fallback skipped activation and claimed readiness after a new activation failure")
        }
        precondition(AudioSessionUsers.users.isEmpty)

        AudioSessionUsers.directionalSpeechUnavailable = true
        AudioSessionUsers.activationFailures = 0
        session.currentRoute = AVAudioSessionRouteDescription(outputs: [])
        do {
            let player = SpeechPlayer()
            let ready = try await player.prepare(output: .speaker)
            player.play(Data([16, 0]))
            precondition(!ready && AVAudioPlayerNode.last!.buffers.isEmpty && AudioSessionUsers.users.isEmpty,
                         "empty ordinary public route claimed readiness, queued PCM, or held the session")
        }
        AudioSessionUsers.directionalSpeechUnavailable = false
        AudioSessionUsers.directionalSpeechEnabled = true
        AudioSessionUsers.activationFailures = 0
        setRoute(headphones: true)
        print("PASS: transient activation rollback, healthy dual recovery, map/ordinary failure, ordinary previews, later directional upgrade, and verified fallback readiness")
    }
    #endif

    @MainActor static func main() async throws {
        channelMaps()
        #if LIVELY_AUDIO_ROUTING_TEST
        try await directionalPlayback()
        try await privateFallbackPlayback()
        try await activationRecovery()
        try await concurrentMicFallback()
        #else
        precondition(!SpeechPlayer.supportsDirectionalOutput, "macOS unexpectedly enabled iOS directional routing")
        #endif
        // Engine startup throws after session acquisition.
        do {
            let player = SpeechPlayer()
            AVAudioEngine.failNextStart = true
            player.play(Data([1, 0, 2]))
            precondition(AudioSessionUsers.users.isEmpty, "failed start retained session")
            precondition(AVAudioPlayerNode.last!.buffers.isEmpty, "failed start queued audio")
            precondition(!AVAudioEngine.last!.isRunning)
            player.stop()
            player.play(Data([3, 0]))
            precondition(AVAudioPlayerNode.last!.buffers == [[Float(3) / 32768]], "failed start carried partial sample")
        }
        precondition(AudioSessionUsers.users.isEmpty, "deinit retained session")

        // A partial sample is discarded even if playback never started.
        do {
            let player = SpeechPlayer()
            player.play(Data([0x34]))
            player.stop()
            player.stop()
            precondition(!player.isAudible, "silent stop created fake speech activity")
            player.play(Data([0x12, 0]))
            precondition(AVAudioPlayerNode.last!.buffers == [[Float(0x12) / 32768]], "stop retained partial sample")
        }
        precondition(AudioSessionUsers.users.isEmpty)

        // A route change drops actual buffers and rejects old completions.
        do {
            let player = SpeechPlayer()
            player.play(Data([1, 0]))
            let node = AVAudioPlayerNode.last!
            let completion = node.completions[0]
            let engine = AVAudioEngine.last!
            engine.stop()
            // Session activation can notify while the main actor is waiting
            // for its queue. Posting must return without waiting for main.
            let postReturned = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
                postReturned.signal()
            }
            precondition(postReturned.wait(timeout: .now() + 1) == .success,
                         "configuration notification waited for blocked main actor")
            for _ in 0..<100 {
                if node.buffers.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            precondition(node.buffers.isEmpty, "route change retained scheduled audio")
            precondition(!node.isPlaying, "route change left player running")
            player.play(Data([2, 0]))
            completion(0)
            try? await Task.sleep(for: .milliseconds(2200))
            precondition(engine.isRunning, "old completion stopped new playback")
            precondition(AudioSessionUsers.users.contains(.speech), "old completion released new playback session")
            player.stop()
        }
        precondition(AudioSessionUsers.users.isEmpty, "deinit before deferred release retained session")
        print("PASS: failed startup, partial sample stop, idempotent stop, nonblocking configuration reset, stale completion, deinit session cleanup")
    }
}
