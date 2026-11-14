import CoreML
import Foundation

public enum NeuralVoiceError: Error, LocalizedError, Sendable, Equatable {
    case unloaded
    case missingAssets([String])
    case corruptAssets(String)
    case unsupportedLanguage(String)
    case unavailableVoice(String)
    case voiceLanguageMismatch(voice: String, language: String)
    case emptyText
    case textTooLong(maximumCharacters: Int)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unloaded: "The offline voice model is not loaded."
        case .missingAssets(let files): "Offline voice files are missing: \(files.joined(separator: ", "))."
        case .corruptAssets(let detail): "The offline voice files could not be loaded: \(detail)"
        case .unsupportedLanguage(let language): "Offline speech is not supported for \(language)."
        case .unavailableVoice(let voice): "The offline voice \(voice) is not installed."
        case let .voiceLanguageMismatch(voice, language): "Voice \(voice) does not support \(language)."
        case .emptyText: "There is no text to speak."
        case .textTooLong(let maximum): "Split this text into pieces of at most \(maximum) characters."
        case .inferenceFailed(let detail): "Offline speech could not be generated: \(detail)"
        }
    }
}

/// Owns one local CoreML model. Loading and inference execute on this actor,
/// away from the main actor; no model object crosses the isolation boundary.
/// The caller downloads and verifies assets before passing their directory.
public actor NeuralVoiceEngine {
    public nonisolated static let sampleRate = 24_000
    public nonisolated static let maximumTextCharacters = 4_096
    /// Avoids the observed iOS MPSGraph compiler abort for the INT8 graph.
    /// Callers may explicitly select another CoreML route when loading.
    public nonisolated static var defaultComputeUnits: MLComputeUnits {
        #if os(iOS)
        .cpuOnly
        #else
        .all
        #endif
    }
    public nonisolated static var licenseNotices: String {
        ["NOTICE", "Apache-2.0", "ipa-dict-MIT", "pinyin-to-ipa-MIT"].compactMap { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n")
    }
    private var model: KokoroTTSModel?

    public init() {}

    public var isLoaded: Bool { model != nil }
    public var availableVoiceIDs: [String] { model?.availableVoices ?? [] }

    /// Replaces the existing model without retaining two models at once.
    /// No asset lookup, download, system speech synthesis, or fallback occurs.
    public func load(directory: URL, computeUnits: MLComputeUnits = NeuralVoiceEngine.defaultComputeUnits) async throws {
        try Task.checkCancellation()
        model = nil
        do {
            try Self.validateAssets(in: directory)
            let loaded = try KokoroTTSModel.fromLocal(directory: directory, computeUnits: computeUnits)
            try Task.checkCancellation()
            model = loaded
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NeuralVoiceError {
            throw error
        } catch {
            throw NeuralVoiceError.corruptAssets(error.localizedDescription)
        }
    }

    /// Releases this actor's model references. Cancel an active stream first
    /// to let inference reach a cancellation boundary before unloading.
    public func unload() { model = nil }

    public func synthesize(text: String, voiceID: String, language: String) async throws -> [Float] {
        let language = try Self.validateRequest(text: text, voiceID: voiceID, language: language)
        try Task.checkCancellation()
        guard let model else { throw NeuralVoiceError.unloaded }
        guard model.availableVoices.contains(voiceID) else { throw NeuralVoiceError.unavailableVoice(voiceID) }
        do {
            let audio = try model.synthesize(text: text, voice: voiceID, language: language)
            try Task.checkCancellation()
            guard !audio.isEmpty, audio.allSatisfy(\.isFinite) else {
                throw NeuralVoiceError.inferenceFailed("The model returned empty or non-finite audio.")
            }
            return audio
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NeuralVoiceError {
            throw error
        } catch {
            throw NeuralVoiceError.inferenceFailed(error.localizedDescription)
        }
    }

    /// Produces complete chunks without dropping samples. A bounded text
    /// request limits retained audio; consumers must cancel when stopping.
    /// Cancellation is checked before and after every CoreML prediction and
    /// before each chunk is delivered. A prediction already running finishes
    /// before its result is discarded; CoreML has no synchronous abort API.
    public nonisolated func stream(text: String, voiceID: String, language: String) -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let task = Task { [weak self] in
            guard let self else { continuation.finish(throwing: NeuralVoiceError.unloaded); return }
            await self.generate(text: text, voiceID: voiceID, language: language, into: continuation)
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func generate(text: String, voiceID: String, language: String,
                          into continuation: AsyncThrowingStream<[Float], Error>.Continuation) {
        do {
            let language = try Self.validateRequest(text: text, voiceID: voiceID, language: language)
            try Task.checkCancellation()
            guard let model else { throw NeuralVoiceError.unloaded }
            guard model.availableVoices.contains(voiceID) else { throw NeuralVoiceError.unavailableVoice(voiceID) }
            var produced = false
            try model.synthesizeChunks(text: text, voice: voiceID, language: language, speed: 1) { audio, _ in
                try Task.checkCancellation()
                guard !audio.isEmpty, audio.allSatisfy(\.isFinite) else {
                    throw NeuralVoiceError.inferenceFailed("The model returned empty or non-finite audio.")
                }
                produced = true
                if case .terminated = continuation.yield(audio) { throw CancellationError() }
            }
            try Task.checkCancellation()
            guard produced else { throw NeuralVoiceError.inferenceFailed("The model returned no audio.") }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch let error as NeuralVoiceError {
            continuation.finish(throwing: error)
        } catch {
            continuation.finish(throwing: NeuralVoiceError.inferenceFailed(error.localizedDescription))
        }
    }

    nonisolated static func validateRequest(text: String, voiceID: String, language: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NeuralVoiceError.emptyText }
        guard text.count <= maximumTextCharacters else { throw NeuralVoiceError.textTooLong(maximumCharacters: maximumTextCharacters) }
        let language = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard ["en", "ja", "zh", "es", "fr", "hi", "it", "pt"].contains(language) else {
            throw NeuralVoiceError.unsupportedLanguage(language)
        }
        let prefixes: [String: Set<Character>] = [
            "en": ["a", "b"], "ja": ["j"], "zh": ["z"], "es": ["e"],
            "fr": ["f"], "hi": ["h"], "it": ["i"], "pt": ["p"]
        ]
        guard let first = voiceID.first, prefixes[language]?.contains(first) == true else {
            throw NeuralVoiceError.voiceLanguageMismatch(voice: voiceID, language: language)
        }
        return language
    }

    nonisolated private static func validateAssets(in directory: URL) throws {
        let files = ["kokoro_5s.mlmodelc/model.mil", "kokoro_5s.mlmodelc/coremldata.bin",
                     "kokoro_5s.mlmodelc/weights/weight.bin", "vocab_index.json", "voices"]
        let missing = files.filter { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        guard missing.isEmpty else { throw NeuralVoiceError.missingAssets(missing) }
        var isDirectory: ObjCBool = false
        let voicesURL = directory.appendingPathComponent("voices")
        guard FileManager.default.fileExists(atPath: voicesURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NeuralVoiceError.corruptAssets("The voices directory is invalid.")
        }
        let voices = try FileManager.default.contentsOfDirectory(at: voicesURL, includingPropertiesForKeys: nil)
        guard voices.contains(where: { $0.pathExtension == "json" }) else {
            throw NeuralVoiceError.missingAssets(["voices/*.json"])
        }
        for file in files where file != "voices" {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
                throw NeuralVoiceError.corruptAssets("Empty file: \(file)")
            }
        }
    }
}
