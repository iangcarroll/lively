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

    /// Called on the audio thread with a PCM16 chunk and its level in dBFS.
    var onChunk: (@Sendable (Data, Float) -> Void)?
    /// Called on the main thread if capture stops for a reason outside our control.
    var onInterrupted: (@MainActor @Sendable () -> Void)?

    /// Every AVAudioEngine graph change (taps, start, stop, rebuilds) and the
    /// mic's hold on the audio session happen on this queue, one at a time,
    /// so `start()`, `stop()` and route-change restarts can't interleave.
    /// Nothing waits on it from the main thread.
    private let lifecycle = DispatchQueue(label: "lively.mic-lifecycle", qos: .userInitiated)

    // Owned by `lifecycle`.
    private var engine = AVAudioEngine()
    private var engineObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var holdsSession = false
    private var inputRouteID: String?

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
    )!
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var observers: [NSObjectProtocol] = []

    private struct State {
        var converter: AVAudioConverter?
        var pending = Data()
        var requests = CaptureRequests()
    }

    init() {
        let center = NotificationCenter.default
        engineObserver = observeConfigurationChanges(of: engine)
        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in self?.handleInterruption(note) })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.restartIfNeeded(rebuild: true) })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.restartIfNeeded() })
        #endif
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        engineObserver.map(NotificationCenter.default.removeObserver)
        // Queued lifecycle work keeps capture alive, so these snapshots can't
        // race with graph changes. Tear down there without retaining self or
        // blocking whichever thread released the final reference.
        let engine = engine
        let tapInstalled = tapInstalled
        let holdsSession = holdsSession
        #if DEBUG
        let timer = fileTimer
        #endif
        lifecycle.async {
            #if DEBUG
            timer?.cancel()
            #endif
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            if holdsSession { AudioSessionUsers.end(.mic) }
        }
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Starts capturing. The request is registered synchronously on the
    /// caller's actor, before the first suspension, so a `stop()` that runs
    /// any time after this call is made cancels it: capture never comes up
    /// for a stopped request. The slow work (activating the audio session,
    /// starting the engine) runs on `lifecycle`, off the caller's thread.
    ///
    /// Returns normally without capturing if the calling task was already
    /// cancelled, or `stop()` (or a newer `start()`) superseded this request;
    /// throws if the mic couldn't start, after undoing the tap and the audio
    /// session hold. A task that may only begin running after `stop()` should
    /// be cancelled by whoever calls `stop()`.
    nonisolated(nonsending) func start() async throws {
        guard !Task.isCancelled else { return }
        let token = state.withLock { s in
            s.pending.removeAll(keepingCapacity: true)
            return s.requests.begin()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lifecycle.async { [self] in
                continuation.resume(with: Result { try startOnQueue(token) })
            }
        }
    }

    /// Stops capturing. Takes effect at once for chunk delivery and any
    /// start in flight; the engine and audio session are released on
    /// `lifecycle` without blocking the caller.
    func stop() {
        state.withLock { s in
            s.requests.cancel()
            s.converter = nil
            s.pending.removeAll(keepingCapacity: true)
        }
        lifecycle.async { [self] in teardown() }
    }

    private func isCurrent(_ token: Int) -> Bool {
        state.withLock { $0.requests.isCurrent(token) }
    }

    private func startOnQueue(_ token: Int) throws {
        dispatchPrecondition(condition: .onQueue(lifecycle))
        // Stopped before we got here.
        guard isCurrent(token) else { return }
        do {
            #if DEBUG
            if let path = UserDefaults.standard.string(forKey: "LivelyAudioFile") {
                try startFile(URL(filePath: path), token: token)
                return
            }
            #endif
            try startCapture(token)
        } catch {
            teardown()
            state.withLock { $0.requests.fail(token) }
            throw error
        }
        // Stopped while starting up: undo it.
        if !isCurrent(token) { teardown() }
    }

    /// Takes the audio session and brings up the tap and engine. On `lifecycle`.
    private func startCapture(_ token: Int) throws {
        if holdsSession {
            try AudioSessionUsers.reactivate()
        } else {
            try AudioSessionUsers.begin(.mic)
            holdsSession = true
        }
        guard isCurrent(token) else { return }
        try startEngine(token)
    }

    /// Releases the tap, the engine and the mic's hold on the audio session.
    /// Safe to call when nothing is running. On `lifecycle`.
    private func teardown() {
        dispatchPrecondition(condition: .onQueue(lifecycle))
        #if DEBUG
        fileTimer?.cancel()
        fileTimer = nil
        #endif
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        state.withLock {
            $0.converter = nil
            $0.pending.removeAll(keepingCapacity: true)
        }
        if holdsSession {
            holdsSession = false
            AudioSessionUsers.end(.mic)
        }
    }

    private func startEngine(_ token: Int) throws {
        #if os(iOS)
        // With no input route, the input node has no valid format and
        // installing a tap on it raises an exception.
        guard AVAudioSession.sharedInstance().isInputAvailable else { throw CaptureError.noInput }
        #endif
        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.noInput
        }
        #if os(iOS)
        if #available(iOS 26.2, *), AVAudioSession.sharedInstance().mode == .dualRoute {
            // Dual-route input includes the headset too. Select the built-in
            // mic rather than mixing private headphone playback into speech.
            let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
            guard !inputs.isEmpty,
                  inputs.allSatisfy({ $0.channels?.isEmpty == false }),
                  inputs.reduce(0, { $0 + ($1.channels?.count ?? 0) }) == Int(inputFormat.channelCount) else {
                throw CaptureError.noInput
            }
            var offset = 0
            var builtInChannel: Int?
            for port in inputs {
                let count = port.channels?.count ?? 0
                if port.portType == .builtInMic, count > 0 { builtInChannel = offset; break }
                offset += count
            }
            guard let builtInChannel, builtInChannel < Int(inputFormat.channelCount) else {
                throw CaptureError.noInput
            }
            converter.channelMap = [NSNumber(value: builtInChannel)]
        }
        #endif
        inputRouteID = captureRouteID
        state.withLock {
            $0.converter = converter
            $0.pending.removeAll(keepingCapacity: true)
        }
        // The tap serves this request only; a callback still converting
        // after stop() or a newer start drops its audio.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, token: token)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.restartIfNeeded() }
    }

    private func process(_ buffer: AVAudioPCMBuffer, token: Int) {
        // Nothing for a stale request, and nothing from a tap left over from
        // an older input format: converting a mismatched buffer is an error.
        guard let converter = state.withLock({ $0.requests.isCurrent(token) ? $0.converter : nil }),
              buffer.format == converter.inputFormat else { return }

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
            // Stopped or restarted while converting.
            guard s.requests.isCurrent(token) else { return [] }
            s.pending.append(bytes)
            var ready: [Data] = []
            while s.pending.count >= Self.chunkBytes {
                ready.append(s.pending.prefix(Self.chunkBytes))
                s.pending.removeFirst(Self.chunkBytes)
            }
            return ready
        }
        for chunk in chunks {
            let chunk = Data(chunk)
            onChunk?(chunk, Self.decibels(chunk))
        }
    }

    #if DEBUG
    private var fileTimer: DispatchSourceTimer?  // Owned by `lifecycle`.

    /// `-LivelyAudioFile PATH` plays an audio file into the app in real time
    /// instead of the microphone, once, then silence. For testing without a
    /// speaker or a quiet room.
    private func startFile(_ url: URL, token: Int) throws {
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
            guard let self, self.isCurrent(token) else { return }
            var chunk = Data(count: Self.chunkBytes)
            if offset < pcm.count {
                let piece = pcm[offset..<min(offset + Self.chunkBytes, pcm.count)]
                chunk.replaceSubrange(0..<piece.count, with: piece)
                offset += Self.chunkBytes
            }
            self.onChunk?(chunk, Self.decibels(chunk))
        }
        fileTimer?.cancel()
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
            lifecycle.async { [weak self] in self?.engine.stop() }
        case .ended:
            restartIfNeeded()
        @unknown default:
            break
        }
    }
    #endif

    /// Route changes (AirPods connecting, a call ending) can change the input
    /// format or stop the engine. Rebuild the tap and carry on. After a media
    /// services reset the old engine is dead, so `rebuild` makes a new one.
    /// Notifications arrive on any thread; the work goes through `lifecycle`.
    private func restartIfNeeded(rebuild: Bool = false) {
        lifecycle.async { [weak self] in self?.restart(rebuild: rebuild) }
    }

    private func restart(rebuild: Bool) {
        dispatchPrecondition(condition: .onQueue(lifecycle))
        let token = state.withLock { $0.requests.active }
        #if DEBUG
        // Playing a file doesn't use the engine.
        if token != nil, fileTimer != nil { return }
        #endif
        // Already running on an unchanged input, as when our own session
        // setup echoes a notification back: nothing to do, so no loop.
        if !rebuild, let token, isCurrent(token), engine.isRunning, tapInstalled,
           inputRouteID == captureRouteID,
           engine.inputNode.outputFormat(forBus: 0) == state.withLock({ $0.converter?.inputFormat }) {
            return
        }
        if rebuild || token != nil {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
        }
        if rebuild {
            engineObserver.map(NotificationCenter.default.removeObserver)
            engine = AVAudioEngine()
            engineObserver = observeConfigurationChanges(of: engine)
        }
        guard let token else { return }
        do {
            try startCapture(token)
            if !isCurrent(token) { teardown() }
        } catch {
            teardown()
            state.withLock { $0.requests.fail(token) }
            DispatchQueue.main.async { [weak self] in
                // A start or stop since then owns capture now.
                guard let self, self.state.withLock({ $0.requests.hasFailed(token) }) else { return }
                self.onInterrupted?()
            }
        }
    }

    private var captureRouteID: String? {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return session.mode.rawValue + session.currentRoute.inputs.map {
            "\($0.uid):\($0.channels?.count ?? 0)"
        }.joined(separator: ",")
        #else
        return nil
        #endif
    }

    /// The RMS level of a PCM16 chunk in dBFS, from about -120 (silence) to 0.
    static func decibels(_ chunk: Data) -> Float {
        let count = chunk.count / MemoryLayout<Int16>.size
        guard count > 0 else { return -120 }
        let sum: Float = chunk.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(0) { total, sample in
                let value = Float(Int16(littleEndian: sample)) / 32768
                return total + value * value
            }
        }
        return 20 * log10(max(sqrt(sum / Float(count)), 1e-6))
    }

    /// Maps roughly -50 dB...0 dB onto 0...1 for the level meter.
    static func meterLevel(_ decibels: Float) -> Float {
        max(0, min(1, (decibels + 50) / 50))
    }

    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone is available." }
    }
}

/// Start requests, so a stop cancels a start that is still in flight. Each
/// `begin()` gets a new token; `stop()` and newer starts make older tokens stale.
nonisolated struct CaptureRequests: Sendable {
    private(set) var generation = 0
    private(set) var wantsRunning = false

    mutating func begin() -> Int {
        generation += 1
        wantsRunning = true
        return generation
    }

    mutating func cancel() {
        generation += 1
        wantsRunning = false
    }

    /// A failed start or restart gives up, unless a newer request replaced it.
    mutating func fail(_ token: Int) {
        if token == generation { wantsRunning = false }
    }

    func isCurrent(_ token: Int) -> Bool { wantsRunning && token == generation }

    /// This request gave up and nothing has started or stopped since.
    func hasFailed(_ token: Int) -> Bool { !wantsRunning && token == generation }

    /// The request a restart should serve, if capture is wanted.
    var active: Int? { wantsRunning ? generation : nil }
}

/// The mic and `SpeechPlayer` share iOS's audio session. Whichever finishes
/// last deactivates it, so a translation still being spoken isn't cut off
/// when listening stops. macOS has no audio session, so this does nothing there.
///
/// Users are counted under a lock, and the session calls themselves run one
/// at a time on `sessionQueue`. A deactivation re-checks the count there, so
/// one decided just before the other user arrived can't land after that
/// user's activation and leave it with a dead session.
nonisolated enum AudioSessionUsers {
    enum User: Hashable, Sendable { case mic, speech }

    private static let users = OSAllocatedUnfairLock(initialState: [User: Int]())
    private static let sessionQueue = DispatchQueue(label: "lively.audio-session", qos: .userInitiated)
    private static let directionalSpeech = OSAllocatedUnfairLock(initialState: false)

    /// The next activation must establish this configuration successfully;
    /// a failed asynchronous update never counts as a prepared speech route.
    static func setDirectionalSpeechEnabled(_ enabled: Bool) {
        directionalSpeech.withLock { $0 = enabled }
        #if os(iOS)
        sessionQueue.async {
            guard !users.withLock({ $0.isEmpty }) else { return }
            try? configure(AVAudioSession.sharedInstance())
        }
        #endif
    }

    #if os(iOS)
    private static func configure(_ session: AVAudioSession) throws {
        if #available(iOS 26.2, *), directionalSpeech.withLock({ $0 }) {
            let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
            if session.category != .multiRoute || session.mode != .dualRoute
                || !session.categoryOptions.contains(options) {
                try session.setCategory(.multiRoute, mode: .dualRoute, options: options)
            }
        } else {
            let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers]
            if session.category != .playAndRecord || session.mode != .default
                || !session.categoryOptions.contains(options) {
                try session.setCategory(.playAndRecord, mode: .default, options: options)
            }
        }
        try session.setPreferredIOBufferDuration(0.02)
    }
    #endif

    static func begin(_ user: User) throws {
        users.withLock { $0[user, default: 0] += 1 }
        do {
            try reactivate()
        } catch {
            // Release this activation's claim without removing another
            // player's hold on the same kind of audio session.
            end(user)
            throw error
        }
    }

    /// Restarts a running mic's session after a route or media-services reset
    /// without claiming ownership a second time.
    static func reactivate() throws {
        #if os(iOS)
        try sessionQueue.sync {
            let session = AVAudioSession.sharedInstance()
            try configure(session)
            try session.setActive(true)
        }
        #endif
    }

    static func end(_ user: User) {
        let empty = users.withLock { users in
            guard let count = users[user] else { return false }
            if count == 1 { users.removeValue(forKey: user) }
            else { users[user] = count - 1 }
            return users.isEmpty
        }
        #if os(iOS)
        guard empty else { return }
        sessionQueue.async {
            // Someone may have begun since we decided.
            guard users.withLock({ $0.isEmpty }) else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #else
        _ = empty
        #endif
    }

    /// Who holds the session now. For tests and diagnostics.
    static var current: Set<User> { users.withLock { Set($0.keys) } }
}
