import AVFoundation
import Foundation
import CoreMedia
import Speech
import os

/// On-device speech recognition with Apple's Speech framework, the listening
/// half of the offline fallback. Translation stays with `AppleTranslator`, so
/// this engine reports transcript updates plus turn boundaries and leaves the
/// translation to `ConversationStore`.
///
/// The speaker is selected explicitly: a fixed-locale recognizer cannot reliably
/// identify which of two languages was spoken. Everything is local: no audio or
/// text leaves the device.
final class OfflineSpeechEngine: SpeechEngine {
    var onEvent: (SpeechEvent) -> Void = { _ in }
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    var networkAvailable = true
    /// This engine holds the boundary itself while final ASR results arrive.
    var textLag: Duration { .zero }

    private let script: ChineseScript
    private let spokenLanguage: Language

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
    private var inputFrames: Int64 = 0
    private var turnStartTime = CMTime.zero
    /// Audio heard while the analyzers and language assets are starting up.
    private var pendingAudio: [Data] = []
    private static let maxPendingChunks = 375 // 30 s of 80 ms chunks

    /// The language of the current turn, once a recognizer has plausible text.
    private var active: Language?
    /// Finalized text of the current turn, and the volatile tail after it.
    private var committed = ""
    private var volatile = ""
    private var finalizedThrough = CMTime.negativeInfinity
    /// A turn is receiving audio or waiting for its final results.
    private var turnOpen = false
    /// Results are ignored after this instant, once a turn's grace has passed.
    private var ignoreResultsAfter: ContinuousClock.Instant?
    private var heardSpeech = false
    private var silenceTimer: Task<Void, Never>?
    private var closingTurn: Task<Void, Never>?
    private var turnID = 0
    private var loggedTranscript = false
    private let logger = Logger(subsystem: "sh.ian.lively", category: "offline")

    init(languages: LanguagePair, script: ChineseScript, spokenLanguage: Language? = nil) {
        self.script = script
        let chosen = spokenLanguage ?? languages.first
        self.spokenLanguage = languages.contains(chosen) ? chosen : languages.first
    }

    deinit {
        startTask?.cancel()
        silenceTimer?.cancel()
        closingTurn?.cancel()
        resultTasks.values.forEach { $0.cancel() }
        inputs.values.forEach { $0.finish() }
        let analyzers = Array(analyzers.values)
        Task {
            for analyzer in analyzers { await analyzer.cancelAndFinishNow() }
        }
    }

    // MARK: - SpeechEngine

    func start() {
        guard !isRunning, startTask == nil else { return }
        let runID = self.runID
        startTask = Task { [weak self] in
            await self?.setUp(runID: runID)
        }
        onStatus(.connecting)
    }

    func stop() {
        tearDown()
        onStatus(.idle)
    }

    private func tearDown() {
        runID += 1
        startTask?.cancel()
        startTask = nil
        isRunning = false
        inputFrames = 0
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
        let startTime = CMTime(value: inputFrames, timescale: Int32(Self.sampleRate))
        inputFrames += Int64(chunk.count / MemoryLayout<Int16>.size)
        noteAudio(chunk, startTime: startTime)

        for language in [spokenLanguage] {
            guard let continuation = inputs[language],
                  let buffer = makeBuffer(from: chunk) else { continue }
            guard let (converter, format) = converters[language] else { continue }
            if format.isEqual(Self.sourceFormat) {
                continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: startTime))
            } else if let converted = convert(buffer, using: converter, to: format) {
                continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
            }
            // A failed conversion must never send the source buffer to an
            // analyzer configured for a different sample rate or PCM format.
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
        // Resources stay local until the whole setup succeeds. A stopped task
        // can clean up after an await without touching a newer run's analyzer.
        var stagedAnalyzer: SpeechAnalyzer?
        var stagedInput: AsyncStream<AnalyzerInput>.Continuation?
        defer {
            if runID == self.runID { startTask = nil }
            stagedInput?.finish()
            if let analyzer = stagedAnalyzer {
                Task { await analyzer.cancelAndFinishNow() }
            }
        }
        do {
            guard !Task.isCancelled, runID == self.runID else { return }
            guard SpeechTranscriber.isAvailable else { throw OfflineSpeechError.unavailable }
            let language = spokenLanguage
            let locale = Self.locale(for: language, script: script)
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw OfflineSpeechError.unsupported(language.englishName)
            }
            guard !Task.isCancelled, runID == self.runID else { return }
            let transcriber = Self.makeTranscriber(locale: supported)
            let status = await AssetInventory.status(forModules: [transcriber])
            guard !Task.isCancelled, runID == self.runID else { return }
            guard status != .unsupported else { throw OfflineSpeechError.unsupported(language.englishName) }
            guard status == .installed else { throw OfflineSpeechError.notDownloaded(language.englishName) }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? Self.sourceFormat
            guard !Task.isCancelled, runID == self.runID else { return }
            guard let converter = AVAudioConverter(from: Self.sourceFormat, to: format) else {
                throw OfflineSpeechError.audioFormat
            }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
                bufferingPolicy: .bufferingNewest(Self.maxPendingChunks)
            )
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            stagedAnalyzer = analyzer
            stagedInput = continuation
            try await analyzer.start(inputSequence: stream)
            guard !Task.isCancelled, runID == self.runID else { return }

            transcribers[language] = transcriber
            analyzers[language] = analyzer
            inputs[language] = continuation
            converters[language] = (converter, format)
            stagedAnalyzer = nil
            stagedInput = nil
            isRunning = true
            startResults(runID: runID)
            let pending = pendingAudio
            pendingAudio.removeAll()
            for chunk in pending {
                guard !Task.isCancelled, runID == self.runID else { return }
                feed(chunk)
            }
            guard !Task.isCancelled, runID == self.runID else { return }
            onStatus(.live)
            logger.info("on-device recognizer ready for \(language.rawValue, privacy: .public)")
        } catch is CancellationError {
            guard runID == self.runID else { return }
            tearDown()
            onStatus(.idle)
        } catch {
            guard runID == self.runID else { return }
            tearDown()
            logger.error("on-device recognizer unavailable: \(error.localizedDescription, privacy: .public)")
            onStatus(.failed(error.localizedDescription))
        }
    }

    private func startResults(runID: Int) {
        for (language, transcriber) in transcribers {
            resultTasks[language] = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, !Task.isCancelled, runID == self.runID else { return }
                        self.handle(result, from: language)
                    }
                } catch is CancellationError {
                    // The analyzer was cancelled while stopping.
                } catch {
                    guard let self, runID == self.runID, self.isRunning else { return }
                    self.tearDown()
                    self.onStatus(.failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Results

    private func handle(_ result: SpeechTranscriber.Result, from language: Language) {
        guard isRunning, turnOpen else { return }
        if let ignoreResultsAfter, ContinuousClock.now >= ignoreResultsAfter { return }

        // A result from the previous turn may arrive after new speech opens
        // another one. Keep only words whose audio belongs to this turn.
        let lowerBound = max(turnStartTime, finalizedThrough)
        guard result.range.end > lowerBound else { return }
        var attributed = result.text
        if result.range.start < lowerBound {
            let range = CMTimeRange(start: lowerBound, end: result.range.end)
            guard let kept = attributed.rangeOfAudioTimeRangeAttributes(intersecting: range) else { return }
            attributed = AttributedString(attributed[kept])
        }
        let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard language == spokenLanguage else { return }
        active = language

        if result.isFinal {
            appendFinal(text)
            finalizedThrough = result.range.end
            volatile = ""
        } else {
            guard text != volatile else { return }
            volatile = text
        }
        emitText()
    }

    private func appendFinal(_ text: String) {
        committed = join(committed, text)
    }

    private func emitText() {
        let text = join(committed, volatile)
        guard !text.isEmpty else { return }
        if !loggedTranscript {
            loggedTranscript = true
            logger.info("on-device transcript received (\(text.count, privacy: .public) chars)")
        }
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

    private func noteAudio(_ chunk: Data, startTime: CMTime) {
        let speech = Self.isSpeech(chunk)
        if speech {
            if ignoreResultsAfter != nil { closeTurn() }
            if !turnOpen {
                turnOpen = true
                active = nil
                committed = ""
                volatile = ""
                turnStartTime = startTime
                onEvent(.turnStarted)
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

        let runID = self.runID
        let boundary = CMTime(value: inputFrames, timescale: Int32(Self.sampleRate))
        for analyzer in analyzers.values {
            Task { [weak self] in
                do { try await analyzer.finalize(through: boundary) }
                catch {
                    guard let self, runID == self.runID, self.isRunning else { return }
                    self.tearDown()
                    self.onStatus(.failed(error.localizedDescription))
                }
            }
        }

        // Final recognition results can arrive just after the audio goes quiet.
        // Keep accepting them for a moment before closing the turn.
        let deadline = ContinuousClock.now + Self.turnEndGrace
        ignoreResultsAfter = deadline
        let turnID = self.turnID
        closingTurn = Task { [weak self] in
            try? await Task.sleep(for: Self.turnEndGrace)
            guard let self, !Task.isCancelled, turnID == self.turnID,
                  let current = self.ignoreResultsAfter, ContinuousClock.now >= current else { return }
            self.closeTurn()
        }
    }

    private func closeTurn() {
        guard turnOpen else { return }
        resetTurn()
        onEvent(.turnEnded)
    }

    private func resetTurn() {
        turnID += 1
        closingTurn?.cancel()
        closingTurn = nil
        turnOpen = false
        heardSpeech = false
        active = nil
        committed = ""
        volatile = ""
        finalizedThrough = .negativeInfinity
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
        return error == nil && output.frameLength > 0 ? output : nil
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    }

    static func locale(for language: Language, script: ChineseScript) -> Locale {
        guard language == .chinese else { return Locale(identifier: language.rawValue) }
        return Locale(identifier: script == .traditional ? "zh-TW" : "zh-CN")
    }
}

private enum OfflineSpeechError: LocalizedError {
    case unavailable
    case unsupported(String)
    case notDownloaded(String)
    case audioFormat

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "On-device speech recognition isn't available on this device."
        case .unsupported(let language):
            "On-device speech recognition isn't available for \(language) on this device."
        case .notDownloaded(let language):
            "\(language) speech recognition isn't downloaded. Open Settings > Offline Languages while online to download it."
        case .audioFormat:
            "The microphone audio couldn't be converted for on-device speech recognition."
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
                engine: OfflineSpeechEngine(languages: settings.languages, script: settings.chineseScript, spokenLanguage: settings.offlineSpokenLanguage),
                translator: AppleTranslator()
            )
        }
    )
}
