package sh.ian.lively.model

import java.util.Locale

/** A spoken language, by ISO 639-1 code. */
@JvmInline
value class Language(val code: String) {
    /** Short tag shown next to text in this language. */
    val tag: String get() = if (this == CHINESE) "中文" else code.uppercase(Locale.ROOT)

    val locale: Locale get() = if (this == CHINESE) Locale.forLanguageTag("zh-Hans") else Locale.forLanguageTag(code)

    /** Name of the language in English, e.g. "Spanish". */
    val englishName: String
        get() = locale.getDisplayLanguage(Locale.ENGLISH).ifEmpty { code }

    /** Name of the language written in that language, e.g. "Español". */
    val nativeName: String
        get() {
            val name = locale.getDisplayLanguage(locale)
            if (name.isEmpty() || name == code) return englishName
            return name.substring(0, 1).uppercase(locale) + name.substring(1)
        }

    /** "Spanish · Español", or just "English" when the names match. */
    val pickerName: String
        get() = if (englishName == nativeName) englishName else "$englishName · $nativeName"

    /** Written right to left, so a reader's half of the screen mirrors. */
    val isRightToLeft: Boolean get() = code in RTL

    val usesLatinScript: Boolean get() = code in LATIN_SCRIPT

    override fun toString() = code

    companion object {
        val ENGLISH = Language("en")
        val CHINESE = Language("zh")

        private val RTL = setOf("ar", "he", "fa", "ur")

        private val LATIN_SCRIPT = setOf(
            "af", "sq", "az", "eu", "bs", "ca", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "gl", "de",
            "hu", "id", "it", "lv", "lt", "ms", "no", "pl", "pt", "ro", "sk", "sl", "es", "sw", "sv", "tl",
            "tr", "vi", "cy",
        )

        /**
         * Every language Soniox transcribes; it translates between any two.
         * https://soniox.com/docs/stt/concepts/supported-languages
         */
        val SONIOX: List<Language> = listOf(
            "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca", "zh", "hr", "cs", "da", "nl", "en",
            "et", "fi", "fr", "gl", "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn", "kk", "ko",
            "lv", "lt", "mk", "ms", "ml", "mr", "no", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl",
            "es", "sw", "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi", "cy",
        ).map(::Language)

        /** The 13 languages Voxtral transcribes. */
        val VOXTRAL: List<Language> = listOf(
            "en", "zh", "hi", "es", "ar", "fr", "pt", "ru", "de", "ja", "ko", "it", "nl",
        ).map(::Language)
    }
}

/**
 * The two languages of a conversation. Lively listens for both and
 * translates each into the other.
 */
data class LanguagePair(
    /** Shown first: the leading side of the chat and the left column. */
    val first: Language,
    val second: Language,
) {
    val all: List<Language> get() = listOf(first, second)

    operator fun contains(language: Language) = language == first || language == second

    fun other(than: Language): Language = if (than == first) second else first

    /** The pair's member with this code, or null for a language outside the pair. */
    fun language(code: String?): Language? = all.firstOrNull { it.code == code }

    fun swapped() = LanguagePair(second, first)

    companion object {
        val DEFAULT = LanguagePair(Language.ENGLISH, Language.CHINESE)
    }
}

enum class LanguageSide { FIRST, SECOND }

operator fun LanguagePair.get(side: LanguageSide) = if (side == LanguageSide.FIRST) first else second

/** Sets one side of the pair. Choosing the other side's language swaps them. */
fun LanguagePair.with(language: Language, side: LanguageSide): LanguagePair {
    if (other(get(side)) == language) return swapped()
    return if (side == LanguageSide.FIRST) copy(first = language) else copy(second = language)
}

enum class ChineseScript(val id: String) {
    SIMPLIFIED("simplified"),
    TRADITIONAL("traditional");

    /** English first, for whoever is setting Lively up. */
    val label: String get() = if (this == SIMPLIFIED) "Simplified 简体" else "Traditional 繁體"
    val promptName: String get() = if (this == SIMPLIFIED) "Simplified Chinese" else "Traditional Chinese"

    /**
     * Rewrites Simplified Chinese in this script, for engines that only
     * output Simplified. Other text passes through unchanged.
     */
    fun convert(text: String): String {
        if (this != TRADITIONAL || text.isEmpty()) return text
        return ScriptConverter.toTraditional(text)
    }

    companion object {
        fun from(id: String?) = entries.firstOrNull { it.id == id } ?: SIMPLIFIED
    }
}

/** Simplified → Traditional, set by the app; plain JVM tests leave text alone. */
object ScriptConverter {
    var toTraditional: (String) -> String = { it }
}

/** Streaming delay for Voxtral Realtime. Lower is faster, higher is more accurate. */
enum class Latency(val milliseconds: Int, val label: String) {
    FASTEST(240, "Fastest"),
    BALANCED(480, "Balanced"),
    ACCURATE(960, "Accurate");

    companion object {
        fun from(ms: Int) = entries.firstOrNull { it.milliseconds == ms } ?: FASTEST
    }
}
