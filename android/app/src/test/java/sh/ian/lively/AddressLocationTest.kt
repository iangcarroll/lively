package sh.ian.lively

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.ian.lively.model.AddressLanguage

/** The language preferences of `Tools/tests/AddressLookupRegression.swift`. */
class AddressLocationTest {
    private val codes = AddressLanguage.all.map { it.code }

    @Test fun languagesAreUniqueAndIndependentOfSpeechSettings() {
        assertEquals(codes.size, codes.toSet().size)
        assertTrue("ja" in codes && "en" in codes)
        // Far more than any speech engine offers.
        assertTrue(codes.size > 100)
        assertEquals(AddressLanguage.all.map { it.englishName }, AddressLanguage.all.map { it.englishName }.sortedWith(String.CASE_INSENSITIVE_ORDER))
    }

    @Test fun bothChineseScriptsHaveExplicitSelections() {
        assertTrue("zh-Hans" in codes && "zh-Hant" in codes)
        assertFalse("zh" in codes)
        assertNotEquals(AddressLanguage("zh-Hans").locale, AddressLanguage("zh-Hant").locale)
        assertEquals("Hans", AddressLanguage("zh-Hans").locale.script)
        assertEquals("Hant", AddressLanguage("zh-Hant").locale.script)
    }

    @Test fun savedCodesAreNormalized() {
        assertEquals(AddressLanguage("ja"), AddressLanguage.matching("ja_JP"))
        assertEquals(AddressLanguage("en"), AddressLanguage.matching("EN-us"))
        for (code in listOf("zh", "zh-CN", "zh_SG", "zh-Hans", "zh-Hans-HK", "zh-Hans-TW")) {
            assertEquals(code, "zh-Hans", AddressLanguage.matching(code).code)
        }
        for (code in listOf("zh-TW", "zh_HK", "zh-MO", "zh-Hant", "zh-Hant-CN")) {
            assertEquals(code, "zh-Hant", AddressLanguage.matching(code).code)
        }
    }

    @Test fun invalidSavedLanguageFallsBackToEnglish() {
        for (code in listOf("", "zz-ZZ", "not-a-language", "../invalid")) {
            assertEquals(code, AddressLanguage("en"), AddressLanguage.matching(code))
        }
    }

    @Test fun namesAreInEnglishAndTheLanguageItself() {
        assertEquals("Japanese", AddressLanguage("ja").englishName)
        assertEquals("日本語", AddressLanguage("ja").nativeName)
        assertEquals("Español", AddressLanguage("es").nativeName)
        assertEquals("Chinese (Traditional)", AddressLanguage("zh-Hant").englishName)
        assertEquals("繁體中文", AddressLanguage("zh-Hant").nativeName)
    }
}
