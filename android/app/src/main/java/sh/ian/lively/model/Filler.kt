package sh.ian.lively.model

/**
 * Strips hesitation sounds ("um", "uh", "呃", "嗯") from transcripts so they
 * don't get translated or take up space. A turn that is only filler ends up
 * empty and is dropped.
 */
object Filler {
    /** English fillers as whole words, with the commas or ellipsis around them. */
    private val english = Regex(
        """(?:,\s*)?(?<![\p{L}'])(?:u+m+|u+h+|e+r+m*|h+m+|m{2,})(?![\p{L}'])[,.…!?]*\s*""",
        RegexOption.IGNORE_CASE,
    )

    /**
     * Chinese fillers standing on their own: at the start or after
     * punctuation, and followed by punctuation or the end. "好啊" keeps its 啊.
     */
    private val chinese = Regex("""(^|[，。！？、；,.!?;\s])[嗯呃额唔]+(?:[，、,…\s]+|(?=[。！？.!?]|$))""")

    /** Punctuation left dangling at the start once a leading filler is gone. */
    private val leadingPunctuation = Regex("""^[\s，。、,.…!?！？]+""")

    /** Doubled spaces and spaces before punctuation, left where a filler was. */
    private val looseSpace = Regex("""(?<= ) +| +(?=[,.!?])""")

    /**
     * Only English and Chinese fillers are known. Other languages pass
     * through, since "er" or "um" can be real words in them.
     */
    fun strip(text: String, language: Language): String {
        if (language != Language.ENGLISH && language != Language.CHINESE) return text
        var result = text
        // Both, since English and Chinese mix: "um 我们去" or "呃, the station".
        result = english.replace(result, " ")
        result = chinese.replace(result, "$1")
        result = leadingPunctuation.replace(result, "")
        result = looseSpace.replace(result, "")
        result = result.trim()
        // A sentence-final "嗯。" can leave "好的，。" behind.
        result = result.replace("，。", "。").replace(", .", ".")
        // "Um, so we..." reads better as "So we...".
        val first = text.firstOrNull()
        if (first != null && first.isUpperCase() && result.firstOrNull()?.isLowerCase() == true) {
            result = result.substring(0, 1).uppercase() + result.substring(1)
        }
        return result
    }
}
