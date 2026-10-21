@preconcurrency import AVFoundation
import os

/// Captures the microphone and emits 16 kHz mono PCM16 chunks, the format
/// Voxtral Realtime expects. Chunks are small (80 ms) to keep latency low.
///
/// Runs on the audio render thread, so it is not main-actor isolated.
nonisolated final class MicCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let chunkDuration: Double = 0.08
    private static let chunkBytes = Int(sampleRate * chunkDuration) * MemoryLayout<Int16>.size

    /// Called on the audio thread with a PCM16 chunk and its RMS level (0...1).
    var onChunk: (@Sendable (Data, Float) -> Void)?
    /// Called on the main thread if capture stops for a reason outside our control.
    var onInterrupted: (@Sendable () -> Void)?

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
    )!
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var observers: [NSObjectProtocol] = []

    private struct State {
        var converter: AVAudioConverter?
        var pending = Data()
        var wantsRunning = false
    }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restartIfNeeded() })
        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in self?.handleInterruption(note) })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restartIfNeeded() })
        #endif
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        state.withLock { $0.wantsRunning = true }
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "LivelyAudioFile") {
            try startFile(URL(filePath: path))
            return
        }
        #endif
        try configureSession()
        try startEngine()
    }

    func stop() {
        #if DEBUG
        fileTimer?.cancel()
        fileTimer = nil
        #endif
        state.withLock {
            $0.wantsRunning = false
            $0.pending.removeAll(keepingCapacity: true)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func configureSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord, mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers]
        )
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        #endif
    }

    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInput
        }
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        state.withLock {
            $0.converter = converter
            $0.pending.removeAll(keepingCapacity: true)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rms(buffer)
        guard let converter = state.withLock({ $0.converter }) else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }

        let bytes = Data(bytes: samples[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        let chunks: [Data] = state.withLock { s in
            s.pending.append(bytes)
            var ready: [Data] = []
            while s.pending.count >= Self.chunkBytes {
                ready.append(s.pending.prefix(Self.chunkBytes))
                s.pending.removeFirst(Self.chunkBytes)
            }
            return ready
        }
        for chunk in chunks { onChunk?(Data(chunk), level) }
    }

    #if DEBUG
    private var fileTimer: DispatchSourceTimer?

    /// `-LivelyAudioFile PATH` plays an audio file into the app in real time
    /// instead of the microphone, once, then silence. For testing without a
    /// speaker or a quiet room.
    private func startFile(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: format, to: outputFormat) else { throw CaptureError.noInput }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRatio(format)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw CaptureError.noInput }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let pcm = Data(bytes: out.int16ChannelData![0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)

        var offset = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "lively.file-audio", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: Self.chunkDuration, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            var chunk = Data(count: Self.chunkBytes)
            if offset < pcm.count {
                let piece = pcm[offset..<min(offset + Self.chunkBytes, pcm.count)]
                chunk.replaceSubrange(0..<piece.count, with: piece)
                offset += Self.chunkBytes
            }
            self?.onChunk?(chunk, 0.5)
        }
        fileTimer = timer
        timer.resume()
    }

    private func sampleRatio(_ format: AVAudioFormat) -> Double {
        outputFormat.sampleRate / format.sampleRate
    }
    #endif

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            engine.stop()
        case .ended:
            restartIfNeeded()
        @unknown default:
            break
        }
    }
    #endif

    /// Route changes (AirPods connecting, a call ending) can change the input
    /// format or stop the engine. Rebuild the tap and carry on.
    private func restartIfNeeded() {
        guard state.withLock({ $0.wantsRunning }) else { return }
        engine.stop()
        do {
            try configureSession()
            try startEngine()
        } catch {
            state.withLock { $0.wantsRunning = false }
            onInterrupted?()
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        let rms = sqrt(sum / Float(n))
        // Map roughly -50 dB...0 dB onto 0...1 for the level meter.
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 50))
    }

    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone is available." }
    }
}
