package sh.ian.lively.net

import com.google.android.gms.tasks.Task
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.suspendCancellableCoroutine
import sh.ian.lively.model.ChineseScript
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.model.Utterance
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Translates on device with ML Kit, for typed text when no translation API
 * key is set. Models download on first use; the text input bar starts that
 * download when it opens.
 */
class OnDeviceTranslator : TranslationService {
    private val translators = mutableMapOf<Pair<String, String>, Translator>()

    override fun translate(
        text: String,
        from: Language,
        to: Language,
        context: List<Utterance>,
        script: ChineseScript,
    ): Flow<String> = flow {
        val translator = translator(from, to) ?: throw OnDeviceTranslationException(to)
        val output = try {
            translator.downloadModelIfNeeded().await()
            translator.translate(text).await()
        } catch (e: Exception) {
            throw OnDeviceTranslationException(to)
        }
        // ML Kit only writes Simplified Chinese.
        emit(if (to == Language.CHINESE) script.convert(output) else output)
    }

    /** Downloads both languages' models so typed text can translate offline. */
    suspend fun prepare(pair: LanguagePair) {
        translator(pair.first, pair.second)?.downloadModelIfNeeded()?.await()
    }

    private fun translator(from: Language, to: Language): Translator? {
        val source = TranslateLanguage.fromLanguageTag(from.code) ?: return null
        val target = TranslateLanguage.fromLanguageTag(to.code) ?: return null
        return translators.getOrPut(source to target) {
            Translation.getClient(TranslatorOptions.Builder().setSourceLanguage(source).setTargetLanguage(target).build())
        }
    }
}

class OnDeviceTranslationException(language: Language) : Exception("${language.englishName} isn't available on this device")

private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
    addOnSuccessListener { continuation.resume(it) }
    addOnFailureListener { continuation.resumeWithException(it) }
    addOnCanceledListener { continuation.cancel() }
}
