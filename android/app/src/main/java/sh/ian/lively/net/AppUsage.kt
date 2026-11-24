package sh.ian.lively.net

import android.os.SystemClock
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import sh.ian.lively.support.DebugFlags
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/** Called on the main thread by the process lifecycle. Only the upload suspends. */
class AppUsage(
    private val file: File,
    broker: String,
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
    private val uptime: () -> Long = SystemClock::uptimeMillis,
    private val send: suspend (Request) -> Boolean = { request ->
        withContext(Dispatchers.IO) {
            ResilientSocket.sharedClient.newCall(request).execute().use { it.code == 204 }
        }
    },
) : DefaultLifecycleObserver {
    @Serializable
    private data class Day(val day: Long, val opens: Int = 0, val closes: Int = 0, val seconds: Long = 0)

    @Serializable
    private data class Store(val id: String, val days: Map<Long, Day> = emptyMap(), val pending: Set<Long> = emptySet())

    @Serializable
    private data class Batch(val platform: String, val days: List<Day>)

    // Zero counts must also be present on the wire.
    private val json = Json { encodeDefaults = true }
    private val endpoint = broker.trimEnd('/') + "/v1/app-usage"
    private var cached: Store? = null
    private var started: Long? = null
    private var timer: Job? = null
    private var syncing = false

    override fun onStart(owner: LifecycleOwner) {
        if (!DebugFlags.demo) foreground(true)
    }

    override fun onStop(owner: LifecycleOwner) = foreground(false)

    internal fun foreground(active: Boolean) {
        if (active == (started != null)) return
        val timestamp = uptime()
        val elapsed = started?.let { ((timestamp - it) / 1000).coerceIn(0, 30 * 86_400L) }
        started = if (active) timestamp else null
        record { row ->
            if (elapsed == null) row.copy(opens = row.opens + 1)
            else row.copy(closes = row.closes + 1, seconds = row.seconds + elapsed)
        }
        timer?.cancel()
        if (active) timer = scope.launch {
            while (true) {
                delay(60_000)
                tick()
            }
        }
        scope.launch { sync() }
    }

    internal fun tick() {
        if (started == null) return
        record { it }
        scope.launch { sync() }
    }

    private fun read(): Store {
        cached?.let { return it }
        val store = if (file.exists()) json.decodeFromString<Store>(file.readText()) else Store(UUID.randomUUID().toString())
        cached = store
        return store
    }

    private fun save(store: Store) {
        val temporary = File(file.parentFile, file.name + ".tmp")
        temporary.writeText(json.encodeToString(store))
        Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        cached = store
    }

    private fun record(update: (Day) -> Day) {
        try {
            val store = read()
            val today = now() / 86_400_000
            val updated = update(store.days[today] ?: Day(today))
            if (updated == store.days[today]) return
            val days = store.days.filterKeys { it in today - 29..today } + (today to updated)
            save(store.copy(days = days, pending = store.pending.intersect(days.keys) + today))
        } catch (_: java.io.IOException) {
            // Analytics storage is best effort; app startup and translation remain available.
        } catch (_: kotlinx.serialization.SerializationException) {
            // An unreadable ledger cannot be uploaded.
        }
    }

    internal suspend fun sync() {
        if (syncing) return
        syncing = true
        try {
            while (true) {
                val store = read()
                val rows = store.pending.sorted().mapNotNull(store.days::get)
                if (rows.isEmpty()) return
                val request = Request.Builder().url(endpoint).header("Lively-Usage-ID", store.id)
                    .post(json.encodeToString(Batch("android", rows)).toRequestBody("application/json".toMediaType()))
                    .build()
                if (!send(request)) return
                // Keep newer transitions that occurred while this batch was uploading.
                val latest = read()
                if (latest.id != store.id) return
                val confirmed = rows.filter { latest.days[it.day] == it }.map { it.day }.toSet()
                save(latest.copy(pending = latest.pending - confirmed))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // Retain pending totals for the next foreground retry.
        } finally {
            syncing = false
        }
    }
}
