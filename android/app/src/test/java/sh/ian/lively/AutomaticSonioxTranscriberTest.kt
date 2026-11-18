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
import sh.ian.lively.net.AutoSpeechSegment
import sh.ian.lively.net.AutomaticSonioxTranscriber
import sh.ian.lively.net.SocketSignal
import sh.ian.lively.net.SocketStream
import sh.ian.lively.net.SonioxTranscriber
import sh.ian.lively.net.SpeechEvent
import sh.ian.lively.net.WsMessage

/**
 * The one-way token parser, driven through `receive` without a network.
 * Mirrors Tools/tests/AutomaticSonioxRegression.swift.
 */
class AutomaticSonioxTranscriberTest {
    private val ja = Language("ja")
    private val fr = Language("fr")

    private class Harness(listener: Language = Language.ENGLISH) {
        val engine = AutomaticSonioxTranscriber(
            AutomaticSonioxTranscriber.Configuration(SonioxTranscriber.Credential.ApiKey("test-only-unused"), listener),
            TestScope(),
        )
        val events = mutableListOf<AutoSpeechSegment>()
        var resets = 0

        init {
            engine.onEvent = { event ->
                if (event is SpeechEvent.AutoSegment) events += event.segment
                if (event == SpeechEvent.SessionReset) resets += 1
            }
        }

        fun send(vararg tokens: JsonObject, stream: Int = 0, catchUp: Boolean = false) =
            engine.receive(WsMessage.json(buildJsonObject { put("tokens", JsonArray(tokens.toList())) }), SocketStream(stream, catchUp))

        /** The newest state of every segment that still has something to show. */
        val visible: List<AutoSpeechSegment>
            get() = events.associateBy { it.id }.values
                .filter { it.source.isNotEmpty() || it.translation.isNotEmpty() }
                .sortedBy { it.id }
    }

    private fun source(text: String, language: String?, final: Boolean = true, status: String = "none") = buildJsonObject {
        put("text", text)
        put("is_final", final)
        put("translation_status", status)
        language?.let { put("language", it) }
    }

    private fun translated(text: String, language: String?, final: Boolean = true, target: String = "en") = buildJsonObject {
        put("text", text)
        put("is_final", final)
        put("translation_status", "translation")
        put("language", target)
        language?.let { put("source_language", it) }
    }

    private val end = buildJsonObject {
        put("text", "<end>")
        put("is_final", true)
    }

    @Test fun sessionIsOneWayIntoTheListenersLanguageWithoutHints() {
        val config = Harness(ja).engine.openingMessages().single().jsonObject!!
        val translation = config["translation"] as JsonObject
        assertEquals(mapOf("type" to JsonPrimitive("one_way"), "target_language" to JsonPrimitive("ja")), translation.toMap())
        assertFalse("language_hints" in config)
        assertFalse("language_hints_strict" in config)
        assertEquals(JsonPrimitive(true), config["enable_language_identification"])
        assertEquals(JsonPrimitive(16_000), config["sample_rate"])
        assertEquals(JsonPrimitive(1), config["num_channels"])
    }

    @Test fun recordedSessionBecomesFourSegments() {
        val harness = Harness()
        val lines = javaClass.getResource("/automatic-soniox-one-way.jsonl")!!.readText().lines().filter { it.isNotBlank() }
        var boundaries = 0
        for (line in lines) {
            if (harness.engine.receive(WsMessage.Text(line), SocketStream(0, false)) == SocketSignal.Boundary) boundaries += 1
        }
        val real = harness.visible
        assertEquals(
            listOf("Thank you very much.", "ありがとうございます。", "Thank you very much.", "ありがとうございます。"),
            real.map { it.source.trim() },
        )
        assertEquals(listOf(Language.ENGLISH, ja, Language.ENGLISH, ja), real.map { it.language })
        // English has no invented outgoing target.
        assertEquals(listOf(null, Language.ENGLISH, null, Language.ENGLISH), real.map { it.target })
        assertEquals(listOf("", "Thank you very much.", "", "Thank you very much."), real.map { it.stableTranslation.trim() })
        assertTrue(real.all { it.isClosed && it.isSourceFinal && it.languageIsFinal })
        assertTrue(boundaries > 0)
    }

    @Test fun listenerSpeechHasNoTargetAndALocalTimeoutIsNotProviderCompletion() {
        val harness = Harness()
        harness.send(source("Where is the station?", "en"))
        val open = harness.visible.single()
        assertEquals("Where is the station?", open.source)
        assertNull(open.target)
        assertTrue(open.languageIsFinal)
        assertFalse(open.isPartnerEvidence)
        harness.engine.endTurn()
        assertTrue(harness.visible.single().isClosed)
        assertFalse(harness.visible.single().isSourceFinal)
        assertEquals(SocketSignal.Boundary, harness.send(end))
        val done = harness.visible.single()
        assertEquals(open.id, done.id)
        assertTrue(done.isSourceFinal)
        assertNull(done.target)
    }

    @Test fun foreignSpeechIsPartnerEvidenceOnlyAtTheProviderEndpoint() {
        for (code in listOf("es", "fr", "ko", "pt-BR")) {
            val harness = Harness()
            harness.send(source("Original $code", code, status = "original"), translated("Incoming $code", code))
            assertEquals("Incoming $code", harness.visible.first().stableTranslation)
            assertTrue(harness.visible.first().languageIsFinal)
            assertFalse(harness.visible.first().isPartnerEvidence)
            harness.send(end)
            val segment = harness.visible.first()
            // Regional tags are normalized.
            assertEquals(Language(code.lowercase().substringBefore('-')), segment.language)
            assertTrue(segment.languageIsFinal && segment.isPartnerEvidence)
            assertEquals(Language.ENGLISH, segment.target)
        }
    }

    @Test fun foreignReplyDoesNotTakeTheListenersWords() {
        val harness = Harness()
        harness.send(source("Where is it?", "en"), source("あそこです。", "ja", status = "original"), translated("It is there.", "ja"), end)
        assertEquals(listOf("Where is it?", "あそこです。"), harness.visible.map { it.source })
        assertEquals(listOf(null, Language.ENGLISH), harness.visible.map { it.target })
    }

    @Test fun withdrawnPreviewIsRetracted() {
        val harness = Harness()
        harness.send(source("wrong", "es", final = false, status = "original"), translated("wrong preview", "es", final = false))
        assertEquals("", harness.visible.first().stableTranslation)
        assertFalse(harness.visible.first().languageIsFinal)
        harness.send()
        assertTrue(harness.visible.isEmpty())
        val ghost = harness.events.last()
        assertTrue(ghost.source.isEmpty() && ghost.translation.isEmpty() && ghost.isClosed)
        harness.send(source("Hola", "es", final = false, status = "original"))
        harness.engine.sessionDidReset(SocketStream(0, false))
        assertTrue(harness.visible.isEmpty())
        assertEquals(1, harness.resets)
    }

    @Test fun catchUpAudioIsNotPartnerEvidence() {
        val harness = Harness()
        harness.send(source("Bonjour", "fr", status = "original"), translated("Hello", "fr"), end, stream = 4, catchUp = true)
        val late = harness.visible.single()
        assertTrue(late.isCatchUp && late.languageIsFinal && late.isSourceFinal)
        assertFalse(late.isPartnerEvidence)
        harness.send(source("Hello", "en"), end, stream = 5)
        assertEquals(2, harness.visible.map { it.id }.toSet().size)
    }

    @Test fun contradictoryOrMissingMetadataNeverConfirmsALanguage() {
        val contradiction = Harness()
        contradiction.send(source("こんにちは", "ja", status = "original"), translated("Hello", "es"), end)
        assertTrue(contradiction.visible.any { it.source == "こんにちは" && !it.isPartnerEvidence })
        assertTrue(contradiction.visible.any { it.stableTranslation == "Hello" && it.target == Language.ENGLISH && !it.languageIsFinal })

        val missing = Harness()
        missing.send(source("こんにちは", null, status = "original"), translated("Hello", null), end)
        assertTrue(missing.visible.all { it.language == null && !it.languageIsFinal })
        assertTrue(missing.visible.any { it.stableTranslation == "Hello" && it.target == Language.ENGLISH })
    }

    @Test fun identityAndOrphanTranslationsAreSuppressed() {
        val identity = Harness()
        identity.send(source("Hello", "en"), translated("Hello", "en"), end)
        assertEquals("", identity.visible.single().translation)

        val orphan = Harness()
        orphan.send(translated("Unsupported", "ja"), end)
        assertTrue(orphan.visible.isEmpty())
    }

    @Test fun foreignSpeechWithoutNativeTranslationFallsBackToTextTranslation() {
        val harness = Harness()
        harness.send(source("Bonjour", "fr", status = "original"))
        assertNull(harness.visible.first().target)
        harness.send(end)
        val segment = harness.visible.first()
        assertEquals(Language.ENGLISH, segment.target)
        assertEquals(fr, segment.language)
        assertTrue(segment.languageIsFinal)
        assertFalse(segment.isPartnerEvidence)
    }

    @Test fun listenerLanguageNeedNotBeEnglish() {
        val harness = Harness(ja)
        harness.send(source("Hello", "en", status = "original"), translated("こんにちは", "en", target = "ja"), end)
        assertEquals(Language.ENGLISH, harness.visible.first().language)
        assertEquals(ja, harness.visible.first().target)
    }

    @Test fun embeddedNamesAndLanguageSwitchesAtAnyTokenWidth() {
        for (size in listOf(1, 2, 100)) {
            fun chunks(text: String) = text.chunked(size)

            val mixed = Harness()
            for (value in chunks("We will meet ")) mixed.send(source(value, "en"))
            for (value in chunks("田中")) mixed.send(source(value, "ja", status = "original"))
            for (value in chunks(" at the station.")) mixed.send(source(value, "en"))
            mixed.send(end)
            assertEquals("size $size", listOf("We will meet 田中 at the station."), mixed.visible.map { it.source })
            assertNull(mixed.visible[0].target)
            assertEquals(Language.ENGLISH, mixed.visible[0].language)

            val chinese = Harness()
            for (value in chunks("我们去")) chinese.send(source(value, "zh", status = "original"))
            for (value in chunks(" Starbucks ")) chinese.send(source(value, "en"))
            for (value in chunks("喝咖啡。")) chinese.send(source(value, "zh", status = "original"))
            for (value in chunks("Let us have coffee at Starbucks.")) chinese.send(translated(value, "zh"))
            chinese.send(end)
            assertEquals("size $size", "我们去 Starbucks 喝咖啡。", chinese.visible.joinToString("") { it.source })
            val native = chinese.visible.single { it.stableTranslation.isNotEmpty() }
            assertEquals("Let us have coffee at Starbucks.", native.stableTranslation)
            assertTrue(native.target == Language.ENGLISH && native.language == Language.CHINESE && native.languageIsFinal)

            val switcher = Harness()
            for (value in chunks("Bonjour.")) switcher.send(source(value, "fr", status = "original"))
            for (value in chunks("Hello.")) switcher.send(translated(value, "fr"))
            for (value in chunks("こんにちは。")) switcher.send(source(value, "ja", status = "original"))
            for (value in chunks("Good day")) switcher.send(translated(value, "ja"))
            switcher.send(translated(".", null), end)
            assertEquals("size $size", listOf("Bonjour.", "こんにちは。"), switcher.visible.map { it.source })
            // Punctuation without metadata joins the last native direction.
            assertEquals("size $size", listOf("Hello.", "Good day."), switcher.visible.map { it.stableTranslation })
            assertEquals(listOf(fr, ja), switcher.visible.map { it.language })
            assertTrue(switcher.visible.all { it.languageIsFinal })
        }
    }

    @Test fun translationKeepsArrivingAfterALocalTimeout() {
        val harness = Harness()
        harness.send(source("ありがとう", "ja", status = "original"), translated("Thank", "ja"))
        val id = harness.visible.first().id
        harness.engine.endTurn()
        harness.send(translated(" you.", "ja"), end)
        val segment = harness.visible.single()
        assertEquals(id, segment.id)
        assertEquals("Thank you.", segment.stableTranslation)
        assertTrue(segment.isClosed && segment.isSourceFinal)
    }

    @Test fun errorsMapToSignals() {
        val harness = Harness()
        fun error(code: Int) = harness.engine.receive(
            WsMessage.json(buildJsonObject { put("error_code", code); put("error_message", "nope") }),
            SocketStream(0, false),
        )
        assertTrue(error(401) is SocketSignal.Fail)
        assertTrue(error(402) is SocketSignal.Fail)
        assertEquals(SocketSignal.Retry("nope", throttled = true), error(429))
        assertEquals(SocketSignal.Retry("nope"), error(503))
    }
}
