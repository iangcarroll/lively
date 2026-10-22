package sh.ian.lively.net

import kotlinx.coroutines.flow.Flow
import sh.ian.lively.model.ChineseScript
import sh.ian.lively.model.Language
import sh.ian.lively.model.Utterance

/**
 * A realtime speech-to-text service that `ConversationStore` can drive.
 * Everything is called, and calls back, on the main thread.
 *
 * Engines report either raw transcript deltas plus turn boundaries (and
 * leave translation to a [TranslationService]), or whole segments that
 * already carry their translation.
 */
interface SpeechEngine {
    var onEvent: (SpeechEvent) -> Unit
    var onStatus: (SpeechEngineStatus) -> Unit
    /** Set from the connectivity callback. Flipping it back on retries right away. */
    var networkAvailable: Boolean
    /**
     * How far transcript text lags behind turn events, in ms. The store waits
     * this long after a boundary so trailing words stay in their turn.
     */
    val textLagMs: Long get() = 0

    fun start()
    fun stop()
    /**
     * Stops taking audio but may keep the server session open for a while,
     * so [resume] doesn't have to reconnect. Call [stop] to let it go.
     */
    fun pause() = stop()
    /** Takes audio again after [pause]. */
    fun resume() = start()
    /** Queues one 16 kHz mono PCM16 chunk. Safe to call while disconnected. */
    fun send(chunk: ByteArray)
    /** The store ended the current turn on its own after a silence. */
    fun endTurn() {}
    /**
     * The device moved to a different network, such as from Wi-Fi to
     * cellular, while staying online.
     */
    fun networkPathChanged() {}
}

sealed interface SpeechEvent {
    /** More transcript text for the current turn. */
    data class Text(val delta: String) : SpeechEvent
    data object TurnStarted : SpeechEvent
    data object TurnEagerEnded : SpeechEvent
    data object TurnResumed : SpeechEvent
    data object TurnEnded : SpeechEvent
    /**
     * The latest state of a segment from an engine that translates by itself.
     * Segments may be revised until they're closed, and their translation can
     * keep arriving after that.
     */
    data class Segment(val segment: SpeechSegment) : SpeechEvent
    /** The server session was replaced; any open turn will not continue. */
    data object SessionReset : SpeechEvent
}

data class SpeechSegment(
    val id: Int,
    val source: String,
    val translation: String,
    val language: Language?,
    val isClosed: Boolean,
    /**
     * Speech held during a dropout and transcribed late, on its own session,
     * while live speech carried on.
     */
    val isCatchUp: Boolean = false,
)

sealed interface SpeechEngineStatus {
    data object Idle : SpeechEngineStatus
    data object Connecting : SpeechEngineStatus
    data object Live : SpeechEngineStatus
    data object Reconnecting : SpeechEngineStatus
    data class Failed(val message: String) : SpeechEngineStatus
}

interface TranslationService {
    /** Streams the translation of [text] token by token. */
    fun translate(
        text: String,
        from: Language,
        to: Language,
        context: List<Utterance>,
        script: ChineseScript,
    ): Flow<String>
}

class TranslationException(val code: Int) : Exception() {
    override val message: String
        get() = when (code) {
            401, 403 -> "API key rejected"
            429 -> "Rate limited"
            else -> "Server error $code"
        }

    /** Errors that won't fix themselves by retrying. */
    val isPermanent: Boolean get() = code == 400 || code == 401 || code == 403 || code == 404
}
