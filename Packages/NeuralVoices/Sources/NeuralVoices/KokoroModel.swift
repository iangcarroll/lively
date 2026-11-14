import CoreML
import Foundation

/// CoreML wrapper for Kokoro-82M end-to-end TTS inference.
///
/// Loads a single pre-compiled `kokoro_5s.mlmodelc` that runs the full pipeline
/// (BERT → duration → alignment → prosody → decoder) in one CoreML call.
class KokoroNetwork {

    private let e2eModel: MLModel

    /// Load E2E CoreML model from cache directory.
    init(directory: URL, computeUnits: MLComputeUnits = .all) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        let e2eNames = ["kokoro_5s", "kokoro_10s", "kokoro_15s", "kokoro"]
        var loaded: MLModel?
        for name in e2eNames {
            let url = directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                loaded = try MLModel(contentsOf: url, configuration: config)
                break
            }
        }

        guard let model = loaded else {
            throw AudioModelError.modelLoadFailed(
                modelId: "kokoro",
                reason: "No Kokoro E2E model found in \(directory.path)")
        }
        e2eModel = model
    }

    // MARK: - E2E Inference

    struct E2EOutput {
        let audio: MLMultiArray
        let audioLengthSamples: Int
        let predDur: MLMultiArray
    }

    func predictE2E(
        inputIds: MLMultiArray,
        attentionMask: MLMultiArray,
        refS: MLMultiArray,
        speed: MLMultiArray? = nil
    ) throws -> E2EOutput {
        let randomPhases = try MLMultiArray(shape: [1, 9], dataType: .float32)
        for i in 0..<9 { randomPhases[i] = NSNumber(value: Float.random(in: 0..<1)) }

        let speedInput = speed ?? {
            let s = try! MLMultiArray(shape: [1], dataType: .float32)
            s[0] = NSNumber(value: Float(1.0))
            return s
        }()

        let dict: [String: MLFeatureValue] = [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "attention_mask": MLFeatureValue(multiArray: attentionMask),
            "ref_s": MLFeatureValue(multiArray: refS),
            "random_phases": MLFeatureValue(multiArray: randomPhases),
            "speed": MLFeatureValue(multiArray: speedInput),
        ]

        let input = try MLDictionaryFeatureProvider(dictionary: dict)
        try Task.checkCancellation()
        let output = try e2eModel.prediction(from: input)
        try Task.checkCancellation()

        guard let audio = output.featureValue(for: "audio")?.multiArrayValue,
              let audioLen = output.featureValue(for: "audio_length_samples")?.multiArrayValue,
              let predDur = output.featureValue(for: "pred_dur")?.multiArrayValue else {
            throw AudioModelError.inferenceFailed(
                operation: "kokoro-e2e", reason: "Missing output tensors")
        }

        let rawLength: Double
        if audioLen.dataType == .float16 {
            rawLength = Double(audioLen.dataPointer.assumingMemoryBound(to: Float16.self).pointee)
        } else if audioLen.dataType == .int32 {
            rawLength = Double(audioLen.dataPointer.assumingMemoryBound(to: Int32.self).pointee)
        } else {
            rawLength = Double(audioLen.dataPointer.assumingMemoryBound(to: Float.self).pointee)
        }
        let lengthSamples = try Self.validatedAudioLength(rawLength)
        return E2EOutput(audio: audio, audioLengthSamples: lengthSamples, predDur: predDur)
    }

    static func validatedAudioLength(_ value: Double) throws -> Int {
        guard value.isFinite, value >= 0, value <= 10_000_000 else {
            throw AudioModelError.inferenceFailed(operation: "kokoro-e2e", reason: "Invalid audio length tensor")
        }
        return Int(value)
    }
}
