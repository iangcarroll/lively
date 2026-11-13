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
    nonisolated(unsafe) static var users: Set<User> = []
    static func begin(_ user: User) throws { users.insert(user) }
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
            do {
                _ = try await player.prepare(output: .headphones)
                preconditionFailure("channel map failure was ignored")
            } catch {}
            precondition(AudioSessionUsers.users.isEmpty, "failed output mapping leaked an audio-session claim")
            player.play(Data([1, 0]))
            precondition(AVAudioPlayerNode.last!.buffers.isEmpty, "failed output mapping permitted playback")
        }
        precondition(AudioSessionUsers.users.isEmpty)
        print("PASS: private route availability, directional maps, playback drain, cancellation, stop invalidation, immediate disconnect muting, reconnection, map failure cleanup")
    }
    #endif

    @MainActor static func main() async throws {
        channelMaps()
        #if LIVELY_AUDIO_ROUTING_TEST
        try await directionalPlayback()
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
