@preconcurrency import AVFoundation
import Foundation
import os

/// Generates speech locally and sends its audio through the directional
/// player. The system synthesizer never plays directly to an output device.
final class OfflineSpeaker {
    var onError: (String) -> Void = { _ in }
    let player = SpeechPlayer()

    private struct Line {
        let text: String
        let language: Language
        let output: SpeechPlayer.Output
    }
    private let renderer: any OfflineSpeechRendering
    private var queue: [Line] = []
    private var worker: Task<Void, Never>?
    private var generation = 0

    init(script: ChineseScript = .simplified) {
        renderer = SystemOfflineSpeechRenderer(script: script)
    }

    /// Allows queue tests without the system speech service or its voices.
    init(renderer: any OfflineSpeechRendering) { self.renderer = renderer }

    static func hasVoice(for language: Language, script: ChineseScript = .simplified) -> Bool {
        voice(for: language, script: script) != nil
    }

    static func voice(for language: Language, script: ChineseScript = .simplified) -> AVSpeechSynthesisVoice? {
        let preferred = language == .chinese ? (script == .traditional ? "zh-TW" : "zh-CN") : language.rawValue
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let locale = Locale(identifier: voice.language)
            let code = locale.language.languageCode?.identifier
            let matches = code == language.rawValue || (language.rawValue == "no" && code == "nb")
            guard matches,
                  !voice.voiceTraits.contains(.isPersonalVoice),
                  !voice.voiceTraits.contains(.isNoveltyVoice),
                  voice.identifier.hasPrefix("com.apple."),
                  AVSpeechSynthesisVoice(identifier: voice.identifier) != nil else { return false }
            // The app's Chinese language is Mandarin, not Cantonese.
            return language != .chinese || locale.region?.identifier != "HK"
        }
        return voices.sorted { first, second in
            let firstMatches = first.language == preferred
            let secondMatches = second.language == preferred
            if firstMatches != secondMatches { return firstMatches }
            if first.quality != second.quality { return first.quality.rawValue > second.quality.rawValue }
            return first.identifier < second.identifier
        }.first
    }

    func speak(_ text: String, in language: Language, output: SpeechPlayer.Output = .automatic) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queue.append(Line(text: text, language: language, output: output))
        guard worker == nil else { return }
        let generation = generation
        worker = Task { [weak self] in await self?.run(generation: generation) }
    }

    func stop() {
        generation += 1
        queue.removeAll()
        worker?.cancel()
        worker = nil
        renderer.stop()
        player.stop()
    }

    private func run(generation: Int) async {
        defer { if generation == self.generation { worker = nil } }
        while generation == self.generation, !Task.isCancelled, !queue.isEmpty {
            let line = queue.removeFirst()
            do {
                // Missing headphones skip private speech before synthesis.
                guard try await player.prepare(output: line.output) else { continue }
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                for try await audio in try renderer.audio(for: line.text, language: line.language) {
                    try Task.checkCancellation()
                    guard generation == self.generation else { return }
                    player.play(audio)
                }
                renderer.stop()
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                queue.removeAll()
                renderer.stop()
                player.stop()
                onError(error.localizedDescription)
                return
            }
        }
    }
}

protocol OfflineSpeechRendering {
    func audio(for text: String, language: Language) throws -> AsyncThrowingStream<Data, Error>
    func stop()
}

private final class SystemOfflineSpeechRenderer: OfflineSpeechRendering {
    private let synthesizer = AVSpeechSynthesizer()
    private let script: ChineseScript
    private var active: OfflineSpeechPCMStream?
    private var timeout: Task<Void, Never>?

    init(script: ChineseScript) { self.script = script }

    deinit {
        timeout?.cancel()
        active?.cancel()
    }

    func audio(for text: String, language: Language) throws -> AsyncThrowingStream<Data, Error> {
        guard let voice = OfflineSpeaker.voice(for: language, script: script) else {
            throw OfflineSpeechOutputError.missingVoice(language.englishName)
        }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let pcm = OfflineSpeechPCMStream(continuation: continuation)
        active = pcm
        synthesizer.write(utterance) { buffer in pcm.accept(buffer) }
        // Failed system services sometimes omit the terminal buffer. Bound
        // the wait so they cannot retain a conversation indefinitely.
        timeout = Task { [weak self, weak pcm] in
            try? await Task.sleep(for: .seconds(max(30, Double(text.count) / 3 + 20)))
            guard !Task.isCancelled, let self, let pcm, self.active === pcm else { return }
            pcm.fail(OfflineSpeechOutputError.noAudio)
            self.synthesizer.stopSpeaking(at: .immediate)
            self.active = nil
        }
        return stream
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        active?.cancel()
        active = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Convert borrowed system buffers on their callback queue and only pass
/// owned PCM bytes to the main actor. The lock also serializes cancellation.
nonisolated final class OfflineSpeechPCMStream: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                       channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var finished = false
    private var producedAudio = false

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func accept(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        guard let input = buffer as? AVAudioPCMBuffer else {
            finish(throwing: OfflineSpeechOutputError.conversion)
            return
        }
        if input.frameLength == 0 {
            if let converter { flush(converter) }
            guard !finished else { return }
            finish(throwing: producedAudio ? nil : OfflineSpeechOutputError.noAudio)
            return
        }
        guard input.format.sampleRate > 0, input.format.channelCount > 0 else {
            finish(throwing: OfflineSpeechOutputError.conversion)
            return
        }
        if converter == nil { converter = AVAudioConverter(from: input.format, to: format) }
        guard let converter, converter.inputFormat == input.format else {
            finish(throwing: OfflineSpeechOutputError.conversion)
            return
        }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            finish(throwing: OfflineSpeechOutputError.conversion)
            return
        }
        let supplied = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let alreadySupplied = supplied.withLock { value in
                let previous = value
                value = true
                return previous
            }
            guard !alreadySupplied else { inputStatus.pointee = .noDataNow; return nil }
            inputStatus.pointee = .haveData
            return input
        }
        guard error == nil, status != .error else {
            finish(throwing: OfflineSpeechOutputError.conversion)
            return
        }
        emit(output)
    }

    func cancel() { fail(CancellationError()) }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finish(throwing: error)
    }

    private func flush(_ converter: AVAudioConverter) {
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
                finish(throwing: OfflineSpeechOutputError.conversion)
                return
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard error == nil, status != .error else {
                finish(throwing: OfflineSpeechOutputError.conversion)
                return
            }
            emit(output)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
    }

    private func emit(_ output: AVAudioPCMBuffer) {
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        producedAudio = true
        continuation.yield(Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
    }

    private func finish(throwing error: Error?) {
        finished = true
        converter = nil
        continuation.finish(throwing: error)
    }
}

private nonisolated enum OfflineSpeechOutputError: LocalizedError {
    case missingVoice(String)
    case conversion
    case noAudio

    var errorDescription: String? {
        switch self {
        case .missingVoice(let language):
            "Download a \(language) voice in the system Accessibility speech settings, then try again."
        case .conversion:
            "Lively couldn't prepare the on-device speech audio. Try speaking the translation again."
        case .noAudio:
            "The on-device voice didn't produce audio. Check the downloaded voices in the system Accessibility speech settings."
        }
    }
}
