package sh.ian.lively.support

import android.content.Context
import android.net.Uri
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizerOptionsInterface
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.net.await

/**
 * Reads the text in a photo on the device, so signs, menus and documents
 * can be translated like typed lines. Uses ML Kit's text recognition;
 * Vision on iOS.
 */
object TextRecognizer {
    /** The photo's text, one line per line of text found, or "" when there's none. */
    suspend fun text(context: Context, image: Uri, languages: LanguagePair): String {
        // Decoding reads EXIF, so camera photos come out the right way up.
        val input = withContext(Dispatchers.IO) { InputImage.fromFilePath(context, image) }
        return models(languages).map { read(input, it) }.maxBy { it.length }
    }

    /**
     * ML Kit has a model per script, where Vision takes a list of
     * languages. Each one for another script also reads Latin letters, so
     * the Latin model is only needed when neither language has its own.
     * A pair of two such languages, like Chinese and Korean, reads with both
     * and keeps whichever found more.
     */
    private fun models(languages: LanguagePair): List<TextRecognizerOptionsInterface> =
        languages.all.mapNotNull(::model).distinctBy { it.javaClass }.ifEmpty { listOf(TextRecognizerOptions.DEFAULT_OPTIONS) }

    private fun model(language: Language): TextRecognizerOptionsInterface? = when (language.code) {
        "zh" -> ChineseTextRecognizerOptions.Builder().build()
        "ja" -> JapaneseTextRecognizerOptions.Builder().build()
        "ko" -> KoreanTextRecognizerOptions.Builder().build()
        "hi", "mr", "ne" -> DevanagariTextRecognizerOptions.Builder().build()
        else -> null
    }

    private suspend fun read(input: InputImage, options: TextRecognizerOptionsInterface): String =
        TextRecognition.getClient(options).use { recognizer ->
            recognizer.process(input).await().textBlocks
                .flatMap { it.lines }
                .map { it.text.trim() }
                .filter { it.isNotEmpty() }
                .joinToString("\n")
        }
}
