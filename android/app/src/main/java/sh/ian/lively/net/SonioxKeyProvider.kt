package sh.ian.lively.net

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Gets short-lived, single-use Soniox keys from Lively's key broker
 * (`Server/key-broker`), so the app never holds a long-lived key.
 *
 * One spare key is kept ready while listening, so a reconnect on a flaky
 * network never waits on the broker. Keys live 5 min and the spare is
 * replaced after 4, so it outlasts minutes of broker trouble.
 * The broker identifies this install by a random ID kept in the secret store and
 * rate-limits by it, by the account when signed in (`Account`), or by the
 * subscription with Lively Pro (`Pro`).
 *
 * Keys are region-scoped: each works only on its own region's WebSocket
 * host, which comes with it. [regions] picks the region to ask for, and the
 * spare is dropped when that changes.
 */
class SonioxKeyProvider(
    brokerURL: String,
    val regions: RegionProber,
    private val scope: CoroutineScope,
    private val installID: String,
    private val identity: Identity,
    baseClient: OkHttpClient = ResilientSocket.sharedClient,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** Who's asking, for the broker's limits. */
    interface Identity {
        /** The signed-in account's session token. */
        val accountToken: String?
        fun accountTokenRejected(token: String)
        /** The current Lively Pro purchase's Google Play token. */
        val playPurchaseToken: String?
        fun freeLimitReached()
    }

    /** A key and where to use it. */
    data class Key(val value: String, val region: String, val websocketURL: String)

    private class TemporaryKey(
        val key: Key,
        /**
         * The region asked for, or null to let the broker pick. The broker
         * may hand out another region if it can't mint in this one.
         */
        val requestedRegion: String?,
        val fetchedAt: Long,
        val expiresAt: Long,
    ) {
        /**
         * Four fifths of the way through its life: 240 s for a 300 s key,
         * leaving a minute for a broker hiccup to clear.
         */
        val refreshAt: Long get() = fetchedAt + ((expiresAt - fetchedAt) * 0.8).toLong()
    }

    private val endpoint = brokerURL.trimEnd('/') + "/v1/soniox/key"
    /** Text-to-Speech keys, for `SonioxSpeaker`. */
    private val speechEndpoint = brokerURL.trimEnd('/') + "/v1/soniox/tts-key"
    private val client = baseClient.newBuilder().callTimeout(10, TimeUnit.SECONDS).build()
    private var spare: TemporaryKey? = null
    /** The fetch filling [spare], shared by everyone waiting on it. */
    private var filling: Deferred<Unit>? = null
    private var refreshJob: Job? = null

    /** Soniox needs the key only to open the socket, so a few seconds is enough. */
    private val TemporaryKey.isFresh: Boolean get() = expiresAt - now() > 5_000

    init {
        regions.onChoiceChange = {
            // A spare minted for the old region won't work in the new one.
            val hadSpare = spare != null
            spare = null
            if (refreshJob != null || hadSpare) scope.launch { runCatching { fillSpare() } }
        }
    }

    /** Keeps a fresh spare key while listening. */
    fun startRefreshing() {
        regions.startPeriodicProbing()
        refreshJob?.cancel()
        refreshJob = scope.launch {
            while (isActive) {
                val due = spare?.refreshAt ?: now()
                if (due > now()) {
                    delay(due - now())
                    continue
                }
                try {
                    fillSpare()
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // The spare stays if it's still fresh; `takeKey` reports errors.
                    delay(5_000)
                }
            }
        }
    }

    /**
     * Fetches a spare ahead of the first connect, unless one is on hand with
     * a minute or more to live. Each key counts against the daily allowance,
     * so this runs when the app comes forward, never on a timer.
     */
    fun prefetch() {
        spare?.let { if (it.requestedRegion == regions.choice && it.expiresAt - now() > 60_000) return }
        scope.launch { runCatching { fillSpare() } }
    }

    /** Forgets the spare, for when the plan changes: its session limit is the old plan's. */
    fun dropSpare() {
        if (spare == null) return
        spare = null
        if (refreshJob != null) scope.launch { runCatching { fillSpare() } }
    }

    fun stopRefreshing() {
        regions.stopPeriodicProbing()
        refreshJob?.cancel()
        refreshJob = null
    }

    /**
     * A key for one connection. Keys are single-use, so each call returns a
     * different one and starts fetching the next spare.
     */
    suspend fun takeKey(): Key {
        repeat(3) {
            val key = spare
            if (key != null && key.isFresh && key.requestedRegion == regions.choice) {
                spare = null
                scope.launch { runCatching { fillSpare() } }
                return key.key
            }
            // Another caller can take the key this fill brings, so check again.
            fillSpare()
        }
        throw IOException("Couldn't get a key")
    }

    /**
     * A Text-to-Speech key for one connection, in the region listening uses.
     * No spare is kept: the speaker connects only when it has something to say.
     */
    suspend fun takeSpeechKey(): Key = requestKey(speechEndpoint).key

    /**
     * The fetch runs in [scope], not the caller, so a caller that gives up
     * (a connection closed meanwhile) doesn't cancel it for everyone else.
     */
    private suspend fun fillSpare() {
        filling?.let { return it.await() }
        val fetch = scope.async(start = CoroutineStart.LAZY) {
            try {
                spare = requestKey(endpoint)
            } finally {
                filling = null
            }
        }
        filling = fetch
        fetch.start()
        fetch.await()
    }

    private suspend fun requestKey(endpoint: String): TemporaryKey {
        val requestedRegion = regions.choice
        val token = identity.accountToken
        val request = Request.Builder()
            .url(endpoint)
            .post(ByteArray(0).toRequestBody())
            .header("Lively-Install-ID", installID)
            .apply {
                requestedRegion?.let { header("Lively-Region", it) }
                token?.let { header("Authorization", "Bearer $it") }
                identity.playPurchaseToken?.let { header("Lively-Play-Purchase", it) }
            }
            .build()

        val started = now()
        val response = client.fetch(request)

        // A signed-out or expired session: drop it and ask again anonymously.
        if (response.code == 401 && token != null) {
            identity.accountTokenRejected(token)
            return requestKey(endpoint)
        }

        val body = runCatching { Json.parseToJsonElement(response.body) as? JsonObject }.getOrNull()
        if (response.code != 200) {
            val message = body?.string("message")
            val retryAfter = response.header("Retry-After")?.toDoubleOrNull() ?: 0.0
            throw when {
                // A per-minute limit clears quickly; reconnecting with backoff gets past it.
                response.code == 429 && retryAfter <= 60 -> IOException("Rate limited")
                response.code == 429 && body?.string("plan") == "free" -> {
                    identity.freeLimitReached()
                    SocketSetupException(message ?: "Today's free translation time is used up.")
                }
                response.code in setOf(400, 403, 429, 503) ->
                    SocketSetupException(message ?: "Lively's key service turned down the request.")
                else -> IOException("Key service error ${response.code}")
            }
        }

        val apiKey = body?.string("api_key") ?: throw IOException("No key in the response")
        val expiresIn = body.int("expires_in_seconds") ?: throw IOException("No expiry in the response")
        // Speech keys list the TTS hosts, which the prober doesn't measure.
        (body["regions"] as? JsonObject)?.takeIf { endpoint == this.endpoint }?.let { offered ->
            regions.update(offered.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.takeIf { it.isString }?.content?.let { k to it } }.toMap())
        }
        // Time the key by this device's clock, from when it was requested.
        return TemporaryKey(
            key = Key(
                value = apiKey,
                region = body.string("region") ?: "us",
                websocketURL = body.string("websocket_url") ?: SonioxTranscriber.DEFAULT_ENDPOINT,
            ),
            requestedRegion = requestedRegion,
            fetchedAt = started,
            expiresAt = started + expiresIn * 1000L,
        )
    }
}
