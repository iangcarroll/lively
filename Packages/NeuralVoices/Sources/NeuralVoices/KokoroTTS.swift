import CoreML
import Foundation

/// Internal local CoreML Kokoro implementation. The public actor owns and
/// serializes this model; callers cannot bypass its local-asset policy.
final class KokoroTTSModel {

    /// Default HuggingFace model ID.
    static let defaultModelId = "aufklarer/Kokoro-82M-CoreML"
    /// Default voice preset.
    static let defaultVoice = "af_heart"
    /// Output sample rate.
    static let outputSampleRate = 24000

    let config: KokoroConfig
    var network: KokoroNetwork?
    let phonemizer: KokoroPhonemizer
    var voiceEmbeddings: [String: [Float]]

    var _isLoaded: Bool { network != nil }

    init(config: KokoroConfig, network: KokoroNetwork, phonemizer: KokoroPhonemizer, voiceEmbeddings: [String: [Float]]) {
        self.config = config
        self.network = network
        self.phonemizer = phonemizer
        self.voiceEmbeddings = voiceEmbeddings
    }

    // MARK: - Synthesis

    /// Input slots of the end-to-end graph (`input_ids` is `[1, 128]`).
    static let inputSlots = 128
    /// Token budget per chunk, as in speech-core's 5.0 s Kokoro profile. The
    /// packed-LSTM models speak at upstream Kokoro's rate, about 10.5 phoneme
    /// tokens per second, so a chunk this size stays inside the 5 s graph at
    /// speed 1; the earlier 72 overflowed and split-and-retried.
    static let chunkTokenBudget = 56
    /// No chunk grows past this many tokens, the hard cap of the same
    /// speech-core profile. A merged chunk near the 128-token input would
    /// overrun the 5 s graph at this speech rate and render twice.
    static let chunkTokenHardCap = 64
    /// A last chunk shorter than this merges into the previous one when the
    /// hard cap allows it; very short utterances render unreliably.
    static let minTailTokens = 12
    /// Pieces of an overflow retry never go below this many tokens.
    static let minRetryTokens = 6
    /// How many times one chunk may be split again after an overflow.
    static let maxRetryDepth = 4
    /// The last 200 ms of the bounded graph's output window are not trusted,
    /// as in speech-core: speech reaching into them means the chunk was too
    /// long and is split and rendered again.
    static let outputTailGuardSamples = 4800

    /// Synthesize speech from text.
    ///
    /// The text is split into chunks of up to 56 phoneme tokens, about what
    /// the 5 s graph holds at the models' speech rate, preferring sentence
    /// ends, then clauses, then words. Each chunk renders in one call and the
    /// audio is concatenated, so short text is a single call. A chunk whose
    /// speech would still overrun the graph's output window is split again
    /// and rendered as two pieces.
    func synthesize(
        text: String,
        voice: String = "af_heart",
        language: String = "en",
        speed: Float = 1.0
    ) throws -> [Float] {
        var audio: [Float] = []
        try synthesizeChunks(text: text, voice: voice, language: language, speed: speed) { samples, _ in
            audio.append(contentsOf: samples)
        }
        return audio
    }

    /// Renders `text` chunk by chunk and hands each piece's audio to
    /// `onChunk` as soon as it is ready. Exactly one call, the last, has
    /// `isFinal` set; text with nothing to speak yields one empty final piece.
    func synthesizeChunks(
        text: String,
        voice: String,
        language: String,
        speed: Float,
        onChunk: ([Float], Bool) throws -> Void
    ) throws {
        guard _isLoaded, let network else {
            throw AudioModelError.inferenceFailed(
                operation: "kokoro-synthesize", reason: "Model not loaded")
        }
        guard let styleVector = voiceEmbeddings[voice] else {
            let available = Array(voiceEmbeddings.keys).sorted().prefix(5)
            throw AudioModelError.voiceNotFound(
                voice: voice,
                searchPath: "Available: \(available.joined(separator: ", "))...")
        }

        // Packing measures many overlapping candidates and rendering needs the
        // ids of the pieces it kept; phonemize each piece of text once.
        var tokenCache: [String: [Int]] = [:]
        let tokenIds: (String) -> [Int] = { piece in
            if let ids = tokenCache[piece] { return ids }
            let ids = self.phonemizer.tokenize(piece, maxLength: .max, language: language)
            tokenCache[piece] = ids
            return ids
        }
        // Chunk up front, as speech-core does. Text within the budget is one
        // chunk and renders in one call; rendering longer text whole first
        // would only overrun the 5 s window and cost a discarded pass.
        let chunks = Self.chunkPlan(
            text, countTokens: { tokenIds($0).count },
            capacity: min(config.maxPhonemeLength, Self.inputSlots))

        guard !chunks.isEmpty else {
            try onChunk([], true)
            return
        }
        var emitted = false
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            // An overflow retry can turn one chunk into several pieces; they
            // come back together, so the final piece is known when emitted.
            let pieces = try renderChunk(
                chunk, network: network, style: styleVector, speed: speed,
                tokenIds: tokenIds, depth: 0)
            for (pieceIndex, var piece) in pieces.enumerated() {
                try Task.checkCancellation()
                // A short fade-in keeps the seam between pieces click-free.
                if emitted { fadeIn(&piece) }
                let isFinal = index == chunks.count - 1 && pieceIndex == pieces.count - 1
                try onChunk(piece, isFinal)
                emitted = true
            }
        }
    }

    /// The chunks `text` renders as: packed to `chunkTokenBudget`, with a
    /// short last chunk merged only within `chunkTokenHardCap`.
    static func chunkPlan(
        _ text: String,
        countTokens: (String) -> Int,
        capacity: Int = inputSlots
    ) -> [String] {
        KokoroTextChunker.chunk(
            text, countTokens: countTokens, maxTokens: chunkTokenBudget,
            hardCapTokens: min(chunkTokenHardCap, capacity), minTailTokens: minTailTokens)
    }

    /// Renders one chunk, splitting it again while its speech would overrun
    /// the graph's output window.
    private func renderChunk(
        _ text: String,
        network: KokoroNetwork,
        style: [Float],
        speed: Float,
        tokenIds: (String) -> [Int],
        depth: Int
    ) throws -> [[Float]] {
        let ids = tokenIds(text)
        let capacity = min(config.maxPhonemeLength, Self.inputSlots)
        var unsplit: [Float]?
        if ids.count <= capacity {
            let pass = try runModel(tokenIds: ids, network: network, style: style, speed: speed)
            if !pass.overran { return [pass.audio] }
            unsplit = pass.audio
        }
        if depth < Self.maxRetryDepth, ids.count > Self.minRetryTokens * 2 {
            let pieces = KokoroTextChunker.splitForRetry(
                text, countTokens: { tokenIds($0).count },
                minTokens: Self.minRetryTokens, maxTokens: ids.count - 1)
            if pieces.count == 2 {
                return try pieces.flatMap {
                    try renderChunk(
                        $0, network: network, style: style, speed: speed,
                        tokenIds: tokenIds, depth: depth + 1)
                }
            }
        }
        // No safe split exists: keep what one bounded pass produces.
        if let unsplit { return [unsplit] }
        let clipped = Array(ids.prefix(capacity - 1)) + [phonemizer.eosId]
        return [try runModel(tokenIds: clipped, network: network, style: style, speed: speed).audio]
    }

    /// One pass of the end-to-end graph. `overran` is set when the predicted
    /// speech reaches the untrusted tail of the output window.
    private func runModel(
        tokenIds: [Int],
        network: KokoroNetwork,
        style styleVector: [Float],
        speed: Float
    ) throws -> (audio: [Float], overran: Bool) {
        let padTo = Self.inputSlots
        let tokenCount = min(tokenIds.count, padTo)
        let paddedIds = phonemizer.pad(Array(tokenIds.prefix(padTo)), to: padTo)

        let inputIds = try createInt32Array(shape: [1, padTo], values: paddedIds.map { Int32($0) })
        let maskArray = try createInt32Array(shape: [1, padTo], values: (0..<padTo).map { Int32($0 < tokenCount ? 1 : 0) })
        let refS = try createFloatArray(shape: [1, config.styleDim], values: styleVector)
        let speedArray = try createFloatArray(shape: [1], values: [speed])

        try Task.checkCancellation()
        let result = try network.predictE2E(inputIds: inputIds, attentionMask: maskArray, refS: refS, speed: speedArray)

        try Task.checkCancellation()
        let outputCapacity = result.audio.count
        let overran = outputCapacity > Self.outputTailGuardSamples
            && result.audioLengthSamples > outputCapacity - Self.outputTailGuardSamples
        let validSamples = min(result.audioLengthSamples, outputCapacity)
        guard validSamples > 0 else { return ([], overran) }

        var audio = [Float](repeating: 0, count: validSamples)
        if result.audio.dataType == .float16 {
            let ptr = result.audio.dataPointer.bindMemory(to: Float16.self, capacity: validSamples)
            for i in 0..<validSamples { audio[i] = Float(ptr[i]) }
        } else {
            let ptr = result.audio.dataPointer.bindMemory(to: Float.self, capacity: validSamples)
            for i in 0..<validSamples { audio[i] = ptr[i] }
        }

        // Kokoro's E2E model often emits 100–300 ms of trailing artifacts
        // past the real speech (random low-energy noise + an occasional
        // loud-spike click, observed on iPhone playback). Find where real
        // speech actually ended by walking backwards through 10 ms windows
        // and locating the last window above a silence-energy threshold —
        // then zero everything past that, plus a short ramp-down on the
        // last few ms of real speech to avoid a click at the new boundary.
        // Use a 50 ms window with a higher silence floor and require the
        // window to be SUSTAINED above threshold — Kokoro's trailing
        // artifacts are often a single 10–20 ms spike with low surrounding
        // energy, so a tight short window otherwise mistakes them for
        // speech. Real speech tails consistently above ~0.03 RMS over a
        // 50 ms span; isolated artifact spikes don't. Soft word endings
        // (German "Tisch", "Hamburg") fall under 0.030, so the floor is 0.015;
        // lower values only keep more tail.
        let win = max(1, Int(0.050 * Double(config.sampleRate)))
        let silenceRMS: Float = 0.015
        var speechEnd = validSamples
        var i = validSamples - win
        while i > 0 {
            var sumSq: Float = 0
            for j in 0..<win { let v = audio[i + j]; sumSq += v * v }
            let rms = sqrt(sumSq / Float(win))
            if rms > silenceRMS { speechEnd = i + win; break }
            i -= win / 2  // 50 % overlap so we don't miss a window boundary
        }
        // Zero the trailing artifact region.
        if speechEnd < validSamples {
            for k in speechEnd..<validSamples { audio[k] = 0 }
        }
        // Linear fade-out on the last ~10 ms of the kept signal so the
        // boundary between speech and the silenced region is also smooth.
        let fadeSamples = min(speechEnd, Int(0.010 * Double(config.sampleRate)))
        if fadeSamples >= 2 {
            let start = speechEnd - fadeSamples
            let denom = Float(fadeSamples - 1)
            for k in 0..<fadeSamples {
                let gain = Float(fadeSamples - 1 - k) / denom
                audio[start + k] *= gain
            }
        }
        // The vocoder is not bounded to +-1: the packed-LSTM models occasionally
        // overshoot by a few percent. Clamp so callers get valid float PCM.
        for k in 0..<speechEnd { audio[k] = min(1, max(-1, audio[k])) }

        return (audio, overran)
    }

    /// 5 ms linear fade-in at the start of a piece that follows another.
    private func fadeIn(_ audio: inout [Float]) {
        let count = min(audio.count, config.sampleRate / 200)
        guard count >= 2 else { return }
        for i in 0..<count { audio[i] *= Float(i) / Float(count) }
    }

    /// List available voice presets.
    var availableVoices: [String] {
        Array(voiceEmbeddings.keys).sorted()
    }

    /// Registers custom `word -> IPA` pronunciations for proper nouns missing from
    /// the shipped dictionaries. Resolved ahead of the bundled dictionaries, suffix
    /// stemming, and the neural G2P fallback.
    ///
    /// Keys are matched lowercased and must be single words — a key containing a
    /// space, hyphen, or apostrophe is never looked up, because text is split on
    /// punctuation before resolution. The IPA must use symbols from the model
    /// vocabulary; anything else is dropped at tokenization.
    ///
    /// Entries apply to English only. Passing `language:` zh, ja, it, fr, es, pt,
    /// or hi to `synthesize` selects a phonemizer that never sees them.
    ///
    /// The lookup is unlocked, so register entries before `synthesize` starts
    /// running concurrently on this instance.
    func addPronunciations(_ entries: [String: String]) {
        phonemizer.addPronunciations(entries)
    }

    // MARK: - Helpers

    private func createInt32Array(shape: [Int], values: [Int32]) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: shape.map { $0 as NSNumber }, dataType: .int32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<values.count { ptr[i] = values[i] }
        return arr
    }

    private func createFloatArray(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: shape.map { $0 as NSNumber }, dataType: .float32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<values.count { ptr[i] = values[i] }
        return arr
    }

    // MARK: - Warmup

    /// Warm up CoreML model by running a dummy inference.
    ///
    /// A model's first prediction is slower than subsequent predictions.
    /// This helper never runs implicitly during asset loading.
    func warmUp() throws {
        let voice = voiceEmbeddings[Self.defaultVoice] != nil ? Self.defaultVoice : (availableVoices.first ?? Self.defaultVoice)
        _ = try? synthesize(text: "hello", voice: voice)
    }

    // MARK: - Model Loading

    /// Load only from the provided complete local directory. No network API.
    static func fromLocal(directory: URL, computeUnits: MLComputeUnits = .all) throws -> KokoroTTSModel {
        let phonemizer = try KokoroPhonemizer.loadVocab(from: directory.appendingPathComponent("vocab_index.json"))
        try phonemizer.loadDictionaries(from: directory)
        let encoder = directory.appendingPathComponent("G2PEncoder.mlmodelc")
        let decoder = directory.appendingPathComponent("G2PDecoder.mlmodelc")
        if FileManager.default.fileExists(atPath: encoder.path), FileManager.default.fileExists(atPath: decoder.path) {
            try phonemizer.loadG2PModels(encoderURL: encoder, decoderURL: decoder, vocabURL: directory.appendingPathComponent("g2p_vocab.json"))
        }
        var voices: [String: [Float]] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("voices"), includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let embedding = try loadVoiceEmbedding(from: file, styleDim: KokoroConfig.default.styleDim)
            guard embedding.count == KokoroConfig.default.styleDim, embedding.allSatisfy({ $0.isFinite }) else {
                throw AudioModelError.modelLoadFailed(modelId: "kokoro", reason: "Invalid voice embedding: " + file.lastPathComponent)
            }
            voices[file.deletingPathExtension().lastPathComponent] = embedding
        }
        return KokoroTTSModel(config: .default, network: try KokoroNetwork(directory: directory, computeUnits: computeUnits), phonemizer: phonemizer, voiceEmbeddings: voices)
    }

    /// Load voice embedding from JSON file.
    private static func loadVoiceEmbedding(from url: URL, styleDim: Int) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [Double] else { return [] }
        guard embedding.count == styleDim else { return [] }
        return embedding.map { Float($0) }
    }
}
