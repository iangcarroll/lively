package sh.ian.lively.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import sh.ian.lively.audio.PickupRange
import sh.ian.lively.support.Preferences
import sh.ian.lively.support.SecretStore

/** Settings, as Compose state, saved as they change. */
class AppSettings(
    private val prefs: Preferences,
    private val secrets: SecretStore,
    /** Every engine, the default first. */
    val providers: List<SpeechProvider>,
    /** The `LivelyDemo` launch option. */
    private val isDemo: () -> Boolean = { false },
) {
    private var _conversationMode by mutableStateOf(
        ConversationMode.initial(prefs.string("conversationMode"), prefs.bool("onboardingDone")),
    )

    /**
     * Online discovery keeps the listener's language fixed and learns
     * the other language from speech. The saved pair is for manual use.
     */
    var conversationMode: ConversationMode
        get() = _conversationMode
        set(value) {
            _conversationMode = value
            prefs.putString("conversationMode", value.id)
        }

    val usesAutomaticLanguageDetection: Boolean
        get() {
            // The demo is a scripted conversation in the saved pair.
            if (isDemo()) return false
            return conversationMode == ConversationMode.AUTOMATIC && providerID == SpeechProviders.SONIOX_ID
        }

    private var _providerID by mutableStateOf(
        prefs.string("speechProvider")?.takeIf { id -> providers.any { it.id == id } } ?: providers.first().id,
    )

    /** [SpeechProvider.id] of the chosen engine. */
    var providerID: String
        get() = _providerID
        set(value) {
            _providerID = value
            prefs.putString("speechProvider", value)
            if (!provider.supports(languages)) languages = LanguagePair.DEFAULT
        }

    val provider: SpeechProvider get() = provider(providerID)

    fun provider(id: String) = providers.firstOrNull { it.id == id } ?: providers.first()

    /** API keys by [ProviderCredential.id], mirrored to the secret store. */
    private val credentials = mutableStateMapOf<String, String>()

    private var _latency by mutableStateOf(Latency.from(prefs.int("latency", Latency.FASTEST.milliseconds)))
    var latency: Latency
        get() = _latency
        set(value) {
            _latency = value
            prefs.putInt("latency", value.milliseconds)
        }

    private var _languages by mutableStateOf(LanguagePair.DEFAULT)

    /** The conversation's two languages. Always ones the provider supports. */
    var languages: LanguagePair
        get() = _languages
        set(value) {
            _languages = value
            prefs.putString("firstLanguage", value.first.code)
            prefs.putString("secondLanguage", value.second.code)
        }

    /** Sets one side of the pair. Choosing the other side's language swaps them. */
    fun setLanguage(language: Language, side: LanguageSide) {
        languages = languages.with(language, side)
    }

    private var _usesLocationLanguages by mutableStateOf(prefs.bool("usesLocationLanguages"))

    /** Optional: the pair follows the country the device is in. See [LocationLanguages]. */
    var usesLocationLanguages: Boolean
        get() = _usesLocationLanguages
        set(value) {
            _usesLocationLanguages = value
            prefs.putBool("usesLocationLanguages", value)
        }

    /** The country the pair was last set for, so a choice made there by hand sticks. */
    var locationLanguageRegion: String? = prefs.string("locationLanguageRegion")
        set(value) {
            field = value
            prefs.putString("locationLanguageRegion", value)
        }

    private var _pickupRange by mutableStateOf(PickupRange.from(prefs.string("pickupRange")))

    /** How far away the mic listens; quieter sound is sent as silence. */
    var pickupRange: PickupRange
        get() = _pickupRange
        set(value) {
            _pickupRange = value
            prefs.putString("pickupRange", value.id)
        }

    private var _chineseScript by mutableStateOf(ChineseScript.from(prefs.string("chineseScript")))
    var chineseScript: ChineseScript
        get() = _chineseScript
        set(value) {
            _chineseScript = value
            prefs.putString("chineseScript", value.id)
        }

    private var _translationModel by mutableStateOf(prefs.string("translationModel") ?: DEFAULT_TRANSLATION_MODEL)
    var translationModel: String
        get() = _translationModel
        set(value) {
            _translationModel = value
            prefs.putString("translationModel", value)
        }

    private var _speaksTranslations by mutableStateOf(prefs.bool("speaksTranslations"))

    /**
     * Speech-to-speech mode: translations into the second language are read
     * aloud through the speaker. Off unless turned on.
     */
    var speaksTranslations: Boolean
        get() = _speaksTranslations
        set(value) {
            _speaksTranslations = value
            prefs.putBool("speaksTranslations", value)
        }

    private var _speechListenerLanguageCode by mutableStateOf("")

    /**
     * The reader's own language, independent of the face-to-face layout. In
     * Automatic it is any Soniox language; with a pair it is one of the two.
     */
    var speechListenerLanguage: Language
        get() {
            val language = Language(_speechListenerLanguageCode)
            if (usesAutomaticLanguageDetection) {
                return if (language in Language.SONIOX) language else Language.ENGLISH
            }
            return if (language in languages) language else languages.first
        }
        set(value) {
            val valid = if (usesAutomaticLanguageDetection) value in Language.SONIOX else value in languages
            if (!valid) return
            _speechListenerLanguageCode = value.code
            prefs.putString("speechListenerLanguage", value.code)
        }

    fun credential(credential: ProviderCredential): String = credentials[credential.id] ?: ""

    fun setCredential(value: String, credential: ProviderCredential) {
        if (credentials[credential.id] == value) return
        credentials[credential.id] = value
        secrets.write(value.ifEmpty { null }, credential.id)
    }

    /** The chosen provider has every key it needs. */
    val hasCredentials: Boolean
        get() = provider.credentials.all { it.isOptional || credential(it).isNotBlank() }

    /** Every credential any provider uses, without duplicates. */
    val allCredentials: List<ProviderCredential>
        get() = providers.flatMap { it.credentials }.distinctBy { it.id }

    init {
        // Saved at once, so finishing the welcome tour doesn't change it.
        prefs.putString("conversationMode", _conversationMode.id)
        val stored = LanguagePair(
            Language(prefs.string("firstLanguage") ?: LanguagePair.DEFAULT.first.code),
            Language(prefs.string("secondLanguage") ?: LanguagePair.DEFAULT.second.code),
        )
        _languages = if (provider.supports(stored) && stored.first != stored.second) stored else LanguagePair.DEFAULT
        _speechListenerLanguageCode = prefs.string("speechListenerLanguage") ?: stored.first.code
        for (credential in allCredentials) credentials[credential.id] = secrets.read(credential.id) ?: ""
    }

    companion object {
        const val DEFAULT_TRANSLATION_MODEL = "mistral-small-latest"
        const val TRANSCRIPTION_MODEL = "voxtral-mini-transcribe-realtime-3"
    }
}

enum class ConversationMode(val id: String, val label: String) {
    AUTOMATIC("automatic", "Automatic"),
    PAIR("pair", "Choose a pair");

    companion object {
        /**
         * The mode at launch. Automatic is for new installs; someone who set
         * Lively up before it existed keeps their pair.
         */
        fun initial(saved: String?, onboardingDone: Boolean) =
            entries.firstOrNull { it.id == saved } ?: if (onboardingDone) PAIR else AUTOMATIC
    }
}
