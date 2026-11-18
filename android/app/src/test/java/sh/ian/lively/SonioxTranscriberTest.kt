package sh.ian.lively

import kotlinx.coroutines.test.TestScope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.net.ResilientSocket
import sh.ian.lively.net.SocketSignal
import sh.ian.lively.net.SocketStream
import sh.ian.lively.net.SonioxTranscriber
import sh.ian.lively.net.SpeechEvent
import sh.ian.lively.net.SpeechSegment
import sh.ian.lively.net.WsMessage

/**
 * The paired two-way token parser, driven through `receive` without a
 * network. Mirrors Tools/tests/SonioxLanguageRegression.swift, and the
 * parser half of Tools/tests/OnlineProtocolRegression.swift.
 */
class SonioxTranscriberTest {
    private val ja = Language("ja")

    private class Capture {
        val events = mutableListOf<SpeechSegment>()
        var resets = 0
        val order = mutableListOf<String>()
        val last get() = events.lastOrNull()
        /** The newest state of every segment. */
        val latest: Map<Int, SpeechSegment> get() = events.associateBy { it.id }
        val turns get() = latest.values.sortedBy { it.id }
    }

    private fun engine(pair: LanguagePair = LanguagePair(Language.ENGLISH, ja)): Pair<SonioxTranscriber, Capture> {
        val capture = Capture()
        val engine = SonioxTranscriber(
            SonioxTranscriber.Configuration(SonioxTranscriber.Credential.ApiKey("test-only-unused"), pair),
            TestScope(),
        )
        engine.onEvent = { event ->
            if (event is SpeechEvent.Segment) {
                capture.events += event.segment
                capture.order += "segment"
            }
            if (event == SpeechEvent.SessionReset) {
                capture.resets += 1
                capture.order += "reset"
            }
        }
        return engine to capture
    }

    private fun token(
        text: String,
        language: String? = null,
        final: Boolean = true,
        status: String = "original",
        source: String? = null,
    ) = buildJsonObject {
        put("text", text)
        put("is_final", final)
        put("translation_status", status)
        language?.let { put("language", it) }
        source?.let { put("source_language", it) }
    }

    private fun send(engine: SonioxTranscriber, tokens: List<JsonObject>, stream: Int = 1, catchUp: Boolean = false) =
        engine.receive(WsMessage.json(buildJsonObject { put("tokens", JsonArray(tokens)) }), SocketStream(stream, catchUp))

    private fun send(engine: SonioxTranscriber, vararg tokens: JsonObject) = send(engine, tokens.toList())

    private fun translation(text: String, target: String, source: String, final: Boolean = true) =
        token(text, target, final, status = "translation", source = source)

    // region Basics

    @Test fun finalAndPendingTokensMakeOneSegment() {
        val (engine, capture) = engine(LanguagePair.DEFAULT)
        send(engine, token("Hello", "en"), token(" there", "en", final = false))
        assertEquals(SpeechSegment(0, "Hello there", "", language = Language.ENGLISH, isClosed = false), capture.last)
        // The next response replaces the pending words.
        send(engine, token(" there,", "en"), token(" friend", "en", final = false))
        assertEquals("Hello there, friend", capture.last?.source)
    }

    @Test fun endpointClosesTheSegmentAndSignalsABoundary() {
        val (engine, capture) = engine()
        send(engine, token("Hi", "en"))
        assertEquals(SocketSignal.Boundary, send(engine, token("<end>")))
        assertTrue(capture.last!!.isClosed)
    }

    @Test fun providerEndpointsSeparateTurnsAndTranslationFollowsItsOwnTurn() {
        val (engine, capture) = engine()
        send(engine, token("Good morning.", "en"), translation("おはよう。", "ja", "en"), token("<end>"), token("おはようございます。", "ja"))
        assertEquals(2, capture.latest.size)
        assertTrue(capture.latest.values.any { it.source == "Good morning." && it.language == Language.ENGLISH && it.isClosed })
        assertEquals("おはようございます。", capture.last?.source)
        assertEquals(ja, capture.last?.language)
        send(engine, translation("Good morning.", "en", "ja"))
        assertTrue(
            capture.latest.values.any {
                it.source == "Good morning." && it.translation == "おはよう。" && it.language == Language.ENGLISH
            },
        )
        assertEquals("Good morning.", capture.last?.translation)
        assertEquals(ja, capture.last?.language)
    }

    @Test fun orphanTranslationAfterABoundaryIsNotGuessedOntoAnOwner() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "en"), token("<end>"))
        val closed = capture.last?.id
        send(engine, translation("こんにちは", "ja", "en"))
        assertEquals(closed, capture.last?.id)
        assertEquals("", capture.last?.translation)
    }

    @Test fun translationOfTheOpenSegmentStaysWithIt() {
        val (engine, capture) = engine(LanguagePair.DEFAULT)
        send(engine, token("你好", "zh"), token("Hello", status = "translation", source = "zh"))
        assertEquals("Hello", capture.last?.translation)
        assertEquals("Hello", capture.last?.stableTranslation)
    }

    @Test fun errorsMapToSignals() {
        val (engine, _) = engine()
        fun error(code: Int) =
            engine.receive(WsMessage.Text("{\"error_code\":$code,\"error_message\":\"x\"}"), SocketStream(1, false))
        assertTrue(error(402) is SocketSignal.Fail)
        assertEquals(SocketSignal.Retry("x", throttled = true), error(429))
        assertTrue(error(503) is SocketSignal.Retry)
        assertTrue(error(401) is SocketSignal.Fail)
    }

    @Test fun finishedSessionsReconnect() {
        val (engine, _) = engine()
        assertTrue(engine.receive(WsMessage.Text("{\"tokens\":[],\"finished\":true}"), SocketStream(1, false)) is SocketSignal.Retry)
    }

    @Test fun resetClosesTheOpenSegment() {
        val (engine, capture) = engine()
        send(engine, token("Half a sent", "en"))
        engine.sessionDidReset(SocketStream(1, false))
        assertTrue(capture.last!!.isClosed)
        assertEquals(listOf("segment", "reset"), capture.order.takeLast(2))
    }

    @Test fun openingMessageAsksForTwoWayTranslation() {
        val (engine, _) = engine()
        val opening = engine.openingMessages().first().jsonObject!!
        assertEquals(JsonPrimitive(true), opening["enable_language_identification"])
        assertEquals(JsonArray(listOf(JsonPrimitive("en"), JsonPrimitive("ja"))), opening["language_hints"])
        val translation = opening["translation"] as JsonObject
        assertEquals(JsonPrimitive("two_way"), translation["type"])
        assertEquals(JsonPrimitive("en"), translation["language_a"])
        assertEquals(JsonPrimitive("ja"), translation["language_b"])
        assertNull(opening["language_hints_strict"])
        assertEquals(JsonPrimitive(16000), opening["sample_rate"])
        assertEquals(JsonPrimitive(1), opening["num_channels"])
    }

    @Test fun trimSilenceKeepsSpeechWithPadding() {
        fun chunk(amplitude: Int) = ByteArray(2560) { i -> if (i % 2 == 0) (amplitude and 0xFF).toByte() else (amplitude shr 8).toByte() }
        val chunks = List(10) { chunk(0) } + List(5) { chunk(8000) } + List(30) { chunk(0) } + List(5) { chunk(8000) } + List(10) { chunk(0) }
        val kept = ResilientSocket.trimSilence(chunks)
        // 5 + 5 speech, 3 padding each side of both runs, and the 30-chunk pause cut to 10.
        assertEquals(3 + 5 + 10 + 5 + 3, kept.size)
        assertTrue(ResilientSocket.trimSilence(List(20) { chunk(0) }).isEmpty())
    }

    // endregion

    // region Language evidence

    @Test fun punctuationCannotRelabelASentence() {
        val (engine, capture) = engine()
        send(engine, token("Good morning", "en"), token(".", "ja"))
        assertEquals(Language.ENGLISH, capture.last?.language)
    }

    @Test fun nothingIsEmittedUntilTheProviderGivesLanguageEvidence() {
        val (engine, capture) = engine()
        send(engine, token("No"))
        assertTrue(capture.events.isEmpty())
        send(engine, translation("いいえ", "ja", "en"))
        assertEquals("No", capture.last?.source)
        assertEquals(Language.ENGLISH, capture.last?.language)

        val (spanish, spanishCapture) = engine(LanguagePair(Language.ENGLISH, Language("es")))
        send(spanish, token("No"), translation("No", "es", "en"))
        assertEquals(Language.ENGLISH, spanishCapture.last?.language)
    }

    @Test fun targetMetadataResolvesTheOtherLanguageAndBadMetadataIsRejected() {
        val (engine, capture) = engine()
        send(engine, token("OK"), token("了解", "ja", status = "translation"))
        assertEquals(Language.ENGLISH, capture.last?.language)
        assertEquals("了解", capture.last?.translation)
        // Same-language and out-of-pair translation metadata.
        send(engine, translation("duplicate", "en", "en"), translation("foreign", "ja", "fr"))
        assertEquals("了解", capture.last?.translation)
    }

    @Test fun regionalTagsResolveToTheConfiguredPair() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "EN_us"), translation("こんにちは", "ja-JP", "en-US"))
        assertEquals(Language.ENGLISH, capture.last?.language)
        assertEquals("こんにちは", capture.last?.translation)
    }

    @Test fun thirdLanguageWordsStayInTheSourceButNeverPickASide() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "en"), token(" Starbucks", "fr", status = "none"))
        assertEquals("Hello Starbucks", capture.last?.source)
        send(engine, translation("Bonjour", "fr", "en"))
        assertTrue(capture.latest.values.none { "Bonjour" in it.translation })

        val (foreign, foreignCapture) = engine()
        send(foreign, token("Bonjour", "fr", status = "none"), token("<end>"))
        assertTrue(foreignCapture.events.isEmpty())
    }

    @Test fun mixedWordTagsWaitForTheSentenceTranslation() {
        val (engine, capture) = engine(LanguagePair(Language.ENGLISH, Language.CHINESE))
        send(engine, token("我们去", "zh"), token(" Starbucks", "en"), token("喝咖啡。", "zh"))
        assertTrue(capture.events.isEmpty())
        send(engine, translation("Let's go to Starbucks for coffee.", "en", "zh"), token("<end>"))
        assertEquals(1, capture.latest.size)
        assertEquals("我们去 Starbucks喝咖啡。", capture.last?.source)
        assertEquals(Language.CHINESE, capture.last?.language)
        assertEquals("Let's go to Starbucks for coffee.", capture.last?.translation)

        val (close, closeCapture) = engine(LanguagePair(Language("no"), Language("da")))
        send(
            close,
            token("Jeg", "no"), token(" heter", "da"), token(" Ola", "no"),
            translation("Jeg hedder Ola", "da", "no"), token("<end>"),
        )
        assertEquals(1, closeCapture.latest.size)
        assertEquals("Jeg heter Ola", closeCapture.last?.source)
        assertEquals(Language("no"), closeCapture.last?.language)
    }

    @Test fun finalTranslationMetadataCorrectsTentativeTagsAndFoldsAnEmbeddedName() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "ja"))
        val id = capture.last?.id
        send(engine, translation("こんにちは", "ja", "en"))
        assertEquals(id, capture.last?.id)
        assertEquals(Language.ENGLISH, capture.last?.language)
        assertEquals("こんにちは", capture.last?.stableTranslation)
        // A foreign word waits without changing an established direction.
        send(engine, token(" Starbucks", "ja"))
        assertEquals("Hello", capture.last?.source)
        assertEquals(Language.ENGLISH, capture.last?.language)
        engine.endTurn()
        send(engine, token("!", "en"), token("<fin>"))
        assertEquals(id, capture.last?.id)
        assertEquals("Hello Starbucks!", capture.last?.source)
        assertEquals(Language.ENGLISH, capture.last?.language)
        assertEquals("こんにちは", capture.last?.stableTranslation)
        assertTrue(capture.last!!.isClosed)
    }

    // endregion

    // region Local timeouts and previews

    @Test fun endTurnClosesTheTurnButKeepsItsIdUntilTheProviderBoundary() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "en"))
        val old = capture.last!!.id
        engine.endTurn()
        assertEquals(old, capture.last?.id)
        assertTrue(capture.last!!.isClosed)
        assertTrue(engine.isMidUtterance(SocketStream(1, false)))
        send(engine, translation("こんにちは", "ja", "en"), token("<fin>"))
        assertEquals(old, capture.last?.id)
        assertEquals("こんにちは", capture.last?.translation)
        send(engine, token("How are you?", "en"))
        assertTrue(capture.last?.id != old)
        assertEquals("How are you?", capture.last?.source)
        send(engine, translation("お元気ですか", "ja", "en"))
        assertEquals("こんにちは", capture.latest[old]?.translation)
        assertEquals("お元気ですか", capture.last?.translation)
    }

    @Test fun provisionalMetadataIdentifiesAnUnknownLocallyClosedTurn() {
        val (engine, capture) = engine()
        send(engine, token("No"))
        engine.endTurn()
        send(engine, translation("いいえ", "ja", "en", final = false))
        assertEquals("No", capture.last?.source)
        assertEquals(Language.ENGLISH, capture.last?.language)
        assertEquals("", capture.last?.stableTranslation)
        val id = capture.last?.id
        send(engine, translation("いいえ", "ja", "en"), token("<fin>"))
        assertEquals(id, capture.last?.id)
        assertEquals("いいえ", capture.last?.stableTranslation)
    }

    @Test fun provisionalTextIsAnOverlayThatFinalTokensReplace() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "ja", final = false))
        val id = capture.last!!.id
        assertEquals(ja, capture.last?.language)
        assertEquals("", capture.last?.stableTranslation)
        send(engine, token("Hello", "en", final = false))
        assertEquals(id, capture.last?.id)
        assertEquals(Language.ENGLISH, capture.last?.language)
        send(engine, token("Hello", "en"), translation("こんにちは", "ja", "en"))
        assertEquals("Hello", capture.last?.source)
        assertEquals("こんにちは", capture.last?.stableTranslation)

        val (mixed, mixedCapture) = engine()
        send(mixed, token("Hello", "en", final = false), token("こんにちは", "ja", final = false))
        assertTrue(mixedCapture.events.isEmpty())
        send(
            mixed,
            token("Bonjour", "fr", final = false, status = "none"),
            token("Hello", "en", final = false),
            token("こんにちは", "ja", final = false),
            translation("Mixed original", "ja", "en", final = false),
        )
        assertEquals("BonjourHelloこんにちは", mixedCapture.last?.source)
        assertEquals(Language.ENGLISH, mixedCapture.last?.language)
    }

    @Test fun onlyFinalTranslationIsStable() {
        val (engine, capture) = engine()
        send(engine, token("Good morning", "en"), translation("おはよう", "ja", "en"))
        send(engine, translation("ございます", "ja", "en", final = false))
        assertEquals("おはようございます", capture.last?.translation)
        assertEquals("おはよう", capture.last?.stableTranslation)
        send(engine, translation("！", "ja", "en", final = false))
        assertEquals("おはよう！", capture.last?.translation)
        send(engine, translation("ございます", "ja", "en"))
        assertEquals("おはようございます", capture.last?.translation)
        assertEquals("おはようございます", capture.last?.stableTranslation)
        // Contradictory metadata, provisional or final, can't move a spoken translation.
        send(engine, translation("Wrong direction", "en", "ja", final = false))
        assertEquals(Language.ENGLISH, capture.last?.language)
        assertEquals("おはようございます", capture.last?.translation)
        assertEquals("おはようございます", capture.last?.stableTranslation)
        send(engine, translation("Wrong direction", "en", "ja"))
        assertEquals("おはようございます", capture.last?.translation)
    }

    @Test fun previewOnlyTextIsClearedAndClosedHoweverTheTurnEnds() {
        for (ending in listOf("reset", "stop", "side stream", "provider endpoint", "local timeout")) {
            val (engine, capture) = engine()
            send(engine, token("Hello", "en", final = false))
            val id = capture.last?.id
            when (ending) {
                "reset" -> engine.sessionDidReset(SocketStream(1, false))
                "stop" -> engine.stop()
                "side stream" -> engine.sideStreamDidEnd(SocketStream(1, true))
                "provider endpoint" -> send(engine, token("<end>"))
                else -> engine.endTurn()
            }
            assertEquals(ending, SpeechSegment(id!!, "", "", "", Language.ENGLISH, isClosed = true), capture.last)
            if (ending == "reset") assertEquals(listOf("segment", "reset"), capture.order.takeLast(2))
        }
    }

    @Test fun anEmptyTokenListRetractsThePreviousHypothesis() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "en", final = false))
        val id = capture.last?.id
        send(engine, emptyList())
        assertEquals(SpeechSegment(id!!, "", "", "", Language.ENGLISH, isClosed = false), capture.last)
        send(engine, token("Hello", "en", final = false))
        send(engine, token("Bonjour", "fr", final = false, status = "none"))
        assertEquals(id, capture.last?.id)
        assertEquals("", capture.last?.source)
        send(engine, token("Hello", "en"))
        assertEquals(id, capture.last?.id)
        assertEquals("Hello", capture.last?.source)
    }

    @Test fun withdrawnTranslationClearsOnlyTheOverlay() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "en"))
        send(engine, translation("こんにちは", "ja", "en", final = false))
        send(engine, emptyList())
        assertEquals("Hello", capture.last?.source)
        assertEquals("", capture.last?.translation)
        send(engine, translation("こんにちは", "ja", "en"))
        send(engine, emptyList())
        assertEquals("Hello", capture.last?.source)
        assertEquals("こんにちは", capture.last?.stableTranslation)

        // A remembered preview direction can't classify held words.
        val (held, heldCapture) = engine()
        send(held, token("No"))
        send(held, translation("いいえ", "ja", "en", final = false))
        val id = heldCapture.last?.id
        send(held, emptyList())
        assertEquals(id, heldCapture.last?.id)
        assertEquals("", heldCapture.last?.source)
        send(held, translation("いいえ", "ja", "en"))
        assertEquals(id, heldCapture.last?.id)
        assertEquals("No", heldCapture.last?.source)
        assertEquals("いいえ", heldCapture.last?.stableTranslation)
    }

    @Test fun anEmptyCorrectionRemembersTheLastSideShown() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "en", final = false))
        send(engine, token("こんにちは", "ja"), token("Hello", "en", final = false))
        send(engine, token(" Hello", "en"))
        assertEquals("", capture.last?.source)
        assertEquals(ja, capture.last?.language)
    }

    @Test fun anUnconfirmedPlaceholderCannotDisplaceTheTurnAwaitingItsTranslation() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "en"))
        val id = capture.last?.id
        engine.endTurn()
        send(engine, token("こんにちは", "ja", final = false))
        send(engine, emptyList())
        send(engine, translation("こんにちは", "ja", "en"), token("<fin>"))
        assertEquals(1, capture.latest.size)
        assertEquals(id, capture.last?.id)
        assertEquals("Hello", capture.last?.source)
        assertEquals("こんにちは", capture.last?.translation)

        val (order, orderCapture) = engine()
        send(order, token("No"), token("<end>"), token("こんにちは", "ja"), translation("Hello", "en", "ja"), token("<end>"))
        assertEquals(1, orderCapture.latest.size)
        assertEquals("こんにちは", orderCapture.last?.source)
    }

    // endregion

    // region Streams

    @Test fun severalEndpointsInOneResponseKeepDistinctClosedTurns() {
        val (engine, capture) = engine()
        send(
            engine,
            token("Hello", "en"), translation("こんにちは", "ja", "en"), token("<end>"),
            token("おはよう", "ja"), translation("Good morning", "en", "ja"), token("<end>"),
            token("Thanks", "en"), translation("ありがとう", "ja", "en"), token("<end>"),
        )
        assertTrue(capture.turns.all { it.isClosed })
        assertEquals(listOf("Hello", "おはよう", "Thanks"), capture.turns.map { it.source })
        assertEquals(listOf("こんにちは", "Good morning", "ありがとう"), capture.turns.map { it.translation })
        assertEquals(listOf(Language.ENGLISH, ja, Language.ENGLISH), capture.turns.map { it.language })
    }

    @Test fun liveAndCatchUpStreamsKeepSeparateSegments() {
        val (engine, capture) = engine()
        send(engine, listOf(token("Live", "en")), stream = 10)
        val liveID = capture.last!!.id
        send(engine, listOf(token("戻りました", "ja"), translation("I returned", "en", "ja")), stream = 11, catchUp = true)
        val caughtID = capture.last!!.id
        assertTrue(liveID != caughtID)
        assertTrue(capture.latest[caughtID]!!.isCatchUp)
        // A manual boundary closes only live streams.
        engine.endTurn()
        assertTrue(capture.latest[liveID]!!.isClosed)
        assertFalse(capture.latest[caughtID]!!.isClosed)
        engine.sideStreamDidEnd(SocketStream(11, true))
        assertTrue(capture.latest[caughtID]!!.isClosed)
        assertFalse(engine.isMidUtterance(SocketStream(11, true)))
        engine.sessionDidReset(SocketStream(10, false))
        assertEquals(1, capture.resets)
        send(engine, listOf(token("Fresh", "en")), stream = 10)
        assertTrue(capture.last?.id != liveID && capture.last?.id != caughtID)
    }

    @Test fun translationCannotBorrowASourceFromNowhereOrAnotherStream() {
        val (engine, capture) = engine()
        send(engine, translation("Hello", "en", "ja"), token("<end>"))
        assertTrue(capture.events.isEmpty())
        send(engine, listOf(token("Hello", "en")), stream = 1)
        send(engine, listOf(translation("Reply", "en", "ja"), token("<end>")), stream = 2)
        assertEquals(1, capture.latest.size)
        assertEquals(Language.ENGLISH, capture.last?.language)
        assertEquals("", capture.last?.stableTranslation)
    }

    // endregion

    // region Rapid replies

    @Test fun finalTranslationMetadataConfirmsARapidReply() {
        for (reverse in listOf(false, true)) for (delayed in listOf(false, true)) {
            val info = "reverse=$reverse, delayed=$delayed"
            val (engine, capture) = engine()
            val firstLanguage = if (reverse) "ja" else "en"
            val secondLanguage = if (reverse) "en" else "ja"
            val firstSource = if (reverse) "駅はどこですか？" else "Where is the station?"
            val firstTranslation = if (reverse) "Where is the station?" else "駅はどこですか？"
            val replySource = if (reverse) "It's over there." else "あそこです。"
            val replyTranslation = if (reverse) "あそこです。" else "It's over there."
            send(engine, token(firstSource, firstLanguage))
            val firstID = capture.last?.id
            if (delayed) send(engine, token(replySource, secondLanguage))
            send(engine, translation(firstTranslation, secondLanguage, firstLanguage))
            if (!delayed) send(engine, token(replySource, secondLanguage))
            // The unconfirmed reply is held outside the established source.
            assertEquals(info, 1, capture.latest.size)
            assertEquals(info, firstID, capture.last?.id)
            assertEquals(info, firstSource, capture.last?.source)
            // An opposite provisional translation can't confirm a boundary.
            send(engine, translation(replyTranslation, firstLanguage, secondLanguage, final = false))
            assertEquals(info, 1, capture.latest.size)
            assertEquals(info, firstTranslation, capture.last?.stableTranslation)
            send(engine, translation(replyTranslation, firstLanguage, secondLanguage), token("<end>"))
            val turns = capture.turns
            assertEquals(info, listOf(firstSource, replySource), turns.map { it.source })
            assertTrue(info, turns.all { it.isClosed })
            assertEquals(info, listOf(firstTranslation, replyTranslation), turns.map { it.translation })
            assertEquals(info, listOf(Language(firstLanguage), Language(secondLanguage)), turns.map { it.language })
            // Stable speech is never relabelled.
            for (turn in turns) {
                assertTrue(
                    info,
                    capture.events.filter { it.id == turn.id && it.stableTranslation.isNotEmpty() }.all { it.language == turn.language },
                )
            }
        }
    }

    @Test fun remainingFirstDirectionTranslationDoesNotConsumeTheHeldReply() {
        val (engine, capture) = engine()
        send(engine, token("Where is the station?", "en"), translation("駅は", "ja", "en"))
        send(engine, token("あそこです。", "ja"))
        send(engine, translation("どこですか？", "ja", "en"))
        send(engine, translation("It's over there.", "en", "ja"), token("<end>"))
        assertEquals(listOf("駅はどこですか？", "It's over there."), capture.turns.map { it.translation })
    }

    @Test fun aCleanReplyAppearsBeforeTheEndpoint() {
        for (reverse in listOf(false, true)) {
            val (engine, capture) = engine()
            val a = if (reverse) "ja" else "en"
            val b = if (reverse) "en" else "ja"
            val first = if (reverse) listOf("これ", "ですか？") else listOf("Where is", " the station?")
            val tq = if (reverse) listOf("Where is", " the station?") else listOf("これ", "ですか？")
            val second = if (reverse) listOf("Over", " there.") else listOf("あそこ", "です。")
            val tr = if (reverse) listOf("あそこ", "です。") else listOf("It's", " over there.")
            for (index in 0..1) send(engine, token(first[index], a), translation(tq[index], b, a))
            val firstID = capture.last?.id
            send(engine, token(second[0], b), translation(tr[0], a, b))
            assertEquals(2, capture.latest.size)
            assertEquals(Language(b), capture.last?.language)
            assertEquals(second[0], capture.last?.source)
            assertFalse(capture.last!!.isClosed)
            send(engine, token(second[1], b), translation(tr[1], a, b))
            assertEquals(second.joinToString(""), capture.last?.source)
            assertEquals(tr.joinToString(""), capture.last?.stableTranslation)
            // A reset can't merge the reply into the previous caption.
            engine.sessionDidReset(SocketStream(1, false))
            assertEquals(first.joinToString(""), capture.latest[firstID]?.source)
            assertEquals(second.joinToString(""), capture.last?.source)
        }
    }

    @Test fun aConfirmedReplyAfterALocalCloseGetsANewId() {
        val (engine, capture) = engine()
        send(engine, token("Where?", "en"), translation("どこ？", "ja", "en"))
        val id = capture.last?.id
        engine.endTurn()
        send(engine, token("あそこ。", "ja"), translation("There.", "en", "ja"), token("<fin>"))
        assertEquals(2, capture.latest.size)
        assertEquals("Where?", capture.latest[id]?.source)
        assertEquals("あそこ。", capture.last?.source)
        assertEquals("There.", capture.last?.translation)
    }

    @Test fun severalRapidDirectionsKeepOrderedSourcesAndTranslations() {
        val turns = listOf(
            listOf("Where?", "en", "どこ？", "ja"), listOf("あそこ。", "ja", "There.", "en"),
            listOf("Thanks.", "en", "ありがとう。", "ja"), listOf("どういたしまして。", "ja", "You're welcome.", "en"),
        )
        for (queued in listOf(false, true)) {
            val (engine, capture) = engine()
            if (queued) send(engine, turns.map { token(it[0], it[1]) })
            for ((source, language, translated, target) in turns) {
                send(engine, listOfNotNull(token(source, language).takeIf { !queued }, translation(translated, target, language)))
            }
            send(engine, token("<end>"))
            assertEquals("queued=$queued", turns.map { it[0] }, capture.turns.map { it.source })
            assertTrue("queued=$queued", capture.turns.all { it.isClosed })
            assertEquals("queued=$queued", turns.map { it[2] }, capture.turns.map { it.translation })
        }
    }

    @Test fun finalMetadataKeepsAReplyWithWrongOrMissingTags() {
        for (reverse in listOf(false, true)) {
            val originalLanguage = if (reverse) "ja" else "en"
            val replyLanguage = if (reverse) "en" else "ja"
            for (label in listOf(originalLanguage, null)) {
                val info = "reverse=$reverse, label=$label"
                val (engine, capture) = engine()
                val question = if (reverse) "駅はどこですか？" else "Where is the station?"
                val translatedQuestion = if (reverse) "Where is the station?" else "駅はどこですか？"
                val reply = if (reverse) "Yes" else "はい"
                val translatedReply = if (reverse) "はい" else "Yes"
                send(engine, token(question, originalLanguage), translation(translatedQuestion, replyLanguage, originalLanguage))
                val establishedID = capture.last?.id
                send(engine, token(reply, label))
                send(engine, translation(translatedReply, originalLanguage, replyLanguage), token("<end>"))
                val actual = capture.turns
                assertEquals(info, question + reply, actual.joinToString("") { it.source })
                assertEquals(info, listOf(Language(originalLanguage), Language(replyLanguage)), actual.map { it.language })
                assertEquals(info, establishedID, actual.first().id)
                assertEquals(info, listOf(translatedQuestion, translatedReply), actual.map { it.translation })
            }
        }
    }

    @Test fun formattingOnlyTranslationCannotEstablishADirection() {
        val (engine, capture) = engine()
        send(engine, token("Where?", "en"), translation("どこ？", "ja", "en"), token("はい", "ja"))
        send(engine, translation(".", "en", "ja"))
        assertEquals(1, capture.latest.size)
        send(engine, translation("Yes", "en", "ja"), token("<end>"))
        assertEquals(listOf("どこ？", "Yes"), capture.turns.map { it.translation })
    }

    // endregion

    // region Embedded names

    @Test fun aSameSourceContinuationFoldsAnEmbeddedNameBackInOrder() {
        val (engine, capture) = engine()
        send(engine, token("Let's go to", "en"), translation("行きましょう", "ja", "en"))
        val id = capture.last?.id
        send(engine, token(" Starbucks", "ja"))
        send(engine, token(" tomorrow.", "en"))
        assertEquals(1, capture.latest.size)
        assertEquals(id, capture.last?.id)
        assertEquals("Let's go to Starbucks tomorrow.", capture.last?.source)
        send(engine, translation("明日スターバックスに", "ja", "en"), token("<end>"))
        assertEquals(id, capture.last?.id)
        assertEquals(Language.ENGLISH, capture.last?.language)
        assertEquals("Let's go to Starbucks tomorrow.", capture.last?.source)
    }

    @Test fun aNameThenAReplyKeepsEveryOriginalAndTheConfirmedSpeech() {
        val (engine, capture) = engine()
        send(engine, token("Let's go to", "en"), translation("行きましょう", "ja", "en"))
        send(engine, token(" Starbucks", "ja"), token(" tomorrow.", "en"))
        send(engine, token("はい。", "ja"), translation("Yes.", "en", "ja"), token("<end>"))
        assertEquals("Let's go to Starbucks tomorrow.はい。", capture.turns.joinToString("") { it.source })
        assertEquals(Language.ENGLISH, capture.turns.first().language)
        assertTrue(capture.turns.any { it.language == ja && it.translation == "Yes." && it.stableTranslation == "Yes." })
    }

    @Test fun aTrailingForeignNameStaysInItsSentence() {
        val (engine, capture) = engine()
        send(engine, token("Let's go to", "en"), translation("行きましょう", "ja", "en"))
        send(engine, token(" Starbucks", "ja"), translation("スターバックスに", "ja", "en"), token("<end>"))
        assertEquals(1, capture.latest.size)
        assertEquals("Let's go to Starbucks", capture.last?.source)
        assertEquals("行きましょうスターバックスに", capture.last?.translation)

        val (third, thirdCapture) = engine()
        send(third, token("Let's go to", "en"), translation("行きましょう", "ja", "en"))
        send(third, token(" Le Café", "fr", status = "none"), token("<end>"))
        assertEquals(1, thirdCapture.latest.size)
        assertEquals("Let's go to Le Café", thirdCapture.last?.source)
        assertEquals(Language.ENGLISH, thirdCapture.last?.language)
    }

    @Test fun aWithdrawnPossibleReplyDonatesNothingToThePriorSource() {
        val (engine, capture) = engine()
        send(engine, token("Hello", "en"), translation("こんにちは", "ja", "en"))
        send(engine, token("あそこです。", "ja", final = false))
        send(engine, emptyList())
        send(engine, token("<end>"))
        assertEquals(1, capture.latest.size)
        assertEquals("Hello", capture.last?.source)
        assertEquals("こんにちは", capture.last?.translation)
    }

    @Test fun unreceiptedFoldedOriginalsStayLosslessAfterAnotherTranslationChunk() {
        val (engine, capture) = engine()
        send(engine, token("Let's go to", "en"), translation("行きましょう", "ja", "en"))
        send(engine, token(" Starbucks", "ja"), token(" tomorrow", "en"))
        send(engine, translation("明日スターバックスに", "ja", "en"))
        send(engine, translation("Invented reply", "en", "ja"), token("<end>"))
        assertEquals("Let's go to Starbucks tomorrow", capture.turns.joinToString("") { it.source })
        assertEquals(Language.ENGLISH, capture.turns.first().language)
        assertTrue(
            capture.turns.any { it.language == ja && it.translation == "Invented reply" && it.stableTranslation == "Invented reply" },
        )
    }

    // endregion

    // region Queued and ambiguous directions

    @Test fun queuedOriginalsKeepFourOwnersWhateverThePunctuation() {
        val original = listOf("One", "二", "Three", "四")
        val languages = listOf("en", "ja", "en", "ja")
        val translated = listOf("一", "Two", "三", "Four")
        for (punctuation in 0 until 16) {
            val (engine, capture) = engine()
            val sources = original.indices.map { original[it] + if (punctuation and (1 shl it) != 0) "." else "" }
            send(engine, sources.indices.map { token(sources[it], languages[it]) })
            for (index in original.indices) {
                send(engine, translation(translated[index], if (languages[index] == "en") "ja" else "en", languages[index]))
                if (index == 0) {
                    // The first stable direction holds every later source owner.
                    assertEquals("punctuation=$punctuation", sources[0], capture.last?.source)
                    assertEquals("punctuation=$punctuation", 1, capture.latest.size)
                }
            }
            send(engine, token("<end>"))
            assertEquals("punctuation=$punctuation", sources, capture.turns.map { it.source })
            assertEquals("punctuation=$punctuation", translated, capture.turns.map { it.translation })
            assertTrue("punctuation=$punctuation", capture.turns.all { it.isClosed })
        }
    }

    @Test fun equallyPlausiblePartitionsKeepTheCaptionAndEmitTranslationOnlySegments() {
        val (engine, capture) = engine()
        send(engine, token("One", "en"), token("二", "ja"), token("Three", "en"), token("四", "ja"))
        send(
            engine,
            translation("一", "ja", "en"), translation("Reply", "en", "ja"),
            token("!", status = "translation"), token("<end>"),
        )
        assertTrue(capture.latest.values.any { it.source == "One二Three四" })
        assertTrue(capture.events.filter { it.id == 0 && it.stableTranslation.isNotEmpty() }.all { it.language == Language.ENGLISH })
        assertEquals(2, capture.latest.size)
        assertEquals(SpeechSegment(capture.last!!.id, "", "Reply!", "Reply!", ja, isClosed = true), capture.last)

        val (late, lateCapture) = engine()
        val originals = listOf(token("One", "en"), token("二", "ja"), token("Three", "en"), token("四", "ja"))
        send(late, originals, stream = 7, catchUp = true)
        send(late, listOf(translation("一", "ja", "en"), translation("Reply", "en", "ja"), token("<end>")), stream = 7, catchUp = true)
        assertEquals("", lateCapture.last?.source)
        assertTrue(lateCapture.last!!.isCatchUp)
        assertEquals("Reply", lateCapture.last?.stableTranslation)
    }

    @Test fun anInterleavedReplySurvivesTheIncrementalFold() {
        for (reverse in listOf(false, true)) {
            val firstLanguage = if (reverse) "ja" else "en"
            val replyLanguage = if (reverse) "en" else "ja"
            val question = if (reverse) "これですか" else "Is it this one"
            val reply = if (reverse) "Yes" else "はい"
            val continuation = if (reverse) " 了解です" else " OK thanks"
            val translatedQuestion = if (reverse) "Is it this one" else "これですか"
            val translatedReply = if (reverse) "はい" else "Yes"
            for (punctuation in 0 until 8) for (label in listOf(replyLanguage, firstLanguage, null)) {
                val info = "reverse=$reverse, punctuation=$punctuation, tag=$label"
                val (engine, capture) = engine()
                val first = question + if (punctuation and 1 == 0) "" else "."
                val second = reply + if (punctuation and 2 == 0) "" else "."
                val third = continuation + if (punctuation and 4 == 0) "" else "."
                send(engine, token(first, firstLanguage), translation(translatedQuestion, replyLanguage, firstLanguage))
                val originalID = capture.last?.id
                send(engine, token(second, label))
                send(engine, token(third, firstLanguage))
                send(engine, translation(translatedReply, firstLanguage, replyLanguage))
                send(engine, token("<end>"))
                val final = capture.turns
                assertEquals(info, first + second + third, final.joinToString("") { it.source })
                assertTrue(
                    info,
                    final.any {
                        it.language == Language(replyLanguage) && it.translation == translatedReply &&
                            it.stableTranslation == translatedReply
                    },
                )
                assertEquals(info, originalID, final.first().id)
                assertEquals(info, Language(firstLanguage), final.first().language)
                assertEquals(info, translatedQuestion, final.first().translation)
            }
        }
    }

    private class Boundaries(val parts: Int, val split: Boolean, val third: Boolean, val width: Int, val label: Int, val punct: Boolean) {
        override fun toString() = "parts=$parts,split=$split,third=$third,width=$width,label=$label,punct=$punct"
    }

    private fun pieces(text: String, width: Int) = if (width > 0) text.chunked(width) else listOf(text)

    @Test fun tokenBoundariesDoNotChangeTheFinalDirections() {
        val scenarios = listOf(
            Boundaries(2, false, true, 0, 0, false), Boundaries(3, false, false, 0, 0, false),
            Boundaries(2, true, false, 0, 0, false), Boundaries(3, true, true, 0, 0, false),
            Boundaries(2, true, true, 1, 0, false), Boundaries(3, false, true, 2, 0, false),
            Boundaries(2, false, true, 1, 1, false), Boundaries(3, true, true, 2, 2, false),
            Boundaries(2, true, false, 1, 1, true), Boundaries(3, false, false, 2, 2, true),
            Boundaries(2, false, true, 2, 0, true), Boundaries(3, true, true, 1, 0, true),
        )
        for (reverse in listOf(false, true)) for (test in scenarios) {
            val info = "reverse=$reverse,$test"
            val a = if (reverse) "ja" else "en"
            val b = if (reverse) "en" else "ja"
            val (engine, capture) = engine()
            val q = (if (reverse) "これですか" else "Is it this one") + if (test.punct) "?" else ""
            val r = (if (reverse) "Yes" else "はい") + if (test.punct) "." else ""
            val continuation = when {
                reverse -> if (test.parts == 2) listOf(" 了解", "です") else listOf(" 了", "解", "です")
                else -> if (test.parts == 2) listOf(" OK", " thanks") else listOf(" O", "K", " thanks")
            }
            val tq = if (reverse) "Is it this one" else "これですか"
            val tr = if (reverse) "はい" else "Yes"
            val tc = if (reverse) "OK, thank you" else "了解、ありがとう"
            val label = when (test.label) { 0 -> b; 1 -> a; else -> null }
            fun original(text: String, language: String?) = send(engine, pieces(text, test.width).map { token(it, language) })
            fun translated(text: String, source: String) {
                val target = if (source == a) b else a
                for (part in pieces(text, test.width)) send(engine, translation(part, target, source))
            }
            original(q, a)
            translated(if (test.split) tq.take(1) else tq, a)
            val establishedID = capture.last?.id
            original(r, label)
            continuation.forEach { original(it, a) }
            if (test.split) translated(tq.drop(1), a)
            translated(tr, b)
            if (test.third) translated(tc, a)
            send(engine, token("<end>"))
            val actual = capture.turns
            val expectedText = listOfNotNull(tq, tr, tc.takeIf { test.third })
            val expectedLanguages = listOfNotNull(Language(a), Language(b), Language(a).takeIf { test.third })
            assertEquals(info, q + r + continuation.joinToString(""), actual.joinToString("") { it.source })
            assertEquals(info, expectedText, actual.map { it.translation })
            assertEquals(info, expectedText, actual.map { it.stableTranslation })
            assertEquals(info, expectedLanguages, actual.map { it.language })
            assertTrue(info, actual.all { it.isClosed })
            assertEquals(info, establishedID, actual.first().id)
            assertTrue(
                info,
                capture.events.filter { it.id == establishedID && it.stableTranslation.isNotEmpty() }.all { it.language == Language(a) },
            )
        }
    }

    @Test fun aRealFoldKeepsFourIncrementalOwners() {
        val (engine, capture) = engine()
        val exchange = listOf(
            listOf("Question", "en", "質問", "ja"), listOf("はい", "ja", "Yes", "en"),
            listOf(" OK thanks", "en", "了解", "ja"), listOf("どうも", "ja", "Welcome", "en"),
        )
        send(engine, token(exchange[0][0], "en"), translation(exchange[0][2], "ja", "en"))
        for (turn in exchange.drop(1)) send(engine, token(turn[0], turn[1]))
        for (turn in exchange.drop(1)) send(engine, translation(turn[2], turn[3], turn[1]))
        send(engine, token("<end>"))
        assertEquals(exchange.map { it[0] }, capture.turns.map { it.source })
        assertEquals(exchange.map { it[2] }, capture.turns.map { it.translation })
        assertEquals(exchange.map { Language(it[1]) }, capture.turns.map { it.language })
    }

    // endregion

    // region Online protocol frames

    private class Scenario(
        val name: String,
        val frames: List<List<JsonObject>>,
        /** Every original word, in order. */
        val sources: String,
        /** Each translation with the language it was spoken in. */
        val speech: List<Pair<String, Language>>,
    )

    private fun original(text: String, language: String) = token(text, language)

    private fun translated(text: String, source: String) = translation(text, if (source == "en") "ja" else "en", source)

    private fun protocolScenarios(): List<Scenario> {
        val end = buildJsonObject { put("text", "<end>"); put("is_final", true) }
        val question = "Where is the station?"
        val reply = "あそこです。"
        val translatedQuestion = "駅はどこですか？"
        val translatedReply = "It's over there."
        val english = Language.ENGLISH
        val cases = mutableListOf(
            Scenario(
                "rapid reply",
                listOf(
                    listOf(original(question, "en"), translated(translatedQuestion, "en")),
                    listOf(original(reply, "ja")), listOf(translated(translatedReply, "ja"), end),
                ),
                question + reply, listOf(translatedQuestion to english, translatedReply to ja),
            ),
            Scenario(
                "reverse reply",
                listOf(
                    listOf(original(translatedQuestion, "ja"), translated(question, "ja")),
                    listOf(original(translatedReply, "en")), listOf(translated(reply, "en"), end),
                ),
                translatedQuestion + translatedReply, listOf(question to ja, reply to english),
            ),
            Scenario(
                "delayed first translation",
                listOf(
                    listOf(original(question, "en"), original(reply, "ja")),
                    listOf(translated(translatedQuestion, "en")), listOf(translated(translatedReply, "ja"), end),
                ),
                question + reply, listOf(translatedQuestion to english, translatedReply to ja),
            ),
            Scenario(
                "four queued source groups",
                listOf(
                    listOf(original(question, "en"), original(reply, "ja"), original("Thank you.", "en"), original("どういたしまして。", "ja")),
                    listOf(
                        translated(translatedQuestion, "en"), translated(translatedReply, "ja"),
                        translated("ありがとうございます。", "en"), translated("You are welcome.", "ja"), end,
                    ),
                ),
                question + reply + "Thank you." + "どういたしまして。",
                listOf(translatedQuestion to english, translatedReply to ja, "ありがとうございます。" to english, "You are welcome." to ja),
            ),
            Scenario(
                "incremental folded reply",
                listOf(
                    listOf(original("Is it this one", "en"), translated("これですか", "en")),
                    listOf(original("はい", "ja")), listOf(original(" OK thanks", "en")),
                    listOf(translated("Yes", "ja")), listOf(end),
                ),
                "Is it this one" + "はい" + " OK thanks", listOf("これですか" to english, "Yes" to ja),
            ),
            Scenario(
                "incremental reverse folded reply",
                listOf(
                    listOf(original("これですか", "ja"), translated("Is it this one", "ja")),
                    listOf(original("Yes", "en")), listOf(original(" 了解です", "ja")),
                    listOf(translated("はい", "en")), listOf(end),
                ),
                "これですか" + "Yes" + " 了解です", listOf("Is it this one" to ja, "はい" to english),
            ),
            Scenario(
                "ambiguous source ownership",
                listOf(
                    listOf(original("One", "en"), original("二", "ja"), original("Three", "en"), original("四", "ja")),
                    listOf(translated("一", "en"), translated("Reply.", "ja"), end),
                ),
                "One二Three四", listOf("一" to english, "Reply." to ja),
            ),
        )
        for (reverse in listOf(false, true)) {
            val firstLanguage = if (reverse) "ja" else "en"
            val replyLanguage = if (reverse) "en" else "ja"
            val first = if (reverse) "これですか" else "Is it this one"
            val second = if (reverse) "Yes" else "はい"
            val continuation = if (reverse) listOf(" 了解", " ありがとう") else listOf(" OK", " thanks")
            val firstTranslation = if (reverse) "Is it this one" else "これですか"
            val replyTranslation = if (reverse) "はい" else "Yes"
            val continuationTranslation = if (reverse) "OK, thanks" else "了解、ありがとう"
            val firstLine = firstTranslation to Language(firstLanguage)
            val replyLine = replyTranslation to Language(replyLanguage)
            cases += Scenario(
                "incremental multi-token continuation reverse=$reverse",
                listOf(
                    listOf(original(first, firstLanguage), translated(firstTranslation, firstLanguage)),
                    listOf(original(second, replyLanguage)), continuation.map { original(it, firstLanguage) },
                    listOf(translated(replyTranslation, replyLanguage)),
                    listOf(translated(continuationTranslation, firstLanguage)), listOf(end),
                ),
                first + second + continuation.joinToString(""),
                listOf(firstLine, replyLine, continuationTranslation to Language(firstLanguage)),
            )
            val translationParts = if (reverse) listOf("Is it", " this one") else listOf("これ", "ですか")
            cases += Scenario(
                "incremental first translation spans fold reverse=$reverse",
                listOf(
                    listOf(original(first, firstLanguage), translated(translationParts[0], firstLanguage)),
                    listOf(original(second, replyLanguage)),
                    listOf(original(continuation.joinToString(""), firstLanguage)),
                    listOf(translated(translationParts[1], firstLanguage)),
                    listOf(translated(replyTranslation, replyLanguage)), listOf(end),
                ),
                first + second + continuation.joinToString(""), listOf(firstLine, replyLine),
            )
            for (queued in listOf(false, true)) {
                // The reply carries the first speaker's tag.
                val frames = if (queued) {
                    listOf(
                        listOf(original(first, firstLanguage)), listOf(original(second, firstLanguage)),
                        listOf(translated(translationParts[0], firstLanguage)),
                        listOf(translated(translationParts[1], firstLanguage)),
                        listOf(translated(replyTranslation, replyLanguage)), listOf(end),
                    )
                } else {
                    listOf(
                        listOf(original(first, firstLanguage), translated(translationParts[0], firstLanguage)),
                        listOf(original(second, firstLanguage)),
                        listOf(translated(translationParts[1], firstLanguage)),
                        listOf(translated(replyTranslation, replyLanguage)), listOf(end),
                    )
                }
                cases += Scenario(
                    "incremental single mistagged reply reverse=$reverse, queued=$queued",
                    frames, first + second, listOf(firstLine, replyLine),
                )
            }
            val firstParts = if (reverse) listOf("駅は", "どこ", "です", "か？") else listOf("Where", " is", " the", " station?")
            val cleanParts = if (reverse) listOf("Where is", " the station?") else listOf("駅は", "どこですか？")
            val replyParts = if (reverse) listOf("It's", " over there.") else listOf("あそこ", "です。")
            val replyTranslations = if (reverse) listOf("あそこ", "です。") else listOf("It's", " over there.")
            for (reset in listOf(false, true)) {
                cases += Scenario(
                    "clean mid-translation reply reverse=$reverse, reset=$reset",
                    listOf(
                        listOf(original(firstParts[0], firstLanguage), original(firstParts[1], firstLanguage), translated(cleanParts[0], firstLanguage)),
                        listOf(original(firstParts[2], firstLanguage), original(firstParts[3], firstLanguage), translated(cleanParts[1], firstLanguage)),
                        listOf(original(replyParts[0], replyLanguage)),
                        listOf(translated(replyTranslations[0], replyLanguage)),
                        listOf(original(replyParts[1], replyLanguage), translated(replyTranslations[1], replyLanguage)),
                        listOf(end),
                    ),
                    firstParts.joinToString("") + replyParts.joinToString(""),
                    listOf(cleanParts.joinToString("") to Language(firstLanguage), replyTranslations.joinToString("") to Language(replyLanguage)),
                )
            }
        }
        // Provider token boundaries are independent of words and sentences.
        // Replay the same cases with two-character and single-character tokens.
        val whole = cases.toList()
        for (width in listOf(2, 1)) for (scenario in whole) {
            val frames = scenario.frames.map { frame ->
                frame.flatMap { token ->
                    val text = (token["text"] as JsonPrimitive).content
                    if (text.startsWith("<")) listOf(token)
                    else text.chunked(width).map { piece -> JsonObject(token + ("text" to JsonPrimitive(piece))) }
                }
            }
            cases += Scenario("${scenario.name} token-width=$width", frames, scenario.sources, scenario.speech)
        }
        return cases
    }

    @Test fun protocolFramesKeepEveryOriginalWordAndEveryConfirmedTranslation() {
        for (scenario in protocolScenarios()) {
            val (engine, capture) = engine()
            scenario.frames.forEachIndexed { index, frame ->
                if ("reset=true" in scenario.name && index == scenario.frames.lastIndex) {
                    engine.sessionDidReset(SocketStream(1, false))
                } else {
                    send(engine, frame)
                }
            }
            val turns = capture.turns
            assertTrue(scenario.name, turns.all { it.isClosed })
            assertEquals(scenario.name, scenario.sources, turns.joinToString("") { it.source })
            // Each translation is final once, with the language of its source.
            val spoken = turns.filter { it.translation.isNotEmpty() }
            assertEquals(scenario.name, spoken.map { it.translation }, spoken.map { it.stableTranslation })
            assertEquals(
                scenario.name,
                scenario.speech.sortedBy { it.first },
                spoken.map { it.translation to it.language }.sortedBy { it.first },
            )
        }
    }

    // endregion
}
