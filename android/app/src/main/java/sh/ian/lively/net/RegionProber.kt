package sh.ian.lively.net

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.withContext
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.ConnectionPool
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import sh.ian.lively.support.Preferences
import java.util.concurrent.TimeUnit
import kotlin.math.min

/**
 * Picks the Soniox region with the shortest round trip from this network.
 *
 * Soniox regions are separate projects, and a temporary key works only in
 * its own region, so the broker mints keys for whichever region the app asks
 * for. This measures each region the broker offers and keeps the best one in
 * [choice]. A change applies to the next connection only; a healthy socket is
 * never torn down to move it.
 *
 * A probe is three unauthenticated `GET https://stt-rt.<region>.soniox.com/`
 * on one connection. Each returns a 404 from the regional origin through
 * Cloudflare, the same path audio takes. The first request pays for the TCP
 * and TLS handshakes, so the RTT is the faster of the other two. Probes are
 * free and use no key. See `Tools/probe/ASIA_LATENCY.md` §6.2.
 */
class RegionProber(
    private val prefs: Preferences,
    private val scope: CoroutineScope,
    /** Measures one region's RTT in ms, or null if it can't be reached. */
    private val measure: suspend (websocketURL: String) -> Double? = ::measureRTT,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /**
     * The region to ask the broker for. Null until the broker has listed its
     * regions; the broker then picks one from the caller's country.
     */
    var choice: String? = null
        private set(value) {
            if (field == value) return
            field = value
            prefs.putString(CHOICE_KEY, value)
            onChoiceChange()
        }

    var onChoiceChange: () -> Unit = {}

    private class Stats {
        /** Smoothed RTT in milliseconds. Null until a probe succeeds. */
        var rtt: Double? = null
        /** Smoothed share of probes and connects that failed, 0…1. */
        var failureRate = 0.0
        var connectFailuresInARow = 0

        val score: Double? get() = rtt?.let { it + FAILURE_PENALTY_MS * failureRate }

        fun record(success: Boolean) {
            failureRate = failureRate * (1 - SMOOTHING) + (if (success) 0.0 else SMOOTHING)
        }
    }

    /** Region → WebSocket URL, as last listed by the broker. */
    private var regions: Map<String, String>
    private val stats = mutableMapOf<String, Stats>()
    private var probing: Job? = null
    private var lastProbe: Long? = null
    private var periodic: Job? = null

    init {
        regions = prefs.string(REGIONS_KEY)?.let { stored ->
            runCatching {
                (Json.parseToJsonElement(stored) as JsonObject).mapValues { (it.value as JsonPrimitive).content }
            }.getOrNull()
        } ?: emptyMap()
        // Nobody listens yet, so restoring it notifies no one.
        choice = prefs.string(CHOICE_KEY)?.takeIf { it in regions }
    }

    /** Takes the regions the broker offers, from each key it hands out. */
    fun update(offered: Map<String, String>) {
        if (offered.isEmpty() || offered == regions) return
        regions = offered
        prefs.putString(REGIONS_KEY, JsonObject(offered.mapValues { JsonPrimitive(it.value) }).toString())
        stats.keys.retainAll(offered.keys)
        if (choice != null && choice !in offered) choice = null
        probe(minimumIntervalMs = 0)
    }

    /**
     * Measures every region, unless a probe is running or one finished
     * within [minimumIntervalMs].
     */
    fun probe(minimumIntervalMs: Long = 60_000) {
        if (probing != null || regions.isEmpty()) return
        lastProbe?.let { if (now() - it < minimumIntervalMs) return }
        val targets = regions
        probing = scope.launch {
            val results = targets.map { (region, url) -> async { region to measure(url) } }.awaitAll()
            for ((region, rtt) in results) {
                if (region !in regions) continue
                val entry = stats.getOrPut(region) { Stats() }
                if (rtt != null) entry.rtt = entry.rtt?.let { it * (1 - SMOOTHING) + rtt * SMOOTHING } ?: rtt
                entry.record(rtt != null)
            }
            lastProbe = now()
            probing = null
            choose()
        }
    }

    /** Probes every ~10 min while listening. Never on a timer otherwise. */
    fun startPeriodicProbing() {
        periodic?.cancel()
        periodic = scope.launch {
            while (isActive) {
                delay(LISTENING_INTERVAL_MS)
                probe(minimumIntervalMs = 0)
            }
        }
    }

    fun stopPeriodicProbing() {
        periodic?.cancel()
        periodic = null
    }

    fun connectSucceeded(region: String) {
        val entry = stats.getOrPut(region) { Stats() }
        entry.connectFailuresInARow = 0
        entry.record(success = true)
    }

    /**
     * After a couple of failed connects in a row, moves to the next-best
     * region right away and probes again.
     */
    fun connectFailed(region: String) {
        val entry = stats.getOrPut(region) { Stats() }
        entry.record(success = false)
        entry.connectFailuresInARow += 1
        val fallBack = entry.connectFailuresInARow >= CONNECT_FAILURES_BEFORE_FALLBACK
        if (fallBack) entry.connectFailuresInARow = 0
        if (!fallBack) return

        regions.keys.filter { it != region }
            .minByOrNull { stats[it]?.score ?: Double.POSITIVE_INFINITY }
            ?.let { choice = it }
        probe(minimumIntervalMs = 0)
    }

    private fun choose() {
        val best = regions.keys.mapNotNull { region -> stats[region]?.score?.let { region to it } }.minByOrNull { it.second } ?: return
        val current = choice
        val currentScore = current?.let { stats[it]?.score }
        if (current == null || currentScore == null) {
            choice = best.first
            return
        }
        val gain = currentScore - best.second
        if (best.first != current && gain >= currentScore * MINIMUM_GAIN && gain >= MINIMUM_GAIN_MS) {
            choice = best.first
        }
    }

    companion object {
        private const val SMOOTHING = 0.3
        /** What a region that always fails costs, in ms of RTT. */
        private const val FAILURE_PENALTY_MS = 500.0
        /** Switch only to a region at least this much better, so close regions don't flap. */
        private const val MINIMUM_GAIN = 0.25
        private const val MINIMUM_GAIN_MS = 40.0
        private const val CONNECT_FAILURES_BEFORE_FALLBACK = 2
        private const val LISTENING_INTERVAL_MS = 600_000L
        private const val CHOICE_KEY = "sonioxRegion"
        private const val REGIONS_KEY = "sonioxRegions"

        /** The region's RTT in ms, or null if it couldn't be reached. */
        suspend fun measureRTT(websocketURL: String): Double? = withContext(Dispatchers.IO) { measureBlocking(websocketURL) }

        private suspend fun measureBlocking(websocketURL: String): Double? {
            val host = websocketURL.replaceFirst("wss://", "https://").toHttpUrlOrNull()?.host ?: return null
            val client = ResilientSocket.sharedClient.newBuilder()
                .connectionPool(ConnectionPool(1, 30, TimeUnit.SECONDS))
                .callTimeout(5, TimeUnit.SECONDS)
                .cache(null)
                .build()
            try {
                var best = Double.POSITIVE_INFINITY
                repeat(3) { attempt ->
                    val started = System.nanoTime()
                    // Any HTTP response counts; the origin answers `/` with a 404.
                    runCatching { client.fetch(Request.Builder().url("https://$host/").header("Cache-Control", "no-cache").build()) }
                        .getOrElse { return null }
                    val elapsed = (System.nanoTime() - started) / 1e6
                    if (attempt > 0) best = min(best, elapsed)
                }
                return best
            } finally {
                client.connectionPool.evictAll()
            }
        }
    }
}
