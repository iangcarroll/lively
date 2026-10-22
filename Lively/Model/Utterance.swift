import Foundation
import Observation

/// One turn of speech and its translation.
@Observable
final class Utterance: Identifiable {
    enum TranslationState: Equatable {
        /// Nothing translated yet.
        case idle
        /// A request is running.
        case working
        /// The translation matches the current transcript.
        case current
        /// Waiting for the network to come back.
        case waitingForNetwork
        case failed(String)
    }

    let id = UUID()
    let createdAt = Date()

    private(set) var source: String = ""
    private(set) var language: Language = .english
    var translation: String = ""
    var translationState: TranslationState = .idle

    /// True once the speaker's turn has ended and the transcript won't change.
    var isFinal = false

    /// Spoken during a network dropout and transcribed after it, so it may
    /// show up after later turns' translations.
    var isLate = false

    /// The transcript the current `translation` was produced from.
    var translatedSource: String?

    init(source: String = "", language: Language? = nil) {
        if !source.isEmpty { append(source) }
        if let language { self.language = language }
    }

    func append(_ delta: String) {
        source += delta
        if let detected = Language.detect(source) { language = detected }
    }

    /// Replaces the transcript, for engines that revise provisional words.
    func setSource(_ text: String, language: Language?) {
        source = text
        if let language { self.language = language } else if let detected = Language.detect(source) { self.language = detected }
    }

    /// The transcript without filler words. This is what's shown and translated.
    var trimmedSource: String { Filler.strip(source) }

    /// False while the turn is empty or only filler so far.
    var hasContent: Bool { !trimmedSource.isEmpty }

    var needsTranslation: Bool { translatedSource != trimmedSource }

    /// Text to show for a given language: the transcript if that's what was
    /// spoken, otherwise the translation.
    func text(in lang: Language) -> String {
        lang == language ? trimmedSource : translation
    }
}
