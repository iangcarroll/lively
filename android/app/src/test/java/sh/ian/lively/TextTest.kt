package sh.ian.lively

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import sh.ian.lively.model.Filler
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguageDetector
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.model.LanguageSide
import sh.ian.lively.model.Phrases
import sh.ian.lively.model.with

class FillerTest {
    private fun en(text: String) = Filler.strip(text, Language.ENGLISH)
    private fun zh(text: String) = Filler.strip(text, Language.CHINESE)

    @Test fun stripsLeadingEnglishFillerAndRecapitalizes() = assertEquals("So we go left.", en("Um, so we go left."))

    @Test fun stripsFillerInTheMiddle() = assertEquals("I think the station is close.", en("I think, uh, the station is close."))

    @Test fun keepsWordsThatContainFillers() = assertEquals("Umbrella and hummus", en("Umbrella and hummus"))

    @Test fun onlyFillerBecomesEmpty() = assertEquals("", en("Hmm... uh"))

    @Test fun stripsChineseFillerAtStart() = assertEquals("我们去车站吧。", zh("呃，我们去车站吧。"))

    @Test fun keepsChineseParticles() = assertEquals("好啊，走吧。", zh("好啊，走吧。"))

    @Test fun sentenceFinalChineseFiller() = assertEquals("好的。", zh("好的，嗯。"))

    @Test fun mixedLanguages() = assertEquals("我们去 Starbucks", zh("um 我们去 Starbucks"))

    @Test fun otherLanguagesPassThrough() = assertEquals("um er", Filler.strip("um er", Language("es")))
}

class LanguageDetectorTest {
    private val enZh = LanguagePair.DEFAULT

    @Test fun english() = assertEquals(Language.ENGLISH, LanguageDetector.detect("Where is the bus stop?", enZh))

    @Test fun chinese() = assertEquals(Language.CHINESE, LanguageDetector.detect("公交车站在哪里？", enZh))

    @Test fun mixedSpeechCountsHanAsSyllables() =
        assertEquals(Language.CHINESE, LanguageDetector.detect("我们去 Starbucks", enZh))

    @Test fun punctuationOnlyIsUnknown() = assertNull(LanguageDetector.detect("…?!", enZh))

    @Test fun japaneseKanjiCountsAsJapanese() =
        assertEquals(Language("ja"), LanguageDetector.detect("駅はどこですか", LanguagePair(Language.ENGLISH, Language("ja"))))

    @Test fun cyrillicAgainstLatin() =
        assertEquals(Language("ru"), LanguageDetector.detect("Где автобус?", LanguagePair(Language("ru"), Language("es"))))

    @Test fun sameScriptUsesFallback() {
        val pair = LanguagePair(Language.ENGLISH, Language("es"))
        val saved = LanguageDetector.fallback
        LanguageDetector.fallback = { _, p -> p.second }
        try {
            assertEquals(Language("es"), LanguageDetector.detect("¿Dónde está?", pair))
        } finally {
            LanguageDetector.fallback = saved
        }
    }
}

class LanguagePairTest {
    @Test fun choosingTheOtherSideSwaps() {
        val pair = LanguagePair.DEFAULT.with(Language.CHINESE, LanguageSide.FIRST)
        assertEquals(LanguagePair(Language.CHINESE, Language.ENGLISH), pair)
    }

    @Test fun choosingANewLanguageReplacesOneSide() {
        val pair = LanguagePair.DEFAULT.with(Language("ja"), LanguageSide.SECOND)
        assertEquals(LanguagePair(Language.ENGLISH, Language("ja")), pair)
    }

    @Test fun everySonioxLanguageHasPhrases() {
        for (language in Language.SONIOX) assert(Phrases.ALL.containsKey(language.code)) { "missing phrases for $language" }
    }

    @Test fun namesComeFromTheLocale() {
        assertEquals("Spanish", Language("es").englishName)
        assertEquals("Español", Language("es").nativeName)
        assertEquals("中文", Language.CHINESE.tag)
        assertEquals("FR", Language("fr").tag)
    }
}
