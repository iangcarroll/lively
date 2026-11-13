import XCTest
@testable import NeuralVoices

final class FrontendTests: XCTestCase {
    func testJapaneseSupplementaryPrefixPreservesReading() {
        let frontend = JapanesePhonemizer()
        let plain = frontend.phonemize("駅はどこですか。")
        XCTAssertFalse(plain.isEmpty)
        XCTAssertEqual(plain, frontend.phonemize("🚉 駅はどこですか。"))
        XCTAssertFalse(frontend.phonemize("𠮷野さん、駅はどこですか。").isEmpty)
    }

    func testJapaneseCanonicalCombiningCharactersHaveSameReading() {
        let frontend = JapanesePhonemizer()
        XCTAssertEqual(frontend.phonemize("ガラスはどこですか。"), frontend.phonemize("カ\u{3099}ラスはどこですか。"))
        XCTAssertEqual(frontend.phonemize("🚉 カ\u{3099}ラスはどこですか。"), frontend.phonemize("ガラスはどこですか。"))
    }

    func testJapanesePunctuationAndEmptyInput() {
        let frontend = JapanesePhonemizer()
        XCTAssertTrue(frontend.phonemize("").isEmpty)
        XCTAssertTrue(frontend.phonemize("🚉").isEmpty)
        XCTAssertTrue(frontend.phonemize("こんにちは。駅はどこですか？").contains("?"))
    }

    func testChunkingKeepsWordsAndFitsBudget() {
        let input = (1...80).map { "word\($0)" }.joined(separator: " ")
        let chunks = KokoroTextChunker.chunk(input, countTokens: { $0.split(separator: " ").count }, maxTokens: 12, hardCapTokens: 16, minTailTokens: 3)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.flatMap { $0.split(separator: " ").map(String.init) }, input.split(separator: " ").map(String.init))
        XCTAssertTrue(chunks.allSatisfy { $0.split(separator: " ").count <= 16 })
    }

    func testUnbrokenJapaneseChunkingKeepsAllCharacters() {
        let input = String(repeating: "駅はどこですか。", count: 15)
        let chunks = KokoroTextChunker.chunk(input, countTokens: { $0.count }, maxTokens: 20, hardCapTokens: 24, minTailTokens: 3)
        XCTAssertEqual(chunks.joined(), input)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 24 })
    }

    func testJapaneseChunkingPreservesEmojiAndCombiningGraphemes() {
        let input = String(repeating: "🚉カ\u{3099}ラスのドアを通って駅へ。", count: 8)
        let chunks = KokoroTextChunker.chunk(input, countTokens: { $0.count }, maxTokens: 17, hardCapTokens: 17, minTailTokens: 0)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(Array(chunks.joined().unicodeScalars), Array(input.unicodeScalars))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 17 })
        XCTAssertFalse(chunks.contains { $0.unicodeScalars.first?.value == 0x3099 })
    }

    func testRequestRejectsUnsupportedAndMismatchedLanguage() throws {
        XCTAssertEqual(try NeuralVoiceEngine.validateRequest(text: "こんにちは", voiceID: "jf_alpha", language: "ja-JP"), "ja")
        XCTAssertThrowsError(try NeuralVoiceEngine.validateRequest(text: "Hello", voiceID: "af_heart", language: "ko")) {
            XCTAssertEqual($0 as? NeuralVoiceError, .unsupportedLanguage("ko"))
        }
        XCTAssertThrowsError(try NeuralVoiceEngine.validateRequest(text: "Hallo", voiceID: "df_test", language: "de-DE")) {
            XCTAssertEqual($0 as? NeuralVoiceError, .unsupportedLanguage("de"))
        }
        XCTAssertThrowsError(try NeuralVoiceEngine.validateRequest(text: "こんにちは", voiceID: "af_heart", language: "ja")) {
            XCTAssertEqual($0 as? NeuralVoiceError, .voiceLanguageMismatch(voice: "af_heart", language: "ja"))
        }
        XCTAssertThrowsError(try NeuralVoiceEngine.validateRequest(text: "  ", voiceID: "jf_alpha", language: "ja")) {
            XCTAssertEqual($0 as? NeuralVoiceError, .emptyText)
        }
        XCTAssertThrowsError(try NeuralVoiceEngine.validateRequest(text: String(repeating: "あ", count: 4097), voiceID: "jf_alpha", language: "ja")) {
            XCTAssertEqual($0 as? NeuralVoiceError, .textTooLong(maximumCharacters: 4096))
        }
    }

    func testMalformedVocabularyDoesNotReachModelLoading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        for text in ["{}", "{\"a\": 1, \"b\": 1}", "{\"a\": -1}", "{\"a\": 9000000}"] {
            try Data(text.utf8).write(to: url)
            XCTAssertThrowsError(try KokoroPhonemizer.loadVocab(from: url))
        }
    }

    func testInvalidModelAudioLengthsCannotTrapIntegerConversion() throws {
        XCTAssertEqual(try KokoroNetwork.validatedAudioLength(24_000), 24_000)
        for value in [Double.nan, .infinity, -.infinity, -1, 1e20] {
            XCTAssertThrowsError(try KokoroNetwork.validatedAudioLength(value))
        }
    }
}
