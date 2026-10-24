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
) {
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
        val stored = LanguagePair(
            Language(prefs.string("firstLanguage") ?: LanguagePair.DEFAULT.first.code),
            Language(prefs.string("secondLanguage") ?: LanguagePair.DEFAULT.second.code),
        )
        _languages = if (provider.supports(stored) && stored.first != stored.second) stored else LanguagePair.DEFAULT
        for (credential in allCredentials) credentials[credential.id] = secrets.read(credential.id) ?: ""
    }

    companion object {
        const val DEFAULT_TRANSLATION_MODEL = "mistral-small-latest"
        const val TRANSCRIPTION_MODEL = "voxtral-mini-transcribe-realtime-3"
    }
}
