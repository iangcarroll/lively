package sh.ian.lively

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import sh.ian.lively.model.Account
import sh.ian.lively.model.ChineseScript
import sh.ian.lively.model.Language
import sh.ian.lively.net.MistralTranslator
import sh.ian.lively.net.RegionProber
import sh.ian.lively.net.SocketSetupException
import sh.ian.lively.net.SonioxKeyProvider
import sh.ian.lively.net.TranslationException
import sh.ian.lively.support.MemoryStore
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
class BrokerClientTest {
    private val server = MockWebServer()
    private val memory = MemoryStore()

    @Before fun setUp() = server.start()
    @After fun tearDown() = server.close()

    private val base get() = server.url("/").toString()

    private fun json(code: Int, body: String, headers: Map<String, String> = emptyMap()) =
        MockResponse.Builder().code(code).body(body).apply { headers.forEach { (k, v) -> addHeader(k, v) } }.addHeader("Content-Type", "application/json").build()

    private class Identity : SonioxKeyProvider.Identity {
        override var accountToken: String? = null
        val rejected = mutableListOf<String>()
        override fun accountTokenRejected(token: String) { rejected += token; accountToken = null }
        override var playPurchaseToken: String? = null
        var limitReached = false
        override fun freeLimitReached() { limitReached = true }
    }

    /** Like the app's MainScope: one failed fetch doesn't fail its siblings or the test. */
    private val TestScope.appScope get() = CoroutineScope(backgroundScope.coroutineContext + SupervisorJob(backgroundScope.coroutineContext[Job]))

    private fun TestScope.provider(identity: Identity = Identity()) = SonioxKeyProvider(
        base, RegionProber(memory, appScope, measure = { null }), appScope, "install-1", identity,
    )

    private val key = """{"api_key":"temp-1","expires_in_seconds":300,"region":"jp","websocket_url":"wss://stt-rt.jp.soniox.com/transcribe-websocket","regions":{"us":"wss://stt-rt.soniox.com/transcribe-websocket","jp":"wss://stt-rt.jp.soniox.com/transcribe-websocket"}}"""

    @Test fun keysComeFromTheBrokerWithTheirRegion() = runTest {
        server.enqueue(json(200, key))
        server.enqueue(json(200, key.replace("temp-1", "temp-2")))
        val identity = Identity().apply { accountToken = "session"; playPurchaseToken = "play-token" }
        val provider = provider(identity)
        val taken = provider.takeKey()
        assertEquals("temp-1", taken.value)
        assertEquals("jp", taken.region)
        assertEquals("wss://stt-rt.jp.soniox.com/transcribe-websocket", taken.websocketURL)
        val request = server.takeRequest()
        assertEquals("/v1/soniox/key", request.url.encodedPath)
        assertEquals("install-1", request.headers["Lively-Install-ID"])
        assertEquals("Bearer session", request.headers["Authorization"])
        assertEquals("play-token", request.headers["Lively-Play-Purchase"])
    }

    @Test fun rejectedSessionsAskAgainAnonymously() = runTest {
        server.enqueue(json(401, """{"error":"unauthorized","message":"Signed out"}"""))
        server.enqueue(json(200, key))
        val identity = Identity().apply { accountToken = "stale" }
        assertEquals("temp-1", provider(identity).takeKey().value)
        assertEquals(listOf("stale"), identity.rejected)
        server.takeRequest()
        assertNull(server.takeRequest().headers["Authorization"])
    }

    @Test fun aSpentFreeDayOffersPro() = runTest {
        server.enqueue(json(429, """{"error":"rate_limited","message":"Today's free translation time is used up.","plan":"free"}""", mapOf("Retry-After" to "40000")))
        val identity = Identity()
        try {
            provider(identity).takeKey()
            fail("expected a setup failure")
        } catch (e: SocketSetupException) {
            assertEquals("Today's free translation time is used up.", e.message)
        }
        assertTrue(identity.limitReached)
    }

    @Test fun aPerMinuteLimitIsRetried() = runTest {
        server.enqueue(json(429, """{"message":"Slow down"}""", mapOf("Retry-After" to "20")))
        try {
            provider().takeKey()
            fail("expected an IO error")
        } catch (e: SocketSetupException) {
            fail("a short limit must not stop listening")
        } catch (e: IOException) {
            // Retried by the socket's backoff.
        }
    }

    @Test fun mistralStreamsTokens() = runTest {
        server.enqueue(
            MockResponse.Builder().code(200).body(
                "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\n" +
                    "data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}\n\n" +
                    "data: [DONE]\n\n",
            ).build(),
        )
        val translator = MistralTranslator("key", "mistral-small-latest", endpoint = server.url("/v1/chat/completions").toString())
        val tokens = translator.translate("Hello", Language.ENGLISH, Language.CHINESE, emptyList(), ChineseScript.SIMPLIFIED).toList()
        assertEquals(listOf("你", "好"), tokens)
        val body = server.takeRequest().body!!.utf8()
        assertTrue(body.contains("Simplified Chinese"))
        assertTrue(body.contains("\"stream\":true"))
    }

    @Test fun mistralErrorsAreTyped() = runTest {
        server.enqueue(MockResponse.Builder().code(401).build())
        val translator = MistralTranslator("bad", "m", endpoint = server.url("/x").toString())
        try {
            translator.translate("Hi", Language.ENGLISH, Language.CHINESE, emptyList(), ChineseScript.SIMPLIFIED).toList()
            fail("expected an error")
        } catch (e: TranslationException) {
            assertTrue(e.isPermanent)
        }
    }

    @Test fun signInStoresTheSession() = runTest {
        server.enqueue(json(200, "{}"))
        server.enqueue(json(200, """{"token":"tok","user":{"email":"a@b.co","free_pro":true}}"""))
        val account = Account(base, memory, memory, backgroundScope, isDemo = { false })
        var planChanges = 0
        account.onPlanChange = { planChanges++ }
        account.sendCode("a@b.co")
        account.signIn("a@b.co", "123456")
        assertEquals("a@b.co", account.email)
        assertTrue(account.hasFreePro)
        assertEquals("tok", memory.read("lively-session-token"))
        assertEquals(1, planChanges)
        assertTrue(server.takeRequest().body!!.utf8().contains("a@b.co"))
        assertTrue(server.takeRequest().body!!.utf8().contains("123456"))

        // A later launch reads it back.
        val again = Account(base, memory, memory, backgroundScope, isDemo = { false })
        assertEquals("a@b.co", again.email)
        assertTrue(again.hasFreePro)
    }

    @Test fun wrongCodesShowTheBrokersMessage() = runTest {
        server.enqueue(json(400, """{"error":"invalid_code","message":"That code didn't work."}"""))
        val account = Account(base, memory, memory, backgroundScope, isDemo = { false })
        try {
            account.signIn("a@b.co", "000000")
            fail("expected an error")
        } catch (e: Account.AccountException) {
            assertEquals("That code didn't work.", e.message)
        }
        assertFalse(account.isSignedIn)
    }

    @Test fun deletingSignsOut() = runTest {
        server.enqueue(json(200, """{"token":"tok","user":{"email":"a@b.co"}}"""))
        server.enqueue(json(200, """{"ok":true}"""))
        val account = Account(base, memory, memory, backgroundScope, isDemo = { false })
        account.signIn("a@b.co", "123456")
        account.deleteAccount()
        assertFalse(account.isSignedIn)
        assertNull(memory.read("lively-session-token"))
        server.takeRequest()
        val delete = server.takeRequest()
        assertEquals("/v1/auth/delete", delete.url.encodedPath)
        assertEquals("Bearer tok", delete.headers["Authorization"])
    }

    @Test fun regionsMoveOnlyForAClearWin() = runTest {
        var rtts = mapOf("us" to 200.0, "jp" to 180.0)
        val prober = RegionProber(memory, backgroundScope, measure = { url -> if ("jp" in url) rtts["jp"] else rtts["us"] })
        prober.update(mapOf("us" to "wss://stt-rt.soniox.com/x", "jp" to "wss://stt-rt.jp.soniox.com/x"))
        testScheduler.advanceTimeBy(1_000)
        assertEquals("jp", prober.choice)
        // 20 ms better isn't worth a move.
        rtts = mapOf("us" to 160.0, "jp" to 180.0)
        prober.probe(minimumIntervalMs = 0)
        testScheduler.advanceTimeBy(1_000)
        assertEquals("jp", prober.choice)
        // Two failed connects in a row fall back to the other region.
        prober.connectFailed("jp")
        prober.connectFailed("jp")
        assertEquals("us", prober.choice)
    }
}
