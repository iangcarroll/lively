package sh.ian.lively.model

import kotlinx.coroutines.CoroutineScope
import sh.ian.lively.net.MistralTranslator
import sh.ian.lively.net.RealtimeTranscriber
import sh.ian.lively.net.SonioxKeyProvider
import sh.ian.lively.net.SonioxTranscriber

/** The engines Settings offers. */
object SpeechProviders {
    const val SONIOX_ID = "soniox"
    const val VOXTRAL_ID = "voxtral-mistral"

    fun sonioxCredential(hasBroker: Boolean) = if (hasBroker) {
        ProviderCredential(
            id = "soniox-api-key",
            name = "Soniox API key (optional)",
            help = "Lively gets short-lived Soniox keys from its key service. For development, a key from console.soniox.com overrides it.",
            isOptional = true,
        )
    } else {
        ProviderCredential(id = "soniox-api-key", name = "Soniox API key", help = "Create a key at console.soniox.com.")
    }

    val mistralCredential = ProviderCredential(
        id = "mistral-api-key",
        name = "Mistral API key",
        help = "Create a key at console.mistral.ai.",
    )

    /**
     * Soniox first: it won the 2026-10-20 benchmark (Tools/probe/RESULTS.md):
     * every turn translated, no leaks, lowest cost.
     */
    fun all(scope: CoroutineScope, keyProvider: SonioxKeyProvider?): List<SpeechProvider> {
        val soniox = sonioxCredential(keyProvider != null)
        return listOf(
            SpeechProvider(
                id = SONIOX_ID,
                name = "Soniox",
                summary = "Soniox stt-rt-v5 transcribes and translates both ways in one stream, for the lowest latency.",
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
                    SpeechPipeline(SonioxTranscriber(SonioxTranscriber.Configuration(credential, settings.languages), scope), null)
                },
            ),
            SpeechProvider(
                id = VOXTRAL_ID,
                name = "Voxtral + Mistral",
                summary = "Voxtral Realtime transcribes and detects turns; a Mistral chat model translates each turn.",
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
