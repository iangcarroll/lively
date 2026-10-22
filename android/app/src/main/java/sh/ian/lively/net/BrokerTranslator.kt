package sh.ian.lively.net

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import sh.ian.lively.model.ChineseScript
import sh.ian.lively.model.Language
import sh.ian.lively.model.Utterance
import java.util.concurrent.TimeUnit

/**
 * Translates through Lively's key broker (`POST /v1/translate`), which runs
 * DeepSeek and counts each line against the plan's daily allowance. The
 * broker holds the prompt; this sends the text, languages and recent turns.
 */
class BrokerTranslator(
    brokerURL: String,
    private val installID: String,
    /** The same caller identity [SonioxKeyProvider] sends. */
    private val identity: SonioxKeyProvider.Identity,
    baseClient: OkHttpClient = ResilientSocket.sharedClient,
) : TranslationService {
    private val endpoint = brokerURL.trimEnd('/') + "/v1/translate"
    private val client = baseClient.newBuilder().readTimeout(12, TimeUnit.SECONDS).build()

    override fun translate(
        text: String,
        from: Language,
        to: Language,
        context: List<Utterance>,
        script: ChineseScript,
    ): Flow<String> {
        val body = buildJsonObject {
            put("text", text)
            put("source", from.code)
            put("target", to.code)
            put("script", script.id)
            putJsonArray("context") {
                for (turn in context.filter { it.translation.isNotEmpty() }) {
                    addJsonObject { put("source", turn.trimmedSource); put("translation", turn.translation) }
                }
            }
        }.toString()
        val token = identity.accountToken
        return flow {
            try {
                chatCompletionStream(client, request(body, token)) { code, response ->
                    if (code == 401 && token != null) return@chatCompletionStream TokenRejected(token)
                    val message = runCatching { (Json.parseToJsonElement(response) as? JsonObject)?.string("message") }.getOrNull()
                    message?.let { BrokerTranslationException(it, isPermanent = code != 502) } ?: TranslationException(code)
                }.collect { emit(it) }
            } catch (e: TokenRejected) {
                // A signed-out or expired session: drop it and ask again anonymously.
                identity.accountTokenRejected(e.token)
                chatCompletionStream(client, request(body, null)) { code, _ -> TranslationException(code) }.collect { emit(it) }
            }
        }
    }

    private fun request(body: String, token: String?): Request = Request.Builder()
        .url(endpoint)
        .header("Accept", "text/event-stream")
        .header("Lively-Install-ID", installID)
        .apply {
            token?.let { header("Authorization", "Bearer $it") }
            identity.playPurchaseToken?.let { header("Lively-Play-Purchase", it) }
        }
        .post(body.toRequestBody("application/json".toMediaType()))
        .build()

    private class TokenRejected(val token: String) : Exception()
}

/** The broker's own message, such as a used-up daily allowance. */
class BrokerTranslationException(message: String, val isPermanent: Boolean) : Exception(message)

/**
 * Tries [primary], and [fallback] if it fails before sending anything, as
 * on-device translation stands in for the broker when it's unreachable or
 * the day's allowance is used up. If both fail, the primary's error is thrown.
 */
class FallbackTranslator(
    private val primary: TranslationService,
    private val fallback: TranslationService,
) : TranslationService {
    override fun translate(
        text: String,
        from: Language,
        to: Language,
        context: List<Utterance>,
        script: ChineseScript,
    ): Flow<String> = flow {
        var started = false
        try {
            primary.translate(text, from, to, context, script).collect {
                started = true
                emit(it)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (primaryError: Exception) {
            if (started) throw primaryError
            try {
                fallback.translate(text, from, to, context, script).collect { emit(it) }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                throw primaryError
            }
        }
    }
}
