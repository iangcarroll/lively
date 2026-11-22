import Testing
@testable import Lively

struct OfflineVoiceSearchTests {
    @Test func findsVoicesByEnglishLocalizedAndNativeLanguageNames() throws {
        let mandarin = try #require(NeuralVoiceCatalog.language(with: "zh"))
        for name in [mandarin.name, mandarin.nativeName, mandarin.displayName, " mandarin "] {
            #expect(mandarin.voices(matching: name) == mandarin.voices)
        }

        let english = try #require(NeuralVoiceCatalog.language(with: "en"))
        let british = english.voices.filter { $0.localeIdentifier == "en-GB" }
        let accent = try #require(british.first?.accent)
        #expect(english.voices(matching: accent) == british)
        #expect(english.voices(matching: "british") == british)
        let voice = try #require(british.first)
        #expect(english.voices(matching: voice.id) == [voice])
        #expect(english.voices(matching: voice.name).contains(voice))
        #expect(english.voices(matching: mandarin.nativeName).isEmpty)
    }
}
