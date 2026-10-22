package sh.ian.lively.model

import sh.ian.lively.net.SpeechEngine
import sh.ian.lively.net.TranslationService

/**
 * A choice of speech engine in Settings, and how to build it.
 *
 * To add a provider, write a [SpeechEngine], describe it with a
 * [SpeechProvider] next to it, and list it in `SpeechProviders.all`. Settings,
 * credential storage and the conversation pipeline pick it up from there.
 */
class SpeechProvider(
    /** Stable, persisted in preferences. */
    val id: String,
    val name: String,
    val summary: String,
    /** API keys this provider needs, in the order Settings shows them. */
    val credentials: List<ProviderCredential>,
    /** App settings that affect this provider, so Settings shows only those. */
    val options: Set<ProviderOption>,
    /** Languages it can listen for, in any pair. */
    val languages: List<Language>,
    val makePipeline: (AppSettings) -> SpeechPipeline,
) {
    fun supports(pair: LanguagePair) = pair.all.all { it in languages }
}

/**
 * An API key kept in the secret store. Providers that share a key (two
 * services from one vendor) share a credential.
 */
data class ProviderCredential(
    /** Secret store account name. */
    val id: String,
    val name: String,
    val help: String,
    /** Settings may leave it empty, because the app can get keys another way. */
    val isOptional: Boolean = false,
)

enum class ProviderOption {
    /** [AppSettings.latency]. */
    SPEED,
    /** [AppSettings.translationModel]. */
    TRANSLATION_MODEL,
}

class SpeechPipeline(
    val engine: SpeechEngine,
    /** Null when the engine translates by itself. */
    val translator: TranslationService?,
)
