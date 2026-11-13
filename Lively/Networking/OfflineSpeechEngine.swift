import AVFoundation
import Foundation
import Speech
import os

/// On-device speech recognition with Apple's Speech framework, the listening
/// half of the offline fallback. Translation stays with `AppleTranslator`, so
/// this engine reports transcript updates plus turn boundaries and leaves the
/// translation to `ConversationStore`.
///
/// One `SpeechTranscriber` runs per side of the pair and the script / language
/// detector picks which one heard the turn. Everything is local: no audio or
/// text leaves the device.
final class OfflineSpeechEngine: SpeechEngine {
    var onEvent: (SpeechEvent) -> Void = { _ in }
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    var networkAvailable = true
    /// Final ASR results trail the end of a turn by a few hundred milliseconds.
    var textLag: Duration { .milliseconds(500) }

    private let languages: LanguagePair
    private let script: ChineseScript

    private static let sampleRate: Double = 16_000
    private static let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
    )!
    private static let speechThreshold: Float = 0.008
    private static let silenceBeforeTurnEnd: Duration = .milliseconds(800)
    private static let turnEndGrace: Duration = .milliseconds(500)

    private var transcribers: [Language: SpeechTranscriber] = [:]
    private var analyzers: [Language: SpeechAnalyzer] = [:]
    private var inputs: [Language: AsyncStream<AnalyzerInput>.Continuation] = [:]
    private var converters: [Language: (AVAudioConverter, AVAudioFormat)] = [:]
    private var resultTasks: [Language: Task<Void, Never>] = [:]
    private var startTask: Task<Void, Never>?
    private var isRunning = false
    /// Invalidates an in-flight start when the engine is stopped.
    private var runID = 0
    /// Audio heard while the analyzers and language assets are starting up.
    private var pendingAudio: [Data] = []
    private static let maxPendingChunks = 375 // 30 s of 80 ms chunks

    /// The language of the current turn, once a recognizer has plausible text.
    private var active: Language?
    /// Latest text each recognizer produced this turn, used to choose the
    /// language when neither result clearly identifies it.
    private var candidates: [Language: String] = [:]
    /// Finalized text of the current turn, and the volatile tail after it.
    private var committed = ""
    private var volatile = ""
    /// A turn is receiving audio or waiting for its final results.
    private var turnOpen = false
    /// Results are ignored after this instant, once a turn's grace has passed.
    private var ignoreResultsAfter: ContinuousClock.Instant?
    private var heardSpeech = false
    private var silenceTimer: Task<Void, Never>?
    private var loggedTranscript = false
    private let logger = Logger(subsystem: "sh.ian.lively", category: "offline")

    init(languages: LanguagePair, script: ChineseScript) {
        self.languages = languages
        self.script = script
    }

    // MARK: - SpeechEngine

    func start() {
        guard !isRunning, startTask == nil else { return }
        onStatus(.connecting)
        let runID = self.runID
        startTask = Task { [weak self] in
            await self?.setUp(runID: runID)
        }
    }

    func stop() {
        runID += 1
        startTask?.cancel()
        startTask = nil
        isRunning = false
        pendingAudio.removeAll()
        silenceTimer?.cancel()
        silenceTimer = nil
        resultTasks.values.forEach { $0.cancel() }
        resultTasks.removeAll()
        for continuation in inputs.values { continuation.finish() }
        inputs.removeAll()
        let analyzers = self.analyzers.values
        self.analyzers.removeAll()
        transcribers.removeAll()
        converters.removeAll()
        for analyzer in analyzers {
            Task { await analyzer.cancelAndFinishNow() }
        }
        resetTurn()
        onStatus(.idle)
    }

    func pause() { stop() }
    func resume() { start() }

    func send(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        guard isRunning else {
            // The hybrid engine buffers for the server too; this keeps the
            // local stopgap from missing the first words while it starts.
            guard startTask != nil else { return }
            pendingAudio.append(chunk)
            if pendingAudio.count > Self.maxPendingChunks { pendingAudio.removeFirst() }
            return
        }
        feed(chunk)
    }

    private func feed(_ chunk: Data) {
        noteAudio(chunk)

        for language in languages.all {
            guard let continuation = inputs[language],
                  let buffer = makeBuffer(from: chunk) else { continue }
            if let (converter, format) = converters[language],
               !format.isEqual(Self.sourceFormat),
               let converted = convert(buffer, using: converter, to: format) {
                continuation.yield(AnalyzerInput(buffer: converted))
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
        }
    }

    /// The store ends the turn itself when it hasn't heard text for a while.
    func endTurn() {
        silenceTimer?.cancel()
        silenceTimer = nil
        finishTurn()
    }

    // MARK: - Setup

    private func setUp(runID: Int) async {
        defer { startTask = nil }
        do {
            var prepared: [(Language, SpeechTranscriber, AVAudioFormat)] = []
            for language in languages.all {
                guard !Task.isCancelled, runID == self.runID else { return }
                let locale = Self.locale(for: language, script: script)
                guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                    throw OfflineSpeechError.unsupported(language.englishName)
                }
                let transcriber = SpeechTranscriber(
                    locale: supported,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: []
                )
                let status = await AssetInventory.status(forModules: [transcriber])
                guard status != .unsupported else {
                    throw OfflineSpeechError.unsupported(language.englishName)
                }
                if status != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                guard !Task.isCancelled, runID == self.runID else { return }
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? Self.sourceFormat
                prepared.append((language, transcriber, format))
            }

            for (language, transcriber, format) in prepared {
                guard !Task.isCancelled, runID == self.runID else { return }
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                try await analyzer.start(inputSequence: stream)
                transcribers[language] = transcriber
                analyzers[language] = analyzer
                inputs[language] = continuation
                if let converter = AVAudioConverter(from: Self.sourceFormat, to: format) {
                    converters[language] = (converter, format)
                }
            }

            guard !Task.isCancelled, runID == self.runID else {
                stop()
                return
            }
            isRunning = true
            startResults(runID: runID)
            let pending = pendingAudio
            pendingAudio.removeAll()
            for chunk in pending { feed(chunk) }
            onStatus(.live)
            logger.info("on-device recognizers ready for \(self.languages.all.map(\.rawValue).joined(separator: "+"), privacy: .public)")
        } catch is CancellationError {
            stop()
        } catch {
            guard runID == self.runID else { return }
            isRunning = false
            logger.error("on-device recognizer unavailable: \(error.localizedDescription, privacy: .public)")
            onStatus(.failed(error.localizedDescription))
            stop()
        }
    }

    private func startResults(runID: Int) {
        for (language, transcriber) in transcribers {
            resultTasks[language] = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { return }
                        self?.handle(result, from: language)
                    }
                } catch is CancellationError {
                    // The analyzer was cancelled while stopping.
                } catch {
                    guard let self, runID == self.runID, self.isRunning else { return }
                    self.onStatus(.failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Results

    private func handle(_ result: SpeechTranscriber.Result, from language: Language) {
        guard isRunning, turnOpen else { return }
        if let ignoreResultsAfter, ContinuousClock.now >= ignoreResultsAfter { return }

        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if active == nil {
            candidates[language] = text
            // The wrong recognizer still produces text for the other language;
            // only the one whose language matches what was said may claim the
            // turn. A couple of characters is too little to tell them apart,
            // so short text waits for the turn to end.
            guard let detected = Language.detect(text, in: languages),
                  detected == language, text.count >= 3 else { return }
            active = language
            logger.info("turn language \(language.rawValue, privacy: .public) after \(text.count, privacy: .public) chars")
        }
        guard active == language else { return }

        if result.isFinal {
            appendFinal(text)
            volatile = ""
        } else {
            guard text != volatile else { return }
            volatile = text
        }
        emitText()
    }

    private func appendFinal(_ text: String) {
        guard !committed.hasSuffix(text) else { return }
        committed = join(committed, text)
    }

    private func emitText() {
        let text = join(committed, volatile)
        guard !text.isEmpty else { return }
        if !loggedTranscript {
            loggedTranscript = true
            logger.info("on-device transcript received (\(text.count, privacy: .public) chars)")
        }
        #if DEBUG
        logger.debug("on-device text: \(text, privacy: .public)")
        #endif
        onEvent(.replaceText(text, active))
    }

    private func join(_ first: String, _ second: String) -> String {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        guard first.last?.isWhitespace != true, second.first?.isWhitespace != true else {
            return first + second
        }
        // Chinese doesn't put spaces between segments; Latin scripts do.
        return active == .chinese ? first + second : first + " " + second
    }

    // MARK: - Turn detection

    private func noteAudio(_ chunk: Data) {
        let speech = Self.isSpeech(chunk)
        if speech {
            if ignoreResultsAfter != nil { resetTurn() }
            if !turnOpen {
                turnOpen = true
                active = nil
                committed = ""
                volatile = ""
            }
            heardSpeech = true
            silenceTimer?.cancel()
            silenceTimer = Task { [weak self] in
                try? await Task.sleep(for: Self.silenceBeforeTurnEnd)
                guard !Task.isCancelled else { return }
                self?.finishTurn()
            }
        } else if heardSpeech, silenceTimer == nil {
            // The timer above only exists while speech is arriving; recreate it
            // for the first quiet chunk after speech.
            silenceTimer = Task { [weak self] in
                try? await Task.sleep(for: Self.silenceBeforeTurnEnd)
                guard !Task.isCancelled else { return }
                self?.finishTurn()
            }
        }
    }

    private func finishTurn() {
        guard turnOpen, heardSpeech else { return }
        heardSpeech = false
        silenceTimer = nil
        if active == nil { resolveLanguage() }
        onEvent(.turnEnded)

        // Final recognition results can arrive just after the audio goes quiet.
        // Keep accepting them for a moment before closing the turn.
        let deadline = ContinuousClock.now + Self.turnEndGrace
        ignoreResultsAfter = deadline
        Task { [weak self] in
            try? await Task.sleep(for: Self.turnEndGrace)
            guard let self, let current = self.ignoreResultsAfter, ContinuousClock.now >= current else { return }
            self.resetTurn()
        }
    }

    /// Picks the recognizer with the longest plausible transcript when neither
    /// claimed the turn, usually for a short utterance.
    private func resolveLanguage() {
        guard active == nil else { return }
        let matching = candidates.filter { Language.detect($0.value, in: languages) == $0.key }
        let pool = matching.isEmpty ? candidates : matching
        guard let best = pool.max(by: { $0.value.count < $1.value.count }), best.value.count >= 4 else { return }
        active = best.key
        committed = ""
        volatile = best.value
        logger.info("turn language \(best.key.rawValue, privacy: .public) resolved at turn end")
        emitText()
    }

    private func resetTurn() {
        turnOpen = false
        heardSpeech = false
        active = nil
        candidates.removeAll()
        committed = ""
        volatile = ""
        loggedTranscript = false
        ignoreResultsAfter = nil
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    // MARK: - Audio

    private static func isSpeech(_ chunk: Data) -> Bool {
        let count = chunk.count / MemoryLayout<Int16>.size
        guard count > 0 else { return false }
        return chunk.withUnsafeBytes { raw -> Bool in
            let samples = raw.bindMemory(to: Int16.self)
            var sum = 0.0
            for sample in samples {
                let value = Double(sample) / 32768
                sum += value * value
            }
            return Float((sum / Double(count)).squareRoot()) > speechThreshold
        }
    }

    private func makeBuffer(from chunk: Data) -> AVAudioPCMBuffer? {
        let frames = chunk.count / MemoryLayout<Int16>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.sourceFormat, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.int16ChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        chunk.withUnsafeBytes { raw in
            if let source = raw.baseAddress {
                memcpy(destination, source, frames * MemoryLayout<Int16>.size)
            }
        }
        return buffer
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    private static func locale(for language: Language, script: ChineseScript) -> Locale {
        guard language == .chinese else { return Locale(identifier: language.rawValue) }
        return Locale(identifier: script == .traditional ? "zh-TW" : "zh-CN")
    }
}

private enum OfflineSpeechError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let language):
            "On-device speech recognition isn't available for \(language) on this device."
        }
    }
}

extension SpeechProvider {
    static let onDevice = SpeechProvider(
        id: "on-device",
        name: "On-device",
        summary: "Apple's speech recognition and translation run on this device. No key, and no audio leaves it.",
        credentials: [],
        options: [],
        languages: Language.appleOnDevice,
        makePipeline: { settings in
            SpeechPipeline(
                engine: OfflineSpeechEngine(languages: settings.languages, script: settings.chineseScript),
                translator: AppleTranslator()
            )
        }
    )
}
