package sh.ian.lively

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.ian.lively.model.AppSettings
import sh.ian.lively.model.ChineseScript
import sh.ian.lively.model.ConnectionStatus
import sh.ian.lively.model.ConversationHost
import sh.ian.lively.model.ConversationStore
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.model.SpeechPipeline
import sh.ian.lively.model.SpeechProvider
import sh.ian.lively.model.SpeechProviders
import sh.ian.lively.model.TranslationState
import sh.ian.lively.model.Utterance
import sh.ian.lively.net.SpeechEngine
import sh.ian.lively.net.SpeechEngineStatus
import sh.ian.lively.net.SpeechEvent
import sh.ian.lively.net.SpeechSegment
import sh.ian.lively.net.TranslationException
import sh.ian.lively.net.TranslationService
import sh.ian.lively.support.MemoryStore

private class FakeEngine : SpeechEngine {
    override var onEvent: (SpeechEvent) -> Unit = {}
    override var onStatus: (SpeechEngineStatus) -> Unit = {}
    override var networkAvailable = true
    var started = 0
    var paused = 0
    var resumed = 0
    var stopped = 0
    val sent = mutableListOf<ByteArray>()
    override fun start() { started++; onStatus(SpeechEngineStatus.Live) }
    override fun stop() { stopped++ }
    override fun pause() { paused++ }
    override fun resume() { resumed++ }
    override fun send(chunk: ByteArray) { sent += chunk }
}

private class FakeTranslator(var fail: Exception? = null) : TranslationService {
    val requests = mutableListOf<String>()
    override fun translate(text: String, from: Language, to: Language, context: List<Utterance>, script: ChineseScript): Flow<String> = flow {
        requests += text
        fail?.let { throw it }
        emit("[")
        emit("$text]")
    }
}

private class FakeHost : ConversationHost {
    var micGranted = true
    var listening = false
    var onChunk: ((ByteArray, Float) -> Unit)? = null
    var onInterrupted: (() -> Unit)? = null
    override suspend fun requestMicPermission() = micGranted
    override fun startMic(onChunk: (ByteArray, Float) -> Unit, onInterrupted: () -> Unit) {
        listening = true
        this.onChunk = onChunk
        this.onInterrupted = onInterrupted
    }
    override fun stopMic() { listening = false }
    override fun keepScreenAwake(awake: Boolean) {}
}

@OptIn(ExperimentalCoroutinesApi::class)
class ConversationStoreTest {
    private val memory = MemoryStore()
    private val engine = FakeEngine()
    private val translator = FakeTranslator()
    private val host = FakeHost()

    private fun TestScope.store(withTranslator: Boolean = false): Pair<ConversationStore, AppSettings> {
        val provider = SpeechProvider(
            id = SpeechProviders.SONIOX_ID, name = "Fake", summary = "", credentials = emptyList(), options = emptySet(),
            languages = Language.SONIOX, makePipeline = { error("unused") },
        )
        val settings = AppSettings(memory, memory, listOf(provider))
        val store = ConversationStore(settings, backgroundScope, host, makePipeline = {
            SpeechPipeline(engine, if (withTranslator) translator else null)
        })
        return store to settings
    }

    private fun segment(id: Int, source: String, translation: String = "", closed: Boolean = false, catchUp: Boolean = false, language: Language? = null) =
        SpeechEvent.Segment(SpeechSegment(id, source, translation, language, closed, catchUp))

    @Test fun listeningStartsMicAndEngine() = runTest {
        val (store, _) = store()
        store.startListening()
        runCurrent()
        assertTrue(store.isListening)
        assertTrue(host.listening)
        assertEquals(1, engine.started)
        assertEquals(ConnectionStatus.Live, store.status)
        host.onChunk!!(ByteArray(4), 0.5f)
        runCurrent()
        assertEquals(1, engine.sent.size)
    }

    @Test fun deniedMicExplainsItself() = runTest {
        host.micGranted = false
        val (store, _) = store()
        store.startListening()
        runCurrent()
        assertFalse(store.isListening)
        assertTrue(store.alert!!.contains("microphone"))
    }

    @Test fun segmentsBecomeUtterances() = runTest {
        val (store, _) = store()
        store.startListening(); runCurrent()
        store.handle(segment(0, "Where is the bus?"))
        store.handle(segment(0, "Where is the bus?", "公交车在哪里？", closed = true))
        store.handle(segment(1, "就在这里。", "It's right here.", closed = true))
        assertEquals(2, store.visibleUtterances.size)
        val first = store.visibleUtterances[0]
        assertEquals(Language.ENGLISH, first.language)
        assertEquals("公交车在哪里？", first.translation)
        assertEquals(TranslationState.Current, first.translationState)
        assertEquals(Language.CHINESE, store.visibleUtterances[1].language)
    }

    @Test fun traditionalScriptAppliesOnlyToChinese() = runTest {
        val (store, settings) = store()
        settings.chineseScript = ChineseScript.TRADITIONAL
        val saved = sh.ian.lively.model.ScriptConverter.toTraditional
        sh.ian.lively.model.ScriptConverter.toTraditional = { it.replace("这", "這") }
        try {
            store.startListening(); runCurrent()
            store.handle(segment(0, "这里", "Here", closed = true))
            assertEquals("這里", store.visibleUtterances[0].source)
            assertEquals("Here", store.visibleUtterances[0].translation)
        } finally {
            sh.ian.lively.model.ScriptConverter.toTraditional = saved
        }
    }

    @Test fun fillerOnlySegmentsAreDropped() = runTest {
        val (store, _) = store()
        store.startListening(); runCurrent()
        store.handle(segment(0, "Um, uh", closed = true))
        assertTrue(store.utterances.isEmpty())
    }

    @Test fun catchUpSpeechGoesWhereTheDropoutHappened() = runTest {
        val (store, _) = store()
        store.startListening(); runCurrent()
        store.handle(segment(0, "Before the dropout.", "之前。", closed = true))
        store.handle(SpeechEvent.SessionReset)
        store.handle(segment(1, "After it.", "之后。", closed = true))
        store.handle(segment(2, "During it.", "期间。", closed = true, catchUp = true))
        assertEquals(listOf("Before the dropout.", "During it.", "After it."), store.visibleUtterances.map { it.source })
        assertTrue(store.visibleUtterances[1].isLate)
    }

    @Test fun transcribeOnlyEnginesGetTranslatedPerTurn() = runTest {
        val (store, _) = store(withTranslator = true)
        store.startListening(); runCurrent()
        store.handle(SpeechEvent.TurnStarted)
        store.handle(SpeechEvent.Text("Hello"))
        store.handle(SpeechEvent.Text(" there"))
        store.handle(SpeechEvent.TurnEnded)
        advanceTimeBy(1_000)
        val utterance = store.visibleUtterances.single()
        assertTrue(utterance.isFinal)
        assertEquals("[Hello there]", utterance.translation)
        assertEquals(TranslationState.Current, utterance.translationState)
    }

    @Test fun translationThrottlesWhileSpeaking() = runTest {
        val (store, _) = store(withTranslator = true)
        store.startListening(); runCurrent()
        store.handle(SpeechEvent.Text("One"))
        advanceTimeBy(300)
        store.handle(SpeechEvent.Text(" two"))
        store.handle(SpeechEvent.Text(" three"))
        advanceTimeBy(5_000)
        // A first request for what was there, then one catching up; never one per word.
        assertEquals(listOf("One", "One two three"), translator.requests)
    }

    @Test fun silenceEndsATurn() = runTest {
        val (store, _) = store(withTranslator = true)
        store.startListening(); runCurrent()
        store.handle(SpeechEvent.Text("Still talking"))
        advanceTimeBy(3_100)
        assertTrue(store.visibleUtterances.single().isFinal)
    }

    @Test fun permanentTranslationErrorsFailAtOnce() = runTest {
        translator.fail = TranslationException(401)
        val (store, _) = store(withTranslator = true)
        store.startListening(); runCurrent()
        store.handle(SpeechEvent.Text("Hi"))
        store.handle(SpeechEvent.TurnEnded)
        advanceTimeBy(10_000)
        assertEquals(TranslationState.Failed("API key rejected"), store.visibleUtterances.single().translationState)
        assertEquals(1, translator.requests.size)
        translator.fail = null
        store.retryTranslation(store.visibleUtterances.single())
        advanceTimeBy(10_000)
        assertEquals("[Hi]", store.visibleUtterances.single().translation)
    }

    @Test fun translationWaitsForTheNetwork() = runTest {
        val (store, _) = store(withTranslator = true)
        store.startListening(); runCurrent()
        store.setNetwork(online = false, changedInterface = false)
        assertEquals(ConnectionStatus.Live, store.status)
        store.handle(SpeechEvent.Text("Offline words"))
        store.handle(SpeechEvent.TurnEnded)
        advanceTimeBy(2_000)
        assertEquals(TranslationState.WaitingForNetwork, store.visibleUtterances.single().translationState)
        store.setNetwork(online = true, changedInterface = false)
        advanceTimeBy(1_000)
        assertEquals("[Offline words]", store.visibleUtterances.single().translation)
    }

    @Test fun stoppingKeepsTheEngineWarmForAMinute() = runTest {
        val (store, _) = store()
        store.startListening(); runCurrent()
        store.stopListening()
        assertEquals(1, engine.paused)
        assertEquals(ConnectionStatus.Idle, store.status)
        store.startListening(); runCurrent()
        assertEquals(1, engine.resumed)
        assertEquals(1, engine.started)
        store.stopListening()
        advanceTimeBy(ConversationStore.WARM_PAUSE_MS + 1)
        assertEquals(1, engine.stopped)
    }

    @Test fun engineFailureStopsAndAlerts() = runTest {
        val (store, _) = store()
        store.startListening(); runCurrent()
        engine.onStatus(SpeechEngineStatus.Failed("Key rejected"))
        assertFalse(store.isListening)
        assertEquals("Key rejected", store.alert)
        assertFalse(host.listening)
    }

    @Test fun micInterruptionStops() = runTest {
        val (store, _) = store()
        store.startListening(); runCurrent()
        host.onInterrupted!!()
        assertFalse(store.isListening)
        assertTrue(store.alert!!.contains("microphone stopped"))
    }

    @Test fun changingLanguagesClearsTheConversation() = runTest {
        val (store, settings) = store()
        store.startListening(); runCurrent()
        store.handle(segment(0, "Hello", "你好", closed = true))
        settings.languages = LanguagePair(Language.ENGLISH, Language("ja"))
        store.settingsDidClose()
        assertTrue(store.utterances.isEmpty())
        assertFalse(store.isListening)
        assertEquals(1, engine.stopped)
    }

    @Test fun demoPlaysTheScript() = runTest {
        val provider = SpeechProvider(SpeechProviders.SONIOX_ID, "x", "", emptyList(), emptySet(), Language.SONIOX) { error("unused") }
        val store = ConversationStore(AppSettings(memory, memory, listOf(provider)), backgroundScope, host, demo = true)
        store.startListening()
        advanceTimeBy(60_000)
        assertEquals(5, store.visibleUtterances.size)
        assertEquals("太好了，非常感谢你的帮助。", store.visibleUtterances.last().translation)
        assertFalse(host.listening)
        assertNull(store.alert)
    }
}
