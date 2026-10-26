@preconcurrency import AVFoundation

/// Plays spoken translations for speech-to-speech mode: 24 kHz mono PCM16
/// chunks from `SonioxSpeaker`, queued back to back as they arrive.
final class SpeechPlayer {
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

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // A route change stops the engine and drops what was scheduled.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Something is playing, or just finished.
    var isAudible: Bool {
        if queued > 0 { return true }
        guard let lastSoundAt else { return false }
        return lastSoundAt.duration(to: .now) < Self.echoTail
    }

    /// The mic would hear the translation through the speaker, so it should
    /// send silence for now. Headphones keep it out of the mic.
    var mutesMic: Bool { isAudible && !Self.outputIsPrivate }

    /// Queues one chunk of little-endian PCM16 at `sampleRate`.
    func play(_ pcm: Data) {
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
        guard queued > 0 || engine.isRunning else { return }
        generation += 1
        node.stop()
        engine.stop()
        queued = 0
        leftover = nil
        lastSoundAt = .now
        scheduleRelease()
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
                engine.prepare()
                try engine.start()
            }
            return true
        } catch {
            return false
        }
    }

    private func finished(_ generation: Int) {
        guard generation == self.generation, queued > 0 else { return }
        queued -= 1
        lastSoundAt = .now
        if queued == 0 { scheduleRelease() }
    }

    private func reset() {
        generation += 1
        queued = 0
        leftover = nil
        lastSoundAt = .now
        scheduleRelease()
    }

    /// Lets the audio session go once nothing has played for a moment, so a
    /// pause between sentences doesn't toggle it.
    private func scheduleRelease() {
        releaseSession?.cancel()
        releaseSession = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.queued == 0 else { return }
            self.engine.stop()
            if self.holdsSession {
                self.holdsSession = false
                AudioSessionUsers.end(.speech)
            }
        }
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
