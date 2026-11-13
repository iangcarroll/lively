import Foundation

/// Configuration for Kokoro-82M TTS model.
struct KokoroConfig: Codable, Sendable {
    /// Output audio sample rate in Hz.
    let sampleRate: Int
    /// Maximum phoneme input length (E2E model uses fixed 128).
    let maxPhonemeLength: Int
    /// Style embedding dimension (ref_s input to CoreML model).
    let styleDim: Int
    /// Supported languages.
    let languages: [String]

    init(
        sampleRate: Int = 24000,
        maxPhonemeLength: Int = 128,
        styleDim: Int = 256,
        languages: [String] = ["en", "fr", "es", "ja", "zh", "hi", "pt", "it"]
    ) {
        self.sampleRate = sampleRate
        self.maxPhonemeLength = maxPhonemeLength
        self.styleDim = styleDim
        self.languages = languages
    }

    /// Default configuration matching Kokoro-82M.
    static let `default` = KokoroConfig()
}
