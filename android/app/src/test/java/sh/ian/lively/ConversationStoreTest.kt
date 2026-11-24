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
import sh.ian.lively.model.ConversationMode
import sh.ian.lively.model.ConversationStore
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguageDetector
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.model.SpeechPipeline
import sh.ian.lively.model.SpeechProvider
import sh.ian.lively.model.SpeechProviders
import sh.ian.lively.model.TranslationState
import sh.ian.lively.model.Utterance
import sh.ian.lively.net.AutoSpeechSegment
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
    /** Each request's source and target language. */
    val directions = mutableListOf<Pair<Language, Language>>()
    override fun translate(text: String, from: Language, to: Language, context: List<Utterance>, script: ChineseScript): Flow<String> = flow {
        requests += text
        directions += from to to
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
    private val ja = Language("ja")
    private val fr = Language("fr")
    /** The store's clock, in milliseconds. */
    private var clock = 0L

    private fun provider(id: String = SpeechProviders.SONIOX_ID) = SpeechProvider(
        id = id, name = "Fake", summaryRes = R.string.engine, credentials = emptyList(), options = emptySet(),
        languages = Language.SONIOX, makePipeline = { error("unused") },
    )

    private fun TestScope.store(withTranslator: Boolean = false, automatic: Boolean = false): Pair<ConversationStore, AppSettings> {
        memory.putString("conversationMode", if (automatic) "automatic" else "pair")
        val settings = AppSettings(memory, memory, listOf(provider()))
        val store = ConversationStore(
            settings, backgroundScope, host,
            makePipeline = { SpeechPipeline(engine, if (withTranslator) translator else null) },
            now = { clock },
        )
        return store to settings
    }

    /** An Automatic conversation that is listening, with a text translator for the listener's words. */
    private fun TestScope.automaticStore(): ConversationStore {
        val (store, _) = store(withTranslator = true, automatic = true)
        store.startListening()
        runCurrent()
        return store
    }

    /** A provider-final turn in the listener's language, which has no target of its own. */
    private fun own(id: Int, source: String, final: Boolean = true) = SpeechEvent.AutoSegment(
        AutoSpeechSegment(
            id, source, Language.ENGLISH, languageIsFinal = true, target = null, translation = "", stableTranslation = "",
            isClosed = final, isSourceFinal = final, isCatchUp = false,
        ),
    )

    /** A provider-final turn in another language, translated for the listener by the engine. */
    private fun heard(
        id: Int,
        source: String,
        language: Language,
        translation: String,
        evidence: Boolean = true,
        catchUp: Boolean = false,
    ) = SpeechEvent.AutoSegment(
        AutoSpeechSegment(
            id, source, language, languageIsFinal = true, target = Language.ENGLISH, translation = translation,
            stableTranslation = translation, isClosed = true, isSourceFinal = true, isCatchUp = catchUp,
            isPartnerEvidence = evidence,
        ),
    )

    private fun segment(id: Int, source: String, translation: String = "", closed: Boolean = false, catchUp: Boolean = false, language: Language? = null) =
        SpeechEvent.Segment(SpeechSegment(id, source, translation, language = language, isClosed = closed, isCatchUp = catchUp))

    @Test fun listeningStartsMicAndEngine() = runTest {
        val (store, _) = store()
        store.startListening()
        runCurrent()
        assertTrue(store.isListening)
        assertTrue(host.listening)
        assertEquals(1, engine.started)
        assertEquals(ConnectionStatus.Live, store.status)
        host.onChunk!!(ByteArray(4), -20f)
        runCurrent()
        assertEquals(1, engine.sent.size)
    }

    @Test fun distantSoundIsSentAsSilence() = runTest {
        val (store, _) = store()
        store.startListening()
        runCurrent()
        host.onChunk!!(byteArrayOf(1, 2, 3, 4), -55f)
        runCurrent()
        assertTrue(engine.sent.single().all { it == 0.toByte() })
        assertFalse(store.isHearing)
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

    @Test fun editedTurnsAreTranslatedAgainAsText() = runTest {
        memory.putString("conversationMode", "pair")
        val store = ConversationStore(
            AppSettings(memory, memory, listOf(provider())), backgroundScope, host,
            brokerTranslator = translator, makePipeline = { SpeechPipeline(engine, null) },
        )
        store.startListening(); runCurrent()
        store.handle(segment(0, "My name is Brian.", "我叫布莱恩。", closed = true))
        val turn = store.visibleUtterances.single()
        store.edit(turn, "My name is Ian.")
        runCurrent()
        assertEquals(listOf("My name is Ian."), translator.requests)
        assertEquals("My name is Ian.", turn.trimmedSource)
        assertEquals("[My name is Ian.]", turn.translation)
        assertEquals(TranslationState.Current, turn.translationState)
        // A late update to the segment doesn't undo the correction.
        store.handle(segment(0, "My name is Brian.", "我叫布莱恩。", closed = true))
        assertEquals("My name is Ian.", turn.trimmedSource)
    }

    @Test fun deletedTurnsLeaveTheConversation() = runTest {
        val (store, _) = store()
        store.startListening(); runCurrent()
        store.handle(segment(0, "Where is the bus?", "公交车在哪里？", closed = true))
        store.handle(segment(1, "就在这里。", "It's right here.", closed = true))
        store.delete(store.visibleUtterances[0])
        assertEquals(listOf("就在这里。"), store.visibleUtterances.map { it.trimmedSource })
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
        assertTrue(store.visibleUtterances.isEmpty())
        // The hidden turn stays attached to its segment until the engine is let go.
        store.stopListening()
        advanceTimeBy(ConversationStore.WARM_PAUSE_MS + 1)
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
        // A new install is on Automatic, but the demo is scripted in the saved pair.
        val settings = AppSettings(memory, memory, listOf(provider()), isDemo = { true })
        assertEquals(ConversationMode.AUTOMATIC, settings.conversationMode)
        assertFalse(settings.usesAutomaticLanguageDetection)
        val store = ConversationStore(settings, backgroundScope, host, demo = true)
        assertFalse(store.isAutomaticLanguageMode)
        store.startListening()
        advanceTimeBy(60_000)
        assertEquals(5, store.visibleUtterances.size)
        assertEquals("太好了，非常感谢你的帮助。", store.visibleUtterances.last().translation)
        assertFalse(host.listening)
        assertNull(store.alert)
        // Opening Settings must not cost the demo its translator.
        store.stopListening()
        store.settingsDidClose()
        store.clear()
        store.startListening()
        advanceTimeBy(60_000)
        assertEquals("太好了，非常感谢你的帮助。", store.visibleUtterances.last().translation)
    }

    // region Native translation ownership

    @Test fun unfinishedNativeTranslationFailsAndRetriesAsText() = runTest {
        memory.putString("conversationMode", "pair")
        val store = ConversationStore(
            AppSettings(memory, memory, listOf(provider())), backgroundScope, host,
            brokerTranslator = translator, makePipeline = { SpeechPipeline(engine, null) },
        )
        store.startListening(); runCurrent()
        store.handle(segment(0, "Where is the bus?", language = Language.ENGLISH))
        advanceTimeBy(5_000)
        val turn = store.visibleUtterances.single()
        // The engine owns this translation; the text translator is not asked on its own.
        assertTrue(translator.requests.isEmpty())
        store.handle(SpeechEvent.SessionReset)
        assertEquals(TranslationState.Failed("Translation did not finish. Tap to retry."), turn.translationState)
        store.retryTranslation(turn)
        runCurrent()
        assertEquals(listOf("Where is the bus?"), translator.requests)
        assertEquals("[Where is the bus?]", turn.translation)
        // A late native result cannot replace the retried translation or add a row.
        store.handle(segment(0, "Where is the bus?", "公交车在哪里？", closed = true, language = Language.ENGLISH))
        assertEquals("[Where is the bus?]", turn.translation)
        assertEquals(1, store.visibleUtterances.size)
    }

    @Test fun aNewEngineDoesNotReuseTheOldOnesSegmentIds() = runTest {
        val (store, _) = store()
        store.startListening(); runCurrent()
        store.handle(segment(0, "First session.", "第一次。", closed = true))
        store.stopListening()
        advanceTimeBy(ConversationStore.WARM_PAUSE_MS + 1)
        store.startListening(); runCurrent()
        store.handle(segment(0, "Second session.", "第二次。", closed = true))
        assertEquals(listOf("First session.", "Second session."), store.visibleUtterances.map { it.source })
    }

    // endregion

    // region Settings

    @Test fun newInstallsStartOnAutomaticAndExistingOnesKeepTheirPair() {
        val fresh = MemoryStore()
        assertEquals(ConversationMode.AUTOMATIC, AppSettings(fresh, fresh, listOf(provider())).conversationMode)
        // Saved at once, so finishing the welcome tour doesn't change it.
        fresh.putBool("onboardingDone", true)
        assertEquals(ConversationMode.AUTOMATIC, AppSettings(fresh, fresh, listOf(provider())).conversationMode)

        val existing = MemoryStore()
        existing.putBool("onboardingDone", true)
        val settings = AppSettings(existing, existing, listOf(provider()))
        assertEquals(ConversationMode.PAIR, settings.conversationMode)
        assertFalse(settings.usesAutomaticLanguageDetection)
        settings.conversationMode = ConversationMode.AUTOMATIC
        assertEquals(ConversationMode.AUTOMATIC, AppSettings(existing, existing, listOf(provider())).conversationMode)
    }

    @Test fun automaticDetectionNeedsSoniox() {
        val settings = AppSettings(memory, memory, listOf(provider(), provider(SpeechProviders.VOXTRAL_ID)))
        assertEquals(ConversationMode.AUTOMATIC, settings.conversationMode)
        assertTrue(settings.usesAutomaticLanguageDetection)
        settings.providerID = SpeechProviders.VOXTRAL_ID
        assertFalse(settings.usesAutomaticLanguageDetection)
        settings.providerID = SpeechProviders.SONIOX_ID
        settings.conversationMode = ConversationMode.PAIR
        assertFalse(settings.usesAutomaticLanguageDetection)
    }

    @Test fun listenerLanguageIsAnySonioxLanguageInAutomaticAndOneOfThePairOtherwise() {
        val settings = AppSettings(memory, memory, listOf(provider()))
        assertEquals(Language.ENGLISH, settings.speechListenerLanguage)
        settings.speechListenerLanguage = fr
        assertEquals(fr, settings.speechListenerLanguage)
        settings.speechListenerLanguage = Language("xx")
        assertEquals(fr, settings.speechListenerLanguage)
        assertEquals("fr", memory.string("speechListenerLanguage"))

        // French isn't in the saved pair, so the pair's first language stands in.
        settings.conversationMode = ConversationMode.PAIR
        assertEquals(Language.ENGLISH, settings.speechListenerLanguage)
        settings.speechListenerLanguage = ja
        assertEquals(Language.ENGLISH, settings.speechListenerLanguage)
        settings.speechListenerLanguage = Language.CHINESE
        assertEquals(Language.CHINESE, settings.speechListenerLanguage)
        // A saved code Soniox doesn't know falls back to English.
        memory.putString("speechListenerLanguage", "xx")
        memory.putString("conversationMode", "automatic")
        assertEquals(Language.ENGLISH, AppSettings(memory, memory, listOf(provider())).speechListenerLanguage)
    }

    @Test fun changingModeOrListenerStartsANewConversation() = runTest {
        val (store, settings) = store(withTranslator = true, automatic = true)
        store.startListening(); runCurrent()
        assertTrue(store.isAutomaticLanguageMode)
        store.handle(heard(0, "こんにちは。", ja, "Hello."))
        settings.speechListenerLanguage = fr
        store.settingsDidClose()
        assertTrue(store.utterances.isEmpty())
        assertNull(store.detectedPartnerLanguage)
        assertEquals(fr, store.listenerLanguage)
        assertFalse(store.isListening)

        store.handle(SpeechEvent.AutoSegment(heard(1, "こんにちは。", ja, "Bonjour.").segment.copy(target = fr)))
        assertEquals(1, store.utterances.size)
        settings.conversationMode = ConversationMode.PAIR
        store.settingsDidClose()
        assertFalse(store.isAutomaticLanguageMode)
        assertTrue(store.utterances.isEmpty())
    }

    // endregion

    // region Automatic conversations

    @Test fun firstForeignFinalTurnSetsThePartner() = runTest {
        val store = automaticStore()
        store.handle(own(0, "Where is the station?"))
        val question = store.visibleUtterances.single()
        assertNull(question.target)
        assertEquals(TranslationState.AwaitingPartner, question.translationState)
        assertTrue(question.waitsForAutomaticPartner)
        assertNull(store.detectedPartnerLanguage)

        // Words still being heard aren't evidence yet.
        store.handle(SpeechEvent.AutoSegment(heard(1, "あそこ", ja, "Over", evidence = false).segment.copy(isClosed = false, isSourceFinal = false)))
        assertNull(store.detectedPartnerLanguage)
        store.handle(heard(1, "あそこです。", ja, "It is over there."))
        assertEquals(ja, store.detectedPartnerLanguage)
        val answer = store.visibleUtterances[1]
        assertEquals(ja, answer.sourceLanguage)
        assertEquals(Language.ENGLISH, answer.target)
        assertEquals("It is over there.", answer.translation)
        assertEquals(TranslationState.Current, answer.translationState)

        // The waiting question is translated now, as text, into the language just heard.
        runCurrent()
        assertEquals(ja, question.target)
        assertEquals(listOf("Where is the station?"), translator.requests)
        assertEquals(listOf(Language.ENGLISH to ja), translator.directions)
        assertEquals("[Where is the station?]", question.translation)
        assertFalse(question.waitsForAutomaticPartner)

        // Later replies go straight to the partner's language.
        store.handle(own(2, "Thank you."))
        runCurrent()
        assertEquals(ja, store.visibleUtterances[2].target)
        assertEquals("[Thank you.]", store.visibleUtterances[2].translation)
    }

    @Test fun aDifferentLanguageNeedsTwoAgreeingFinalTurnsToReplaceThePartner() = runTest {
        val store = automaticStore()
        store.handle(heard(0, "こんにちは。", ja, "Hello."))
        assertEquals(ja, store.detectedPartnerLanguage)
        store.handle(heard(1, "Bonjour.", fr, "Hello."))
        assertEquals(ja, store.detectedPartnerLanguage)
        // The same segment reported again is one turn, not two.
        store.handle(heard(1, "Bonjour.", fr, "Hello."))
        assertEquals(ja, store.detectedPartnerLanguage)
        // The established language in between starts the count again.
        store.handle(heard(2, "はい。", ja, "Yes."))
        store.handle(heard(3, "Merci.", fr, "Thank you."))
        assertEquals(ja, store.detectedPartnerLanguage)
        store.handle(heard(4, "Au revoir.", fr, "Goodbye."))
        assertEquals(fr, store.detectedPartnerLanguage)

        // Completed history keeps its own direction.
        assertEquals(ja, store.visibleUtterances[0].sourceLanguage)
        store.handle(own(5, "Goodbye."))
        runCurrent()
        assertEquals(fr, store.visibleUtterances.last().target)
    }

    @Test fun passthroughAndWordlessTurnsAreNotEvidence() = runTest {
        val store = automaticStore()
        // A name the engine passed through unchanged could be any language.
        store.handle(heard(0, "Tanaka.", ja, "Tanaka"))
        assertNull(store.detectedPartnerLanguage)
        store.handle(heard(1, "123", ja, "123."))
        assertNull(store.detectedPartnerLanguage)
        // The engine didn't vouch for this one.
        store.handle(heard(2, "こんにちは。", ja, "Hello.", evidence = false))
        assertNull(store.detectedPartnerLanguage)
        // The listener's own language is never the partner.
        store.handle(SpeechEvent.AutoSegment(own(3, "Hello there.").segment.copy(isPartnerEvidence = true)))
        assertNull(store.detectedPartnerLanguage)
        store.handle(heard(4, "こんにちは。", ja, "Hello."))
        assertEquals(ja, store.detectedPartnerLanguage)
    }

    @Test fun catchUpAudioIsNotEvidence() = runTest {
        val store = automaticStore()
        store.handle(own(0, "Before the dropout."))
        store.handle(SpeechEvent.SessionReset)
        store.handle(own(1, "After it."))
        store.handle(heard(2, "こんにちは。", ja, "Hello.", catchUp = true))
        assertNull(store.detectedPartnerLanguage)
        // It is still shown, where the dropout happened.
        assertEquals(listOf("Before the dropout.", "こんにちは。", "After it."), store.visibleUtterances.map { it.source })
        assertTrue(store.visibleUtterances[1].isLate)
        assertEquals("Hello.", store.visibleUtterances[1].translation)
    }

    @Test fun onlyTheNewestThreeWaitingTurnsAreBackfilled() = runTest {
        val store = automaticStore()
        for (id in 0 until 5) store.handle(own(id, "Question $id?"))
        store.handle(heard(5, "こんにちは。", ja, "Hello."))
        runCurrent()
        assertEquals(listOf("Question 2?", "Question 3?", "Question 4?"), translator.requests)
        val waiting = store.visibleUtterances.take(5)
        assertTrue(waiting.all { it.target == ja && it.suppressesAutomaticSpeech })
        assertEquals(listOf("", "", "[Question 2?]", "[Question 3?]", "[Question 4?]"), waiting.map { it.translation })
        // Older ones offer Translate instead.
        assertEquals(TranslationState.Idle, waiting[0].translationState)
        store.retryTranslation(waiting[0])
        runCurrent()
        assertEquals("[Question 0?]", waiting[0].translation)
        assertEquals(TranslationState.Current, waiting[0].translationState)
    }

    @Test fun contextExpiresAfterTenMinutes() = runTest {
        val store = automaticStore()
        store.handle(heard(0, "こんにちは。", ja, "Hello."))
        assertEquals(ja, store.detectedPartnerLanguage)
        clock += ConversationStore.CONTEXT_EXPIRY_MS
        store.handle(own(1, "Still here."))
        assertEquals(ja, store.detectedPartnerLanguage)
        clock += ConversationStore.CONTEXT_EXPIRY_MS + 1
        store.handle(own(2, "Excuse me."))
        assertNull(store.detectedPartnerLanguage)
        val later = store.visibleUtterances.last()
        assertNull(later.target)
        assertEquals(TranslationState.AwaitingPartner, later.translationState)
        // The earlier conversation stays as it was.
        assertEquals(3, store.visibleUtterances.size)
        assertEquals("Hello.", store.visibleUtterances[0].translation)
        // One French turn is enough for the new encounter.
        store.handle(heard(3, "Bonjour.", fr, "Hello."))
        assertEquals(fr, store.detectedPartnerLanguage)
        runCurrent()
        assertEquals(fr, later.target)
    }

    @Test fun clearingStartsANewAutomaticConversation() = runTest {
        val store = automaticStore()
        store.handle(heard(0, "こんにちは。", ja, "Hello."))
        store.clear()
        runCurrent()
        assertNull(store.detectedPartnerLanguage)
        assertTrue(store.utterances.isEmpty())
        // The old session is gone, so its late events can't reach the new conversation.
        assertEquals(1, engine.stopped)
        assertTrue(store.isListening)
    }

    @Test fun typedTurnsDetectTheirLanguage() = runTest {
        val store = automaticStore()
        // The typist's language is the hint when the text isn't clearly something else.
        store.submitTyped("Where is the station?", Language.ENGLISH)
        val waiting = store.visibleUtterances.single()
        assertEquals(Language.ENGLISH, waiting.sourceLanguage)
        assertNull(waiting.target)
        assertEquals(TranslationState.AwaitingPartner, waiting.translationState)
        assertTrue(translator.requests.isEmpty())

        // Japanese is clear from its script, whatever the hint says.
        store.submitTyped("駅はどこですか", Language.ENGLISH)
        runCurrent()
        val japanese = store.visibleUtterances[1]
        assertEquals(ja, japanese.sourceLanguage)
        assertEquals(Language.ENGLISH, japanese.target)
        assertEquals("[駅はどこですか]", japanese.translation)
        // Typed text isn't spoken evidence of who is here.
        assertNull(store.detectedPartnerLanguage)

        store.handle(heard(0, "こんにちは。", ja, "Hello."))
        store.submitTyped("Thank you.", Language.ENGLISH)
        runCurrent()
        assertEquals(ja, store.visibleUtterances.last().target)
        assertEquals("[Thank you.]", store.visibleUtterances.last().translation)
    }

    @Test fun clearLanguagesAreDetectedAmongAllOfThem() {
        val all = Language.SONIOX
        assertEquals(ja, LanguageDetector.detect("駅はどこですか", among = all))
        assertEquals(Language.CHINESE, LanguageDetector.detect("车站在哪里？", among = all))
        assertEquals(Language("ko"), LanguageDetector.detect("역이 어디예요?", among = all))
        assertEquals(Language("th"), LanguageDetector.detect("สถานีอยู่ที่ไหน", among = all))
        // Scripts several languages share go to the platform classifier.
        assertNull(LanguageDetector.detect("Where is the station?", among = all))
        assertNull(LanguageDetector.detect("Где вокзал?", among = all))
        // Mixed text isn't clear enough, and neither is text without letters.
        assertNull(LanguageDetector.detect("駅 station please", among = all))
        assertNull(LanguageDetector.detect("123 !?", among = all))
        val saved = LanguageDetector.amongFallback
        LanguageDetector.amongFallback = { _, candidates -> candidates.firstOrNull { it.code == "es" } }
        try {
            assertEquals(Language("es"), LanguageDetector.detect("¿Dónde está la estación?", among = all))
        } finally {
            LanguageDetector.amongFallback = saved
        }
    }

    @Test fun automaticTextTranslationWaitsForTheNetwork() = runTest {
        val store = automaticStore()
        store.handle(heard(0, "こんにちは。", ja, "Hello."))
        store.setNetwork(online = false, changedInterface = false)
        store.handle(own(1, "Where is the station?"))
        runCurrent()
        val question = store.visibleUtterances.last()
        assertEquals(ja, question.target)
        assertEquals(TranslationState.WaitingForNetwork, question.translationState)
        assertTrue(translator.requests.isEmpty())
        store.setNetwork(online = true, changedInterface = false)
        runCurrent()
        assertEquals("[Where is the station?]", question.translation)
        assertEquals(TranslationState.Current, question.translationState)
    }

    @Test fun interruptedAutomaticTurnsOfferARetry() = runTest {
        val store = automaticStore()
        store.handle(heard(0, "こんにちは。", ja, "Hello."))
        // Heard but not finished by the provider when the session dropped.
        store.handle(own(1, "Where is the", final = false))
        store.handle(SpeechEvent.SessionReset)
        val cut = store.visibleUtterances.last()
        assertTrue(cut.isFinal)
        assertEquals(ja, cut.target)
        assertEquals(TranslationState.Failed("Translation interrupted. Tap to retry."), cut.translationState)
        assertTrue(translator.requests.isEmpty())
        store.retryTranslation(cut)
        runCurrent()
        assertEquals("[Where is the]", cut.translation)
    }

    @Test fun pairedEventsAreIgnoredOutsideTheirMode() = runTest {
        val (store, _) = store()
        store.startListening(); runCurrent()
        store.handle(heard(0, "こんにちは。", ja, "Hello."))
        assertTrue(store.utterances.isEmpty())
        assertNull(store.detectedPartnerLanguage)
    }

    // endregion
}
