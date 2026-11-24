package sh.ian.lively.model

import sh.ian.lively.R
import kotlinx.coroutines.CoroutineScope
import sh.ian.lively.net.AutomaticSonioxTranscriber
import sh.ian.lively.net.FallbackTranslator
import sh.ian.lively.net.MistralTranslator
import sh.ian.lively.net.OnDeviceTranslator
import sh.ian.lively.net.RealtimeTranscriber
import sh.ian.lively.net.SonioxKeyProvider
import sh.ian.lively.net.SonioxTranscriber
import sh.ian.lively.net.TranslationService

/** The engines Settings offers. */
object SpeechProviders {
    const val SONIOX_ID = "soniox"
    const val VOXTRAL_ID = "voxtral-mistral"

    fun sonioxCredential(hasBroker: Boolean) = if (hasBroker) {
        ProviderCredential(
            id = "soniox-api-key",
            nameRes = R.string.soniox_api_key_optional,
            helpRes = R.string.soniox_optional_key_help,
            isOptional = true,
        )
    } else {
        ProviderCredential(id = "soniox-api-key", nameRes = R.string.soniox_api_key, helpRes = R.string.create_a_key_at_console_soniox_com)
    }

    val mistralCredential = ProviderCredential(
        id = "mistral-api-key",
        nameRes = R.string.mistral_api_key,
        helpRes = R.string.create_a_key_at_console_mistral_ai,
    )

    /**
     * Soniox first: it won the 2026-10-20 benchmark (Tools/probe/RESULTS.md):
     * every turn translated, no leaks, lowest cost.
     */
    fun all(
        scope: CoroutineScope,
        keyProvider: SonioxKeyProvider?,
        /** DeepSeek through the key broker; null when the build has no broker. */
        brokerTranslator: TranslationService? = null,
    ): List<SpeechProvider> {
        val soniox = sonioxCredential(keyProvider != null)
        return listOf(
            SpeechProvider(
                id = SONIOX_ID,
                name = "Soniox",
                summaryRes = R.string.soniox_engine_summary,
                credentials = listOf(soniox),
                options = emptySet(),
                languages = Language.SONIOX,
                makePipeline = { settings ->
                    val key = settings.credential(soniox)
                    // A key entered in Settings overrides the broker.
                    val credential = if (key.isEmpty() && keyProvider != null) {
                        SonioxTranscriber.Credential.Broker(keyProvider)
                    } else {
                        SonioxTranscriber.Credential.ApiKey(key)
                    }
                    if (settings.usesAutomaticLanguageDetection) {
                        // Soniox translates what it hears into the listener's
                        // language; the listener's own words are translated as
                        // text, on device with ML Kit when the broker can't
                        // (Apple's Translation framework on iOS).
                        val mistral = settings.credential(mistralCredential)
                        val outgoing = when {
                            brokerTranslator != null -> FallbackTranslator(brokerTranslator, OnDeviceTranslator())
                            mistral.isNotEmpty() -> MistralTranslator(mistral, settings.translationModel)
                            else -> OnDeviceTranslator()
                        }
                        SpeechPipeline(
                            AutomaticSonioxTranscriber(
                                AutomaticSonioxTranscriber.Configuration(credential, settings.speechListenerLanguage),
                                scope,
                            ),
                            outgoing,
                        )
                    } else {
                        SpeechPipeline(SonioxTranscriber(SonioxTranscriber.Configuration(credential, settings.languages), scope), null)
                    }
                },
            ),
            SpeechProvider(
                id = VOXTRAL_ID,
                name = "Voxtral + Mistral",
                summaryRes = R.string.voxtral_engine_summary,
                credentials = listOf(mistralCredential),
                options = setOf(ProviderOption.SPEED, ProviderOption.TRANSLATION_MODEL),
                languages = Language.VOXTRAL,
                makePipeline = { settings ->
                    val key = settings.credential(mistralCredential)
                    SpeechPipeline(
                        RealtimeTranscriber(RealtimeTranscriber.Configuration(key, settings.latency.milliseconds), scope),
                        MistralTranslator(key, settings.translationModel),
                    )
                },
            ),
        )
    }
}
