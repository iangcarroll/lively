package sh.ian.lively

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import sh.ian.lively.net.AppUsage
import java.util.UUID

@OptIn(ExperimentalCoroutinesApi::class)
class AppUsageTest {
    @get:Rule val folder = TemporaryFolder()

    @Test fun offlineSessionSurvivesRelaunchAndUploadsThroughTheBrokerClient() = runTest {
        val file = folder.root.resolve("days.json")
        val day = System.currentTimeMillis() / 86_400_000
        var now = (day + 1) * 86_400_000 - 15_000
        var uptime = 1000L
        val failed = mutableListOf<String>()
        MockWebServer().use { server ->
            server.start()
            val base = server.url("/").toString()
            val client = AppUsage(file, base, backgroundScope, { now }, { uptime }) {
                failed += it.header("Lively-Usage-ID")!!
                false
            }
            client.foreground(false)
            client.foreground(true)
            client.foreground(true)
            runCurrent()
            now += 30_000
            uptime += 30_000
            client.tick()
            runCurrent()
            client.foreground(false)
            client.foreground(false)
            runCurrent()

            val next = AppUsage(file, base, backgroundScope)
            server.enqueue(MockResponse.Builder().code(204).build())
            next.sync()
            next.sync()
            assertEquals(1, server.requestCount)
            val request = server.takeRequest()
            assertEquals("/v1/app-usage", request.url.encodedPath)
            assertNull(request.headers["Authorization"])
            val id = request.headers["Lively-Usage-ID"]!!
            UUID.fromString(id)
            assertEquals(setOf(id), failed.toSet())
            val body = Json.parseToJsonElement(request.body!!.utf8()).jsonObject
            assertEquals("android", body["platform"]!!.jsonPrimitive.content)
            val days = body["days"]!!.jsonArray.map { it.jsonObject }
            assertEquals(listOf(day, day + 1), days.map { it["day"]!!.toString().toLong() })
            assertEquals(listOf("1", "0"), days.map { it["opens"].toString() })
            assertEquals(listOf("0", "1"), days.map { it["closes"].toString() })
            assertEquals(listOf("0", "30"), days.map { it["seconds"].toString() })
        }
    }

    @Test fun closeDuringUploadIsDeliveredAfterTheOriginalSnapshot() = runTest {
        lateinit var client: AppUsage
        val closes = mutableListOf<String>()
        client = AppUsage(folder.root.resolve("days.json"), "https://report.example", backgroundScope, uptime = { 500L }) {
            val body = Buffer().apply { it.body!!.writeTo(this) }.readUtf8()
            val day = Json.parseToJsonElement(body).jsonObject["days"]!!.jsonArray.single().jsonObject
            closes += day["closes"].toString()
            if (closes.size == 1) client.foreground(false)
            true
        }
        client.foreground(true)
        runCurrent()
        client.sync()
        assertEquals(listOf("0", "1"), closes)
    }
}
