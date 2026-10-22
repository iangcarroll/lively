package sh.ian.lively.model

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import sh.ian.lively.net.SpeechEvent
import sh.ian.lively.net.TranslationService
import kotlin.math.ceil
import kotlin.math.min
import kotlin.random.Random

/**
 * A scripted conversation for screenshots, previews and trying the UI
 * without an API key. Launch with the `LivelyDemo` extra.
 *
 * It feeds the same events Voxtral sends through the real pipeline, so turn
 * handling and translation behave as they do live.
 */
class DemoConversation(private val scope: CoroutineScope) {
    private var job: Job? = null

    fun play(handle: (SpeechEvent) -> Unit) {
        job?.cancel()
        job = scope.launch {
            for ((index, line) in SCRIPT.withIndex()) {
                if (index > 0) delay(900)
                handle(SpeechEvent.TurnStarted)
                for (piece in pieces(line.first)) {
                    delay(Random.nextLong(70, 141))
                    if (!isActive) return@launch
                    handle(SpeechEvent.Text(piece))
                }
                delay(250)
                handle(SpeechEvent.TurnEagerEnded)
                delay(300)
                handle(SpeechEvent.TurnEnded)
            }
        }
    }

    fun stop() {
        job?.cancel()
    }

    companion object {
        val SCRIPT = listOf(
            "Hi! Is this the right place for the bus to the airport?" to "你好！这里是去机场的公交车站吗？",
            "是的，就在这里。不过下一班车大概二十分钟以后才到。" to "Yes, it's right here. But the next bus won't come for about twenty minutes.",
            "Twenty minutes is fine. Do I pay on the bus or buy a ticket first?" to "二十分钟没问题。我是在车上付钱，还是要先买票？",
            "可以直接上车刷卡，也可以用微信或者支付宝扫码。" to "You can tap a card when you get on, or scan the code with WeChat or Alipay.",
            "Perfect, thank you so much for your help." to "太好了，非常感谢你的帮助。",
        )

        /**
         * Splits English into words and Chinese into 1-3 character chunks,
         * roughly how realtime transcription streams them.
         */
        fun pieces(text: String): List<String> {
            if (LanguageDetector.detect(text, LanguagePair.DEFAULT) == Language.ENGLISH) {
                return text.split(" ").mapIndexed { i, word -> if (i == 0) word else " $word" }
            }
            val result = mutableListOf<String>()
            var rest = text
            while (rest.isNotEmpty()) {
                val n = min(rest.length, Random.nextInt(1, 4))
                result += rest.take(n)
                rest = rest.drop(n)
            }
            return result
        }
    }
}

/** Returns canned translations from the demo script, streamed in pieces. */
class DemoTranslator : TranslationService {
    override fun translate(
        text: String,
        from: Language,
        to: Language,
        context: List<Utterance>,
        script: ChineseScript,
    ): Flow<String> {
        val full = DemoConversation.SCRIPT.firstOrNull { it.first.startsWith(text) }
        // Partial transcripts get a proportional slice of the final translation.
        val ratio = full?.let { text.length.toDouble() / it.first.length } ?: 1.0
        val target = full?.second ?: text
        val output = target.take(ceil(target.length * ratio).toInt())
        return flow {
            delay(180)
            var rest = output
            while (rest.isNotEmpty()) {
                emit(rest.take(4))
                rest = rest.drop(4)
                delay(25)
            }
        }
    }
}
