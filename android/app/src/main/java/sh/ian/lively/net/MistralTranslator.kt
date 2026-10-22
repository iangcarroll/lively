package sh.ian.lively.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
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

/** Translates with a Mistral chat model over streaming chat completions. */
class MistralTranslator(
    private val apiKey: String,
    private val model: String,
    baseClient: OkHttpClient = ResilientSocket.sharedClient,
    private val endpoint: String = ENDPOINT,
) : TranslationService {
    private val client = baseClient.newBuilder().readTimeout(12, TimeUnit.SECONDS).build()

    override fun translate(
        text: String,
        from: Language,
        to: Language,
        context: List<Utterance>,
        script: ChineseScript,
    ): Flow<String> {
        fun name(language: Language) = if (language == Language.CHINESE) script.promptName else language.englishName
        val system = "You are a live interpreter between ${name(from)} and ${name(to)} in a spoken, face-to-face " +
            "conversation. Translate the user's message into ${name(to)}. The text is a speech transcript and " +
            "may be unpunctuated or end mid-sentence; translate it naturally, as a person would say it, and " +
            "don't complete unfinished thoughts. Keep names, numbers and units exact. Reply with the " +
            "translation only: no quotes, notes or romanization."

        // Recent turns help with pronouns, names and topic.
        val history = context.filter { it.translation.isNotEmpty() }.map { it.trimmedSource to it.translation }
        val body = buildJsonObject {
            put("model", model)
            putJsonArray("messages") {
                addJsonObject { put("role", "system"); put("content", system) }
                for ((said, translated) in history) {
                    addJsonObject { put("role", "user"); put("content", said) }
                    addJsonObject { put("role", "assistant"); put("content", translated) }
                }
                addJsonObject { put("role", "user"); put("content", text) }
            }
            put("stream", true)
            put("temperature", 0.2)
            put("max_tokens", 400)
        }

        val request = Request.Builder()
            .url(endpoint)
            .header("Authorization", "Bearer $apiKey")
            .header("Accept", "text/event-stream")
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()

        return chatCompletionStream(client, request) { code, _ -> TranslationException(code) }
    }

    companion object {
        const val ENDPOINT = "https://api.mistral.ai/v1/chat/completions"
    }
}

/**
 * Streams the `content` of OpenAI-style chat completion chunks. [failure]
 * turns a non-2xx status and its body into the exception to throw.
 */
internal fun chatCompletionStream(
    client: OkHttpClient,
    request: Request,
    failure: (code: Int, body: String) -> Exception,
): Flow<String> = flow {
    val call = client.newCall(request)
    try {
        call.execute().use { response ->
            if (!response.isSuccessful) throw failure(response.code, response.peekBody(4096).string())
            val source = response.body.source()
            while (true) {
                val line = source.readUtf8Line() ?: break
                if (!line.startsWith("data:")) continue
                val payload = line.removePrefix("data:").trim()
                if (payload == "[DONE]") break
                val json = runCatching { Json.parseToJsonElement(payload) as? JsonObject }.getOrNull() ?: continue
                val delta = ((json["choices"] as? JsonArray)?.firstOrNull() as? JsonObject)?.obj("delta")
                val content = delta?.string("content")
                if (!content.isNullOrEmpty()) emit(content)
            }
        }
    } finally {
        call.cancel()
    }
}.flowOn(Dispatchers.IO)
