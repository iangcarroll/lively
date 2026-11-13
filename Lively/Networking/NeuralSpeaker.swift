import Foundation
import NeuralVoices

/// Speaks with verified local Kokoro assets through the same directional
/// player as online speech. A queued line keeps the voice chosen at enqueue.
final class NeuralSpeaker: TranslationSpeaker {
    var onError: (String) -> Void = { _ in }
    var onPreviewStatus: (String) -> Void = { _ in }
    let player = SpeechPlayer()

    nonisolated private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
    private struct Line {
        let id: UUID
        let text: String
        let voice: NeuralVoice
        let output: SpeechPlayer.Output
        let completion: Completion?
        var isPreview: Bool { completion != nil }
    }

    private let renderer: any NeuralSpeechRendering
    private let voiceProvider: (Language) -> NeuralVoice?
    private var queue: [Line] = []
    private var active: Line?
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var previewStatus = ""
    private static let maximumQueuedLines = 64

    init(renderer: any NeuralSpeechRendering = InstalledNeuralSpeechRenderer(),
         voiceProvider: @escaping (Language) -> NeuralVoice? = {
             NeuralVoicePacks.shared.selectedVoice(for: $0.rawValue)
         }) {
        self.renderer = renderer
        self.voiceProvider = voiceProvider
    }

    deinit {
        worker?.cancel()
        active?.completion?.finish(.failure(CancellationError()))
        queue.forEach { $0.completion?.finish(.failure(CancellationError())) }
        let player = player
        Task { @MainActor in player.stop() }
    }

    func speak(_ text: String, in language: Language, output: SpeechPlayer.Output = .automatic) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let voice = voiceProvider(language), voice.languageCode == language.rawValue else {
            fail(NeuralSpeechError.unsupportedLanguage(language.englishName))
            return
        }
        speak(text, voice: voice, output: output)
    }

    func speak(_ text: String, voice: NeuralVoice, output: SpeechPlayer.Output = .automatic) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= NeuralVoiceEngine.maximumTextCharacters else {
            fail(NeuralSpeechError.textTooLong)
            return
        }
        guard queue.count < Self.maximumQueuedLines else {
            fail(NeuralSpeechError.queueFull)
            return
        }
        enqueue(Line(id: UUID(), text: text, voice: voice, output: output, completion: nil))
    }

    /// A public sample can use the speaker when no headphones are present.
    /// Incoming conversation lines never use this fallback policy.
    func preview(voice: NeuralVoice) async throws {
        try Task.checkCancellation()
        stop()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                enqueue(Line(id: id, text: Self.sample(for: voice.languageCode), voice: voice,
                             output: .headphones, completion: Completion(continuation)))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.active?.id == id || self.queue.contains(where: { $0.id == id }) else { return }
                self.stop()
            }
        }
    }

    func stop() {
        generation &+= 1
        worker?.cancel()
        worker = nil
        active?.completion?.finish(.failure(CancellationError()))
        active = nil
        queue.forEach { $0.completion?.finish(.failure(CancellationError())) }
        queue.removeAll()
        player.stop()
        publishPreviewStatus("")
    }

    static func releaseCachedModel() async { await NeuralVoiceRuntime.shared.unload() }

    private func enqueue(_ line: Line) {
        queue.append(line)
        guard worker == nil else { return }
        let token = generation
        // Don't retain the speaker across preparation, verification or model
        // inference: dropping it must cancel the producer and stop playback.
        worker = Task { [weak self] in
            defer { self?.finishWorker(token) }
            while !Task.isCancelled, let line = self?.nextLine(token) {
                guard let player = self?.player, let renderer = self?.renderer else { return }
                do {
                    self?.previewStatus("Preparing audio…", for: line, token: token)
                    let available: Bool
                    if line.isPreview {
                        if !SpeechPlayer.supportsDirectionalOutput {
                            available = try await player.prepare(output: .automatic)
                        } else if try await player.prepare(output: .headphones) {
                            available = true
                        } else {
                            try Task.checkCancellation()
                            guard self?.generation == token else { throw CancellationError() }
                            available = try await player.prepare(output: .speaker)
                        }
                    } else {
                        available = try await player.prepare(output: line.output)
                    }
                    try Task.checkCancellation()
                    guard self?.generation == token else { throw CancellationError() }
                    guard available else {
                        if line.isPreview { throw NeuralSpeechError.outputUnavailable }
                        self?.finishLine(line, token: token)
                        continue
                    }
                    self?.previewStatus("Preparing offline voice…", for: line, token: token)
                    try Task.checkCancellation()
                    guard self?.generation == token else { throw CancellationError() }
                    let stream = try await renderer.audio(for: line.text, voice: line.voice)
                    try Task.checkCancellation()
                    guard self?.generation == token else { throw CancellationError() }
                    var produced = false
                    var audible = false
                    for try await samples in stream {
                        try Task.checkCancellation()
                        guard self?.generation == token else { throw CancellationError() }
                        guard !samples.isEmpty else { continue }
                        let pcm = try NeuralSpeechPCM.encode(samples)
                        produced = true
                        player.play(pcm)
                        audible = audible || player.isAudible
                        self?.previewStatus("Playing \(line.voice.name)", for: line, token: token)
                    }
                    try Task.checkCancellation()
                    guard self?.generation == token else { throw CancellationError() }
                    guard produced else { throw NeuralSpeechError.noAudio }
                    if line.isPreview {
                        guard audible else { throw NeuralSpeechError.outputUnavailable }
                        while player.isAudible {
                            try await Task.sleep(for: .milliseconds(50))
                            guard self?.generation == token else { throw CancellationError() }
                        }
                    }
                    self?.finishLine(line, token: token)
                } catch is CancellationError {
                    line.completion?.finish(.failure(CancellationError()))
                    if self?.generation == token { self?.stop() }
                    return
                } catch {
                    guard !Task.isCancelled, self?.generation == token else {
                        line.completion?.finish(.failure(CancellationError()))
                        return
                    }
                    line.completion?.finish(.failure(error))
                    if line.isPreview { self?.stop() }
                    else { self?.fail(error) }
                    return
                }
            }
        }
    }

    private func nextLine(_ token: Int) -> Line? {
        guard generation == token, !queue.isEmpty else { return nil }
        let line = queue.removeFirst()
        active = line
        return line
    }
    private func finishLine(_ line: Line, token: Int) {
        guard generation == token, active?.id == line.id else { return }
        line.completion?.finish(.success(()))
        active = nil
        if line.isPreview { publishPreviewStatus("") }
    }
    private func finishWorker(_ token: Int) {
        guard generation == token else { return }
        worker = nil
        active = nil
    }
    private func fail(_ error: Error) {
        stop()
        onError(error.localizedDescription)
    }
    private func previewStatus(_ message: String, for line: Line, token: Int) {
        guard line.isPreview, generation == token, active?.id == line.id else { return }
        publishPreviewStatus(message)
    }
    private func publishPreviewStatus(_ message: String) {
        guard previewStatus != message else { return }
        previewStatus = message
        onPreviewStatus(message)
    }
    private static func sample(for language: String) -> String {
        switch language {
        case "zh": "你好，这是离线语音预览。"
        case "ja": "こんにちは。これはオフライン音声のプレビューです。"
        case "es": "Hola. Esta es una muestra de voz sin conexión."
        case "fr": "Bonjour. Voici un aperçu de voix hors ligne."
        case "hi": "नमस्ते। यह ऑफ़लाइन आवाज़ का नमूना है।"
        case "it": "Ciao. Questa è un'anteprima della voce offline."
        case "pt": "Olá. Esta é uma prévia da voz offline."
        default: "Hello. This is an offline voice preview."
        }
    }
}

protocol NeuralSpeechRendering {
    func audio(for text: String, voice: NeuralVoice) async throws -> AsyncThrowingStream<[Float], Error>
}

private struct InstalledNeuralSpeechRenderer: NeuralSpeechRendering {
    func audio(for text: String, voice: NeuralVoice) async throws -> AsyncThrowingStream<[Float], Error> {
        let packs = NeuralVoicePacks.shared
        let directory = try await packs.requireInstalledDirectory()
        try Task.checkCancellation()
        // First verification can publish the installed directory and advance
        // its revision. Capture the authoritative revision after that finishes.
        let revision = packs.installationRevision
        guard packs.installedDirectory == directory else { throw CancellationError() }
        return NeuralVoiceRuntime.shared.stream(text: text, voiceID: voice.id,
                                               language: voice.languageCode, directory: directory) {
            await MainActor.run {
                packs.installationRevision == revision && packs.installedDirectory == directory
            }
        }
    }
}

/// One model is shared by conversation and previews. Unloading cancels every
/// producer before releasing CoreML; individual speakers cancel only their job.
actor NeuralVoiceRuntime {
    static let shared = NeuralVoiceRuntime()
    private let engine: NeuralVoiceEngine
    private var loadedDirectory: URL?
    private var epoch = 0
    private var unloading = false
    private var jobs: [UUID: NeuralVoiceJob] = [:]
    private var loading: (id: UUID, directory: URL, epoch: Int, task: Task<Void, Error>)?
    private var unloadWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(engine: NeuralVoiceEngine = NeuralVoiceEngine()) { self.engine = engine }

    nonisolated func stream(text: String, voiceID: String, language: String,
                            directory: URL, isValid: @escaping @Sendable () async -> Bool = { true }) -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let job = NeuralVoiceJob()
        let task = Task { [weak self] in
            guard let self else { continuation.finish(throwing: CancellationError()); return }
            await self.generate(text: text, voiceID: voiceID, language: language,
                                directory: directory, job: job, isValid: isValid, into: continuation)
        }
        job.setTask(task)
        continuation.onTermination = { _ in job.cancel() }
        return stream
    }

    func unload() async {
        epoch &+= 1
        let token = epoch
        unloading = true
        loadedDirectory = nil
        loading?.task.cancel()
        loading = nil
        jobs.values.forEach { $0.cancel() }
        await engine.unload()
        if epoch == token {
            unloading = false
            let waiting = Array(unloadWaiters.values)
            unloadWaiters.removeAll()
            waiting.forEach { $0.resume() }
        }
    }

    private func generate(text: String, voiceID: String, language: String, directory: URL,
                          job: NeuralVoiceJob, isValid: @escaping @Sendable () async -> Bool,
                          into continuation: AsyncThrowingStream<[Float], Error>.Continuation) async {
        let id = UUID()
        defer { jobs.removeValue(forKey: id); job.finish() }
        do {
            repeat { try await waitForUnload() } while unloading
            try Task.checkCancellation()
            let token = epoch
            jobs[id] = job
            guard text.count <= NeuralVoiceEngine.maximumTextCharacters else { throw NeuralSpeechError.textTooLong }
            try await validate(token, isValid: isValid)
            if loadedDirectory != directory {
                let loadID: UUID
                let task: Task<Void, Error>
                if let loading, loading.directory == directory, loading.epoch == token {
                    loadID = loading.id
                    task = loading.task
                } else {
                    loadedDirectory = nil
                    loadID = UUID()
                    task = Task { [engine] in try await engine.load(directory: directory) }
                    loading = (loadID, directory, token, task)
                }
                do { try await task.value }
                catch {
                    if loading?.id == loadID { loading = nil }
                    throw error
                }
                try Task.checkCancellation()
                guard epoch == token, !unloading else { throw CancellationError() }
                if loading?.id == loadID {
                    loadedDirectory = directory
                    loading = nil
                } else if loadedDirectory != directory {
                    throw CancellationError()
                }
            }
            try await validate(token, isValid: isValid)
            for try await samples in engine.stream(text: text, voiceID: voiceID, language: language) {
                try await validate(token, isValid: isValid)
                if case .terminated = continuation.yield(samples) { throw CancellationError() }
            }
            try await validate(token, isValid: isValid)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func validate(_ token: Int, isValid: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        guard epoch == token, !unloading else { throw CancellationError() }
        guard await isValid() else { throw CancellationError() }
        try Task.checkCancellation()
        guard epoch == token, !unloading else { throw CancellationError() }
    }

    private func waitForUnload() async throws {
        guard unloading else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if unloading { unloadWaiters[id] = continuation }
                else { continuation.resume() }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelUnloadWaiter(id) }
        }
    }

    private func cancelUnloadWaiter(_ id: UUID) {
        unloadWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

/// Keeps Bluetooth topology active across successive library previews. The
/// window/library owns this hold; cancelling one click doesn't release it.
final class NeuralPreviewSession {
    private var lease: NeuralPreviewLease?
    private var activation: Task<Void, Error>?

    deinit { activation?.cancel(); lease?.close() }

    func prepare() async throws {
        try Task.checkCancellation()
        let current: NeuralPreviewLease
        let task: Task<Void, Error>
        if let lease, let activation {
            current = lease
            task = activation
        } else {
            current = NeuralPreviewLease()
            task = Task.detached(priority: .userInitiated) { try current.acquire() }
            lease = current
            activation = task
        }
        do { try await task.value }
        catch {
            if lease === current {
                lease = nil
                activation = nil
                current.close()
            }
            throw error
        }
        try Task.checkCancellation()
        guard lease === current, current.isActive else { throw CancellationError() }
    }

    func close() {
        let current = lease
        lease = nil
        activation?.cancel()
        activation = nil
        current?.close()
    }
}

nonisolated private final class NeuralPreviewLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var closed = false
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active && !closed }

    func acquire() throws {
        try Task.checkCancellation()
        lock.lock()
        let alreadyClosed = closed
        lock.unlock()
        guard !alreadyClosed else { throw CancellationError() }
        try AudioSessionUsers.begin(.speech)
        lock.lock()
        let cancelled = closed || Task.isCancelled
        if !cancelled { active = true }
        lock.unlock()
        if cancelled {
            AudioSessionUsers.end(.speech)
            throw CancellationError()
        }
    }

    func close() {
        lock.lock()
        closed = true
        let release = active
        active = false
        lock.unlock()
        if release { AudioSessionUsers.end(.speech) }
    }
}

nonisolated private final class NeuralVoiceJob: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        let cancel = cancelled
        if !cancel { self.task = task }
        lock.unlock()
        if cancel { task.cancel() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
    func finish() {
        lock.lock()
        task = nil
        lock.unlock()
    }
}

nonisolated enum NeuralSpeechPCM {
    static func encode(_ samples: [Float]) throws -> Data {
        guard samples.allSatisfy(\.isFinite) else { throw NeuralSpeechError.invalidAudio }
        var pcm = Data(count: samples.count * MemoryLayout<Int16>.size)
        pcm.withUnsafeMutableBytes { raw in
            for (index, sample) in samples.enumerated() {
                let value: Int16
                if sample <= -1 { value = .min }
                else if sample >= 1 { value = .max }
                else { value = Int16((sample * (sample < 0 ? 32_768 : 32_767)).rounded()) }
                raw.storeBytes(of: value.littleEndian, toByteOffset: index * MemoryLayout<Int16>.size, as: Int16.self)
            }
        }
        return pcm
    }
}

private enum NeuralSpeechError: LocalizedError {
    case unsupportedLanguage(String), textTooLong, queueFull, noAudio, invalidAudio, outputUnavailable
    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let language): "A downloaded voice is not available for \(language)."
        case .textTooLong: "This offline speech request is too long. Split it into shorter sentences."
        case .queueFull: "Too many sentences are waiting for offline speech. Start listening again to clear them."
        case .noAudio: "The downloaded voice did not produce audio."
        case .invalidAudio: "The downloaded voice produced invalid audio."
        case .outputUnavailable: "The voice preview could not play on the selected output."
        }
    }
}
