@preconcurrency import AVFoundation
import AudioToolbox
import os

/// Plays spoken translations for speech-to-speech mode: 24 kHz mono PCM16
/// chunks from `SonioxSpeaker`, queued back to back as they arrive.
final class SpeechPlayer {
    nonisolated enum Output: Sendable { case automatic, headphones, speaker }

    static var supportsDirectionalOutput: Bool {
        #if os(iOS)
        if #available(iOS 26.2, *) { return true }
        #endif
        return false
    }

    static let sampleRate: Double = 24_000
    /// How long after the last sound the mic stays muted, for the room's echo.
    private static let echoTail: Duration = .milliseconds(400)

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    /// Buffers scheduled and not played yet.
    private var queued = 0
    /// A byte left over from a chunk with an odd length.
    private var leftover: UInt8?
    private var lastSoundAt: ContinuousClock.Instant?
    /// Bumped on stop, so completions of dropped buffers are ignored.
    private var generation = 0
    private var releaseSession: Task<Void, Never>?
    private var holdsSession = false
    private var observer: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var output: Output = .automatic
    private var preparedPorts: [SpeechChannelRouting.Port]?
    private var drainWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var lastSoundWasPublic = false
    private nonisolated let routeBinding = OSAllocatedUnfairLock<[SpeechChannelRouting.Port]?>(initialState: nil)

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // A route change stops the engine and drops what was scheduled.
        // Don't make an audio-session notification wait for the main actor:
        // it may itself be waiting for audio-session activation to finish.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reset() }
        }
        #if os(iOS)
        let mixer = engine.mainMixerNode
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let changed = self.routeBinding.withLock { expected in
                guard let bound = expected, bound != Self.routePorts else { return false }
                // Mute already scheduled buffers before waiting for main.
                // Volume changes don't rebuild the engine's audio graph.
                mixer.outputVolume = 0
                expected = nil
                return true
            }
            guard changed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.output != .automatic,
                      self.routeBinding.withLock({ $0 == nil }) else { return }
                self.stop()
                self.preparedPorts = nil
                self.routeBinding.withLock { $0 = nil }
            }
        }
        #endif
    }

    deinit {
        releaseSession?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        drainWaiters.values.forEach { $0.resume(throwing: CancellationError()) }
        node.stop()
        engine.stop()
        if holdsSession { AudioSessionUsers.end(.speech) }
    }

    /// Something is playing, or just finished.
    var isAudible: Bool {
        if queued > 0 { return true }
        guard let lastSoundAt else { return false }
        return lastSoundAt.duration(to: .now) < Self.echoTail
    }

    /// The mic would hear the translation through the speaker, so it should
    /// send silence for now. Headphones keep it out of the mic.
    var mutesMic: Bool {
        if queued > 0, playsPublicly { return true }
        return lastSoundWasPublic && lastSoundAt.map { $0.duration(to: .now) < Self.echoTail } == true
    }

    /// A new direction waits for the preceding audio to actually finish,
    /// rather than moving an already queued sentence to the other listener.
    func prepare(output requested: Output) async throws -> Bool {
        try Task.checkCancellation()
        if requested == output, requested == .automatic { return true }
        if requested == output, preparedPorts == Self.routePorts,
           routeBinding.withLock({ $0 }) == preparedPorts,
           SpeechChannelRouting.map(output: requested, ports: Self.routePorts) != nil { return true }
        let generation = generation
        try await waitForDrain()
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        stop()
        output = requested
        preparedPorts = nil
        if requested == .automatic {
            let mixer = engine.mainMixerNode
            routeBinding.withLock { $0 = nil; mixer.outputVolume = 1 }
            return true
        }
        guard Self.supportsDirectionalOutput else { return false }
        do {
            if !holdsSession {
                try AudioSessionUsers.begin(.speech)
                holdsSession = true
            }
            #if os(iOS)
            if #available(iOS 26.2, *) {
                let session = AVAudioSession.sharedInstance()
                guard session.category == .multiRoute, session.mode == .dualRoute else {
                    throw PlaybackError.routingUnavailable
                }
            }
            #endif
            let ports = Self.routePorts
            guard SpeechChannelRouting.map(output: requested, ports: ports) != nil else {
                releaseHeldSession()
                return false
            }
            preparedPorts = ports
            try applyOutputMap()
            let mixer = engine.mainMixerNode
            routeBinding.withLock { $0 = ports; mixer.outputVolume = 1 }
            return true
        } catch {
            preparedPorts = nil
            releaseHeldSession()
            throw error
        }
    }

    private func waitForDrain() async throws {
        guard queued > 0 else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if queued == 0 { continuation.resume() }
                else { drainWaiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.drainWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    /// Queues one chunk of little-endian PCM16 at `sampleRate`.
    func play(_ pcm: Data) {
        // A port disappearing can reorder every global channel index. Never
        // schedule private audio against an unverified replacement route.
        guard output == .automatic || (preparedPorts == Self.routePorts
            && routeBinding.withLock({ $0 }) == preparedPorts
            && SpeechChannelRouting.map(output: output, ports: Self.routePorts) != nil) else {
            stop()
            return
        }
        var bytes = pcm
        if let leftover {
            bytes.insert(leftover, at: bytes.startIndex)
            self.leftover = nil
        }
        if bytes.count % 2 == 1 { leftover = bytes.removeLast() }
        let frames = bytes.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { raw in
            for i in 0..<frames {
                samples[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        guard start() else { return }
        queued += 1
        let generation = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(generation) }
        }
        if !node.isPlaying { node.play() }
    }

    /// Stops at once and drops everything queued.
    func stop() {
        let waiting = Array(drainWaiters.values)
        drainWaiters.removeAll()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
        let wasAudible = queued > 0 || engine.isRunning
        guard wasAudible || node.isPlaying || leftover != nil || holdsSession else { return }
        generation += 1
        node.stop()
        engine.stop()
        queued = 0
        leftover = nil
        if wasAudible {
            lastSoundAt = .now
            lastSoundWasPublic = playsPublicly
        }
        if holdsSession { scheduleRelease() }
    }

    private func start() -> Bool {
        releaseSession?.cancel()
        releaseSession = nil
        do {
            if !holdsSession {
                try AudioSessionUsers.begin(.speech)
                holdsSession = true
            }
            if !engine.isRunning {
                try applyOutputMap()
                engine.prepare()
                try engine.start()
            }
            return true
        } catch {
            // A failed engine start must not retain the shared audio session
            // or carry a partial PCM sample into the next sentence.
            stop()
            leftover = nil
            if holdsSession {
                releaseHeldSession()
            }
            return false
        }
    }

    private func finished(_ generation: Int) {
        guard generation == self.generation, queued > 0 else { return }
        queued -= 1
        lastSoundAt = .now
        lastSoundWasPublic = playsPublicly
        if queued == 0 {
            let waiting = Array(drainWaiters.values)
            drainWaiters.removeAll()
            waiting.forEach { $0.resume() }
            scheduleRelease()
        }
    }

    private func reset() {
        // Configuration changes can leave the player node's scheduled buffers
        // behind even though the engine has stopped. Drop those too.
        stop()
    }

    /// Lets the audio session go once nothing has played for a moment, so a
    /// pause between sentences doesn't toggle it.
    private func scheduleRelease() {
        releaseSession?.cancel()
        releaseSession = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.queued == 0 else { return }
            self.engine.stop()
            self.releaseHeldSession()
        }
    }

    private func releaseHeldSession() {
        releaseSession?.cancel()
        releaseSession = nil
        if holdsSession {
            holdsSession = false
            AudioSessionUsers.end(.speech)
        }
    }

    private var playsPublicly: Bool {
        switch output {
        case .speaker: true
        case .headphones: false
        case .automatic: !Self.outputIsPrivate
        }
    }

    private nonisolated static var routePorts: [SpeechChannelRouting.Port] {
        #if os(iOS)
        return AVAudioSession.sharedInstance().currentRoute.outputs.map { port in
            let kind: SpeechChannelRouting.PortKind
            switch port.portType {
            case .builtInSpeaker: kind = .speaker
            case .headphones, .headsetMic, .bluetoothHFP, .bluetoothLE: kind = .headphones
            default: kind = .other
            }
            return .init(id: port.uid, kind: kind, channels: port.channels?.count ?? 0)
        }
        #else
        return []
        #endif
    }

    private func applyOutputMap() throws {
        guard output != .automatic else { return }
        #if os(iOS)
        guard preparedPorts == Self.routePorts,
              let map = SpeechChannelRouting.map(output: output, ports: Self.routePorts),
              map.count == AVAudioSession.sharedInstance().maximumOutputNumberOfChannels,
              let unit = engine.outputNode.audioUnit else { throw PlaybackError.routingUnavailable }
        let status = map.withUnsafeBytes {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output,
                                 0, $0.baseAddress, UInt32($0.count))
        }
        guard status == noErr else { throw PlaybackError.routingUnavailable }
        #endif
    }

    private enum PlaybackError: LocalizedError {
        case routingUnavailable
        var errorDescription: String? { "Lively couldn't route speech to the selected audio device. Reconnect your headphones and try again." }
    }

    /// Audio goes to headphones or a headset rather than a loudspeaker.
    private static var outputIsPrivate: Bool {
        #if os(iOS)
        let privatePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headsetMic]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { privatePorts.contains($0.portType) }
        #else
        // macOS has no audio session to ask; assume speakers.
        return false
        #endif
    }
}

/// The hardware flattens ports into one channel array. Its order can change
/// whenever a device connects, so derive the map from the complete route.
nonisolated enum SpeechChannelRouting {
    enum PortKind: Sendable { case speaker, headphones, other }
    struct Port: Equatable, Sendable {
        let id: String
        let kind: PortKind
        let channels: Int
    }

    static func map(output: SpeechPlayer.Output, ports: [Port]) -> [Int32]? {
        guard ports.allSatisfy({ $0.channels >= 0 }) else { return nil }
        let map = ports.flatMap { port -> [Int32] in
            let selected = output == .automatic || (output == .speaker && port.kind == .speaker)
                || (output == .headphones && port.kind == .headphones)
            return Array(repeating: selected ? Int32(0) : -1, count: port.channels)
        }
        return map.contains(0) ? map : nil
    }
}
