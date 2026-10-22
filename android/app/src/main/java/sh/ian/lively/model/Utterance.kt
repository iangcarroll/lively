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
    data class Failed(val message: String) : TranslationState
}

/** One turn of speech and its translation. Its fields are Compose state. */
class Utterance(
    /** The conversation's languages when this turn was spoken. */
    val languages: LanguagePair,
    source: String = "",
    language: Language? = null,
) {
    val id: String = UUID.randomUUID().toString()
    val createdAt: Long = System.currentTimeMillis()

    var source by mutableStateOf("")
        private set
    var language by mutableStateOf(languages.first)
        private set
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
     * Typed instead of spoken, or its transcript corrected by hand, so it's
     * translated as text.
     */
    var isTyped = false

    /** The transcript the current [translation] was produced from. */
    var translatedSource: String? = null

    init {
        if (source.isNotEmpty()) append(source)
        if (language != null) this.language = language
    }

    fun append(delta: String) {
        source += delta
        LanguageDetector.detect(source, languages)?.let { language = it }
    }

    /** Replaces the transcript, for engines that revise provisional words. */
    fun setSource(text: String, language: Language?) {
        source = text
        if (language != null) {
            this.language = language
        } else {
            LanguageDetector.detect(source, languages)?.let { this.language = it }
        }
    }

    /** The transcript without filler words. This is what's shown and translated. */
    val trimmedSource: String get() = Filler.strip(source, language)

    /** The language the translation is in. */
    val target: Language get() = languages.other(language)

    /** False while the turn is empty or only filler so far. */
    val hasContent: Boolean get() = trimmedSource.isNotEmpty()

    val needsTranslation: Boolean get() = translatedSource != trimmedSource

    /**
     * Text to show for a given language: the transcript if that's what was
     * spoken, otherwise the translation.
     */
    fun text(lang: Language): String = if (lang == language) trimmedSource else translation
}
