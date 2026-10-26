package sh.ian.lively

import kotlinx.coroutines.test.TestScope
import org.junit.Assert.assertEquals
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

class SonioxTranscriberTest {
    private val events = mutableListOf<SpeechEvent>()
    private val transcriber = SonioxTranscriber(
        SonioxTranscriber.Configuration(SonioxTranscriber.Credential.ApiKey("k"), LanguagePair.DEFAULT),
        TestScope(),
    ).also { it.onEvent = { event -> events += event } }
    private val live = SocketStream(1, isCatchUp = false)

    private fun token(text: String, final: Boolean, language: String? = null, translation: Boolean = false, source: String? = null): String {
        val fields = mutableListOf("\"text\":\"$text\"", "\"is_final\":$final")
        language?.let { fields += "\"language\":\"$it\"" }
        if (translation) fields += "\"translation_status\":\"translation\""
        source?.let { fields += "\"source_language\":\"$it\"" }
        return fields.joinToString(",", "{", "}")
    }

    private fun receive(vararg tokens: String, stream: SocketStream = live) =
        transcriber.receive(WsMessage.Text("{\"tokens\":[${tokens.joinToString(",")}]}"), stream)

    private val segments get() = events.filterIsInstance<SpeechEvent.Segment>().map { it.segment }

    @Test fun finalAndPendingTokensMakeOneSegment() {
        receive(token("Hello", true, "en"), token(" there", false, "en"))
        assertEquals(SpeechSegment(0, "Hello there", "", language = Language.ENGLISH, isClosed = false), segments.last())
        // The next response replaces the pending words.
        receive(token(" there,", true, "en"), token(" friend", false, "en"))
        assertEquals("Hello there, friend", segments.last().source)
    }

    @Test fun endpointClosesTheSegmentAndSignalsABoundary() {
        receive(token("Hi", true, "en"))
        val signal = receive(token("<end>", true))
        assertEquals(SocketSignal.Boundary, signal)
        assertTrue(segments.last().isClosed)
    }

    @Test fun lateTranslationGoesToThePreviousSegment() {
        receive(token("Hi", true, "en"))
        receive(token("<end>", true))
        // Chinese starts before the English translation has finished.
        receive(token("你好", true, "zh"), token("嗨", true, translation = true, source = "en"))
        val english = segments.last { it.id == 0 }
        val chinese = segments.last { it.id == 1 }
        assertEquals("嗨", english.translation)
        assertEquals("你好", chinese.source)
        assertEquals("", chinese.translation)
    }

    @Test fun translationOfTheOpenSegmentStaysWithIt() {
        receive(token("你好", true, "zh"), token("Hello", true, translation = true, source = "zh"))
        assertEquals("Hello", segments.last().translation)
    }

    @Test fun catchUpStreamsAreMarked() {
        receive(token("Late words", true, "en"), stream = SocketStream(2, isCatchUp = true))
        assertTrue(segments.last().isCatchUp)
    }

    @Test fun errorsMapToSignals() {
        fun error(code: Int) = transcriber.receive(WsMessage.Text("{\"error_code\":$code,\"error_message\":\"x\"}"), live)
        assertTrue(error(402) is SocketSignal.Fail)
        assertEquals(SocketSignal.Retry("x", throttled = true), error(429))
        assertTrue(error(503) is SocketSignal.Retry)
        assertTrue(error(401) is SocketSignal.Fail)
    }

    @Test fun finishedSessionsReconnect() {
        assertTrue(transcriber.receive(WsMessage.Text("{\"tokens\":[],\"finished\":true}"), live) is SocketSignal.Retry)
    }

    @Test fun resetClosesTheOpenSegment() {
        receive(token("Half a sent", true, "en"))
        transcriber.sessionDidReset(live)
        assertTrue(segments.last().isClosed)
        assertEquals(SpeechEvent.SessionReset, events.last())
    }

    @Test fun trimSilenceKeepsSpeechWithPadding() {
        fun chunk(amplitude: Int) = ByteArray(2560) { i -> if (i % 2 == 0) (amplitude and 0xFF).toByte() else (amplitude shr 8).toByte() }
        val chunks = List(10) { chunk(0) } + List(5) { chunk(8000) } + List(30) { chunk(0) } + List(5) { chunk(8000) } + List(10) { chunk(0) }
        val kept = ResilientSocket.trimSilence(chunks)
        // 5 + 5 speech, 3 padding each side of both runs, and the 30-chunk pause cut to 10.
        assertEquals(3 + 5 + 10 + 5 + 3, kept.size)
        assertTrue(ResilientSocket.trimSilence(List(20) { chunk(0) }).isEmpty())
    }
}
