package sh.ian.lively.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.UUID

sealed interface TranslationState {
    /** Nothing translated yet. */
    data object Idle : TranslationState
    /** A request is running. */
    data object Working : TranslationState
    /** The translation matches the current transcript. */
    data object Current : TranslationState
    /** Waiting for the network to come back. */
    data object WaitingForNetwork : TranslationState
    /**
     * Speech is visible, but its language or translation destination is
     * still being identified. This is not a failed translation request.
     */
    data object AwaitingPartner : TranslationState
    data class Failed(val message: String) : TranslationState
}

/** One turn of speech and its translation. Its fields are Compose state. */
class Utterance private constructor(
    private val automaticListener: Language?,
    /** The Automatic conversation this turn belongs to, or null with a pair. */
    val automaticSessionID: String?,
    /** The conversation's languages when this turn was spoken. */
    val languages: LanguagePair,
) {
    constructor(languages: LanguagePair, source: String = "", language: Language? = null) : this(null, null, languages) {
        if (source.isNotEmpty()) append(source)
        if (language != null) this.language = language
    }

    val id: String = UUID.randomUUID().toString()
    val createdAt: Long = System.currentTimeMillis()

    var source by mutableStateOf("")
        private set
    var language by mutableStateOf(languages.first)
        private set
    private var automaticSource by mutableStateOf<Language?>(null)
    private var automaticTarget by mutableStateOf<Language?>(null)
    /** Backfilled questions stay readable without being spoken after an answer. */
    var suppressesAutomaticSpeech = false
    var wasAwaitingPartner = false
    var isExplicitTranslationRequest = false
    /** Provider completion is distinct from closing the local listening UI. */
    var isAutomaticSourceFinal = false
    var hasFinalAutomaticLanguage = false
    /**
     * An unbound live reply can still know its conversation partner; its
     * destination is captured only after the source is complete.
     */
    var waitsForAutomaticPartner by mutableStateOf(false)
    var translation by mutableStateOf("")
    var translationState by mutableStateOf<TranslationState>(TranslationState.Idle)

    /** True once the speaker's turn has ended and the transcript won't change. */
    var isFinal by mutableStateOf(false)

    /**
     * Spoken during a network dropout and transcribed after it, so it may
     * show up after later turns' translations.
     */
    var isLate by mutableStateOf(false)

    /**
     * Translated as text: typed, edited, or retried after an interrupted
     * native translation.
     */
    var isTyped = false

    /**
     * Paired speech segments keep their provider-owned translation until an
     * explicit retry or edit selects text translation through [isTyped].
     */
    var usesNativeTranslation = false

    /** A native event confirmed translated speech before resolving its source. */
    var isTranslationOnly by mutableStateOf(false)

    /** The transcript the current [translation] was produced from. */
    var translatedSource: String? = null
    /**
     * The source language used for that translation. A revised language tag
     * changes the translation direction even when the words stay identical.
     */
    var translatedLanguage: Language? = null
    var translatedTarget: Language? = null

    val isAutomatic: Boolean get() = automaticListener != null
    val listenerLanguage: Language get() = automaticListener ?: languages.first
    val sourceLanguage: Language? get() = if (isAutomatic) automaticSource else language
    val otherLanguage: Language?
        get() {
            sourceLanguage?.let { if (it != listenerLanguage) return it }
            return target?.takeIf { it != listenerLanguage }
        }
    val isAwaitingLanguage: Boolean
        get() = isAutomatic && !isSourceOnly && (target == null || (sourceLanguage == null && translation.isEmpty()))
    /** Original words whose native translation is represented separately. */
    val isSourceOnly: Boolean
        get() = isAutomatic && sourceLanguage != null && sourceLanguage != listenerLanguage && target == null
    val listenerText: String
        get() = when {
            sourceLanguage == listenerLanguage -> trimmedSource
            target == listenerLanguage -> translation
            else -> ""
        }
    val partnerText: String
        get() {
            val source = sourceLanguage
            if (source != null && source != listenerLanguage) return trimmedSource
            if (source == null && target == listenerLanguage) return trimmedSource
            return if (target != null && target != listenerLanguage) translation else ""
        }

    /**
     * A destination is captured once. Later partner-language discoveries only
     * affect new turns. A corrected source may replace its unfinished direction.
     */
    fun bindAutomaticTarget(target: Language): Boolean {
        if (!isAutomatic || automaticTarget != null) return false
        automaticTarget = target
        return true
    }

    fun correctAutomaticTarget(target: Language?) {
        if (isAutomatic) automaticTarget = target
    }

    fun append(delta: String) = setSource(source + delta, language = null)

    /** Replaces the transcript, for engines that revise provisional words. */
    fun setSource(text: String, language: Language?) {
        isTranslationOnly = false
        source = text
        if (isAutomatic) {
            if (automaticSource != language) {
                translation = ""
                translationState = TranslationState.AwaitingPartner
            }
            automaticSource = language
            if (language != null) this.language = language
            return
        }
        val resolved = language?.takeIf { it in languages } ?: LanguageDetector.detect(source, languages) ?: this.language
        if (resolved != this.language) {
            translation = ""
            translationState = TranslationState.Idle
        }
        this.language = resolved
    }

    /** The transcript without filler words. This is what's shown and translated. */
    val trimmedSource: String
        get() = sourceLanguage?.let { Filler.strip(source, it) } ?: source.trim()

    /** The language the translation is in. */
    val target: Language? get() = if (isAutomatic) automaticTarget else languages.other(language)

    /**
     * A confirmed translation can be useful before its source words are
     * resolved. Nonempty raw filler still stays hidden.
     */
    val hasContent: Boolean
        get() = trimmedSource.isNotEmpty() || (isTranslationOnly && source.isBlank() && translation.isNotBlank())

    val needsTranslation: Boolean
        get() {
            val sourceLanguage = sourceLanguage
            if (target == null || sourceLanguage == null) return false
            return translatedSource != trimmedSource || translatedLanguage != sourceLanguage ||
                (isAutomatic && translatedTarget != target)
        }

    /**
     * Text to show for a given language: the transcript if that's what was
     * spoken, otherwise the translation.
     */
    fun text(lang: Language): String = when (lang) {
        sourceLanguage -> trimmedSource
        target -> translation
        else -> ""
    }

    companion object {
        /** A turn of an Automatic conversation, whose source or target may not be known yet. */
        fun automatic(
            source: String = "",
            language: Language? = null,
            target: Language? = null,
            listenerLanguage: Language,
            sessionID: String,
        ): Utterance {
            val other = language?.takeIf { it != listenerLanguage } ?: target?.takeIf { it != listenerLanguage }
            // Compatibility snapshot for the manual layout. Automatic rendering
            // uses the explicit optional direction and never treats this as a target.
            val utterance = Utterance(listenerLanguage, sessionID, LanguagePair(listenerLanguage, other ?: Language("und")))
            utterance.language = language ?: listenerLanguage
            utterance.automaticSource = language
            utterance.automaticTarget = target
            utterance.waitsForAutomaticPartner = language == listenerLanguage && target == null
            utterance.source = source
            if (language == null || target == null) utterance.translationState = TranslationState.AwaitingPartner
            return utterance
        }
    }
}
