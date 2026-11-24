package sh.ian.lively.net

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import okhttp3.Request

/** Request and response watermarks belong to the stream, across all of its WebSockets. */
internal class SonioxReconnect(private val initial: Request, private val capacity: Int) {
    var request: Request? = null
        private set
    private var token: String? = null
    var deadline: Long? = null
    var lastSequence = 0
    var requestCount = 0
        private set
    private val pending = ArrayDeque<WsMessage>()
    private var pingID: Int? = null

    fun acceptOffer(json: JsonObject): Boolean {
        val nextToken = (json["reconnect_token"] as? JsonPrimitive)?.content ?: return false
        val raw = (json["reconnect_url"] as? JsonPrimitive)?.content ?: return false
        val next = runCatching { initial.newBuilder().url(raw).build() }.getOrNull() ?: return false
        val url = next.url
        if (token != null || nextToken.isEmpty() || url.scheme != initial.url.scheme ||
            url.host != initial.url.host || url.port != initial.url.port ||
            url.username.isNotEmpty() || url.password.isNotEmpty()) return false
        request = next
        token = nextToken
        return true
    }

    fun record(message: WsMessage) {
        requestCount++
        pending.addLast(message)
        if (pending.size > capacity) pending.removeFirst()
    }

    fun ping(): WsMessage? {
        if (pingID != null) return null
        pingID = requestCount
        return WsMessage.json(buildJsonObject { put("type", "ping"); put("id", requestCount) })
    }

    fun pong(id: Int?) {
        if (id == null || id != pingID) return
        pingID = null
        discardThrough(id)
    }

    private fun discardThrough(id: Int) {
        while (requestCount - pending.size < id) pending.removeFirst()
    }

    fun handshake() = WsMessage.json(buildJsonObject {
        put("type", "reconnect")
        put("reconnect_token", token)
        put("last_seq", lastSequence)
    })

    fun acceptResume(json: JsonObject, sentBeforeDrop: Int): List<WsMessage>? {
        val nextToken = (json["reconnect_token"] as? JsonPrimitive)?.content ?: return null
        val last = (json["last_request"] as? JsonPrimitive)?.intOrNull ?: return null
        if (nextToken.isEmpty() || last !in (requestCount - pending.size)..sentBeforeDrop) return null
        discardThrough(last)
        token = nextToken
        pingID = null
        deadline = null
        return pending.toList()
    }
}
