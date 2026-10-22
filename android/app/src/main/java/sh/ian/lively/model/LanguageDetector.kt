package sh.ian.lively.model

/**
 * Guesses which of the pair a transcript is in, for engines that don't say.
 *
 * Pairs in different scripts are told apart by counting characters, which is
 * instant and handles mixed speech ("我们去 Starbucks" counts as Chinese
 * because the Han characters carry most of the meaning). Pairs in the same
 * script go to [fallback], which the app points at Android's on-device
 * `TextClassifier`, limited to the two.
 */
object LanguageDetector {
    /** Picks one of the pair for same-script text, or null. Set by the app. */
    var fallback: (String, LanguagePair) -> Language? = { _, _ -> null }

    private enum class Script { HAN, KANA, HANGUL, LATIN, CYRILLIC, GREEK, ARABIC, HEBREW, DEVANAGARI, BENGALI, GURMUKHI, GUJARATI, TAMIL, TELUGU, KANNADA, MALAYALAM, THAI }

    private fun script(language: Language): Script = when (language.code) {
        "zh" -> Script.HAN
        "ja" -> Script.KANA
        "ko" -> Script.HANGUL
        "ru", "uk", "be", "bg", "mk", "sr", "kk" -> Script.CYRILLIC
        "el" -> Script.GREEK
        "ar", "fa", "ur" -> Script.ARABIC
        "he" -> Script.HEBREW
        "hi", "mr" -> Script.DEVANAGARI
        "bn" -> Script.BENGALI
        "pa" -> Script.GURMUKHI
        "gu" -> Script.GUJARATI
        "ta" -> Script.TAMIL
        "te" -> Script.TELUGU
        "kn" -> Script.KANNADA
        "ml" -> Script.MALAYALAM
        "th" -> Script.THAI
        else -> Script.LATIN
    }

    private fun scriptOf(codePoint: Int): Script? = when (codePoint) {
        in 0x41..0x5A, in 0x61..0x7A, in 0xC0..0x24F, in 0x1E00..0x1EFF -> Script.LATIN
        in 0x4E00..0x9FFF, in 0x3400..0x4DBF, in 0x20000..0x2A6DF, in 0xF900..0xFAFF -> Script.HAN
        in 0x3040..0x30FF -> Script.KANA
        in 0xAC00..0xD7AF, in 0x1100..0x11FF, in 0x3130..0x318F -> Script.HANGUL
        in 0x400..0x4FF -> Script.CYRILLIC
        in 0x370..0x3FF -> Script.GREEK
        in 0x600..0x6FF, in 0x750..0x77F, in 0xFB50..0xFDFF, in 0xFE70..0xFEFF -> Script.ARABIC
        in 0x590..0x5FF -> Script.HEBREW
        in 0x900..0x97F -> Script.DEVANAGARI
        in 0x980..0x9FF -> Script.BENGALI
        in 0xA00..0xA7F -> Script.GURMUKHI
        in 0xA80..0xAFF -> Script.GUJARATI
        in 0xB80..0xBFF -> Script.TAMIL
        in 0xC00..0xC7F -> Script.TELUGU
        in 0xC80..0xCFF -> Script.KANNADA
        in 0xD00..0xD7F -> Script.MALAYALAM
        in 0xE00..0xE7F -> Script.THAI
        else -> null
    }

    fun detect(text: String, languages: LanguagePair): Language? {
        val a = script(languages.first)
        val b = script(languages.second)
        if (a == b) return if (text.isBlank()) null else fallback(text, languages)

        var countA = 0.0
        var countB = 0.0
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            i += Character.charCount(cp)
            var s = scriptOf(cp) ?: continue
            // Japanese is written with kanji as well as kana.
            if (s == Script.HAN && (a == Script.KANA || b == Script.KANA) && a != Script.HAN && b != Script.HAN) s = Script.KANA
            // A Han character is roughly a syllable; a Latin-script word is ~4-5 letters.
            val weight = if (s == Script.LATIN) 0.25 else 1.0
            when (s) {
                a -> countA += weight
                b -> countB += weight
                else -> {}
            }
        }
        if (countA == 0.0 && countB == 0.0) return null
        // Ties go to the non-Latin language, as on iOS for Chinese.
        return when {
            countA > countB -> languages.first
            countB > countA -> languages.second
            a == Script.LATIN -> languages.second
            else -> languages.first
        }
    }
}
