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
        /// Speech is visible, but its language or translation destination is
        /// still being identified. This is not a failed translation request.
        case awaitingPartner
        case failed(String)
    }

    let id = UUID()
    let createdAt = Date()

    /// The conversation's languages when this turn was spoken.
    let languages: LanguagePair
    private(set) var source: String = ""
    private(set) var language: Language
    private var automaticListener: Language?
    private var automaticSource: Language?
    private var automaticTarget: Language?
    private(set) var automaticSessionID: UUID?
    /// Backfilled questions stay readable without being spoken after an answer.
    var suppressesAutomaticSpeech = false
    var wasAwaitingPartner = false
    var isExplicitTranslationRequest = false
    /// Provider completion is distinct from closing the local listening UI.
    var isAutomaticSourceFinal = false
    var hasFinalAutomaticLanguage = false
    /// An unbound live reply can still know its conversation partner; its
    /// destination is captured only after the source is complete.
    var waitsForAutomaticPartner = false
    var translation: String = ""
    var translationState: TranslationState = .idle

    /// True once the speaker's turn has ended and the transcript won't change.
    var isFinal = false

    /// Audio buffered while connecting or offline and transcribed later.
    var isLate = false

    /// Translated as text: typed, edited, or retried after an interrupted
    /// native translation.
    var isTyped = false

    /// A native event confirmed translated speech before resolving its source.
    var isTranslationOnly = false

    /// Transcribed on-device during a network outage. The server can replay
    /// the matching audio after connectivity returns and replace these turns.
    var isProvisional = false

    /// The transcript the current `translation` was produced from.
    var translatedSource: String?
    /// The source language used for that translation. A revised language tag
    /// changes the translation direction even when the words stay identical.
    var translatedLanguage: Language?
    var translatedTarget: Language?

    init(source: String = "", language: Language? = nil, languages: LanguagePair) {
        self.languages = languages
        self.language = languages.first
        if !source.isEmpty { append(source) }
        if let language { self.language = language }
    }

    init(automaticSource source: String = "", language: Language? = nil, target: Language? = nil,
         listenerLanguage: Language, sessionID: UUID) {
        let other = language.flatMap { $0 != listenerLanguage ? $0 : nil }
            ?? target.flatMap { $0 != listenerLanguage ? $0 : nil }
        // Compatibility snapshot for the manual layout. Automatic rendering
        // uses the explicit optional direction and never treats this as a target.
        languages = LanguagePair(first: listenerLanguage, second: other ?? Language("und"))
        self.language = language ?? listenerLanguage
        automaticListener = listenerLanguage
        automaticSource = language
        automaticTarget = target
        automaticSessionID = sessionID
        waitsForAutomaticPartner = language == listenerLanguage && target == nil
        self.source = source
        if language == nil || target == nil { translationState = .awaitingPartner }
    }

    var isAutomatic: Bool { automaticListener != nil }
    var listenerLanguage: Language { automaticListener ?? languages.first }
    var sourceLanguage: Language? {
        if isAutomatic { return automaticSource }
        return language
    }
    var otherLanguage: Language? {
        if let sourceLanguage, sourceLanguage != listenerLanguage { return sourceLanguage }
        return target.flatMap { $0 != listenerLanguage ? $0 : nil }
    }
    var isAwaitingLanguage: Bool {
        isAutomatic && !isSourceOnly && (target == nil || (sourceLanguage == nil && translation.isEmpty))
    }
    /// Original words whose native translation is represented separately.
    var isSourceOnly: Bool {
        isAutomatic && sourceLanguage != nil && sourceLanguage != listenerLanguage && target == nil
    }
    var listenerText: String {
        sourceLanguage == listenerLanguage ? trimmedSource : (target == listenerLanguage ? translation : "")
    }
    var partnerText: String {
        if let sourceLanguage, sourceLanguage != listenerLanguage { return trimmedSource }
        if sourceLanguage == nil, target == listenerLanguage { return trimmedSource }
        return target.map { $0 != listenerLanguage ? translation : "" } ?? ""
    }

    /// A destination is captured once. Later partner-language discoveries only
    /// affect new turns. A corrected source may replace its unfinished direction.
    @discardableResult
    func bindAutomaticTarget(_ target: Language) -> Bool {
        guard isAutomatic, automaticTarget == nil else { return false }
        automaticTarget = target
        return true
    }

    func correctAutomaticTarget(_ target: Language?) {
        guard isAutomatic else { return }
        automaticTarget = target
    }

    func append(_ delta: String) {
        setSource(source + delta, language: nil)
    }

    /// Replaces the transcript, for engines that revise provisional words.
    func setSource(_ text: String, language: Language?) {
        isTranslationOnly = false
        source = text
        if isAutomatic {
            if automaticSource != language {
                translation = ""
                translationState = .awaitingPartner
            }
            automaticSource = language
            if let language { self.language = language }
            return
        }
        let resolved = language.flatMap { languages.contains($0) ? $0 : nil }
            ?? Language.detect(source, in: languages) ?? self.language
        if resolved != self.language {
            translation = ""
            translationState = .idle
        }
        self.language = resolved
    }

    /// The transcript without filler words. This is what's shown and translated.
    var trimmedSource: String {
        guard let sourceLanguage else { return source.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Filler.strip(source, in: sourceLanguage)
    }

    /// The language the translation is in.
    var target: Language? {
        if isAutomatic { return automaticTarget }
        return languages.other(than: language)
    }

    /// A confirmed translation can be useful before its source words are
    /// resolved. Nonempty raw filler still stays hidden.
    var hasContent: Bool {
        if !trimmedSource.isEmpty { return true }
        return isTranslationOnly && source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var needsTranslation: Bool {
        guard target != nil, let sourceLanguage else { return false }
        return translatedSource != trimmedSource || translatedLanguage != sourceLanguage
            || (isAutomatic && translatedTarget != target)
    }

    /// Text to show for a given language: the transcript if that's what was
    /// spoken, otherwise the translation.
    func text(in lang: Language) -> String {
        if lang == sourceLanguage { return trimmedSource }
        return lang == target ? translation : ""
    }
}
