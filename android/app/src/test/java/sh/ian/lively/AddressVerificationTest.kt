package sh.ian.lively

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.ian.lively.model.AddressLanguage
import sh.ian.lively.net.AddressVerification
import sh.ian.lively.net.AddressVerification.geocodingLocale
import sh.ian.lively.net.AddressVerification.isWithinLocationTolerance
import sh.ian.lively.net.AddressVerification.numberParts
import sh.ian.lively.net.AddressVerification.supportsRequestedScript

/** The cases of `Tools/tests/AddressVerificationRegression.swift`, without any Geocoder requests. */
class AddressVerificationTest {
    private val ordinary = listOf("1", "10", "6")

    @Test fun namesDoNotSupplyAddressNumbers() {
        for (name in listOf("Roppongi", "六本木", "三軒茶屋", "二子玉川", "四谷", "日本橋", "Hotel Ⅳ", "Tower Ⅵ", "Café ²", "Shop ①")) {
            assertTrue(name, numberParts(name).isEmpty())
        }
        assertEquals(ordinary, numberParts("六本木6-10-1"))
        assertEquals(numberParts("Sangenjaya2-16-1"), numberParts("三軒茶屋2-16-1"))
        assertEquals(ordinary, numberParts("Tower Ⅵ, 6-10-1"))
    }

    @Test fun decimalDigitsOfAnyScriptAreNormalized() {
        assertEquals(ordinary, numberParts("6-10-1"))
        for (address in listOf("６丁目１０−１", "٦-١٠-١", "۶-۱۰-۱", "६-१०-१")) {
            assertEquals(address, ordinary, numberParts(address))
        }
    }

    @Test fun numbersSurviveReorderingButNotChange() {
        assertEquals(
            numberParts("9-1, Marunouchi 1-Chōme, Chiyoda, Tokyo 100-0005"),
            numberParts("〒100-0005 東京都千代田区丸の内1丁目9-1"),
        )
        assertEquals(listOf("0005", "100"), numberParts("〒100-0005"))
        assertNotEquals(numberParts("0005"), numberParts("5"))
        assertNotEquals(numberParts("21 Main St"), numberParts("12 Main St"))
        assertNotEquals(numberParts("12 Main St"), numberParts("1-2 Main St"))
        assertNotEquals(numberParts("6-10-2"), numberParts("6-10-1"))
        assertNotEquals(numberParts("1 Main St"), numberParts("1 Main St Apt 23"))
        assertNotEquals(numberParts("Tokyo 2-8-1"), numberParts("Tokyo"))
        assertNotEquals(numberParts("Main St 2"), numberParts("Main St 2 2"))
        assertEquals(numberParts("1 Apple Park Way, クパティーノ CA95014"), numberParts("1 Apple Park Way, Cupertino CA95014"))
    }

    private val formatted = "9-1, Marunouchi 1-Chōme\nChiyoda, Tokyo\nJapan 100-0005"
    private val original = "1-9-1 Marunouchi, Chiyoda, Tokyo, Japan"
    private val english = AddressLanguage("en")
    private val japanese = AddressLanguage("ja")

    private fun queries(address: String, query: String, language: AddressLanguage, countryName: String? = null) =
        AddressVerification.geocodingQueries(address, query, "JP", countryName, language)

    @Test fun theOriginalQueryStaysAvailable() {
        assertEquals(listOf(formatted, original), queries(formatted, original, english))
        assertEquals(listOf(original), queries(original, original, english))
        assertEquals(listOf("Tokyo\nJapan", "Tokyo Japan"), queries("Tokyo\nJapan", "Tokyo Japan", english))
        assertEquals(listOf(original), AddressVerification.geocodingQueries(original, original, null, null, japanese))
    }

    @Test fun onlyTheCountryComponentIsLocalized() {
        assertEquals(
            listOf(formatted.replace("Japan", "日本"), original.replace("Japan", "日本"), formatted, original),
            queries(formatted, original, japanese),
        )
        assertEquals("Japan Hotel, Tokyo, 日本", queries("Japan Hotel, Tokyo, Japan", "Japan Hotel, Tokyo, Japan", japanese).first())
        assertEquals(listOf("Japan Hotel, Tokyo"), queries("Japan Hotel, Tokyo", "Japan Hotel, Tokyo", japanese))
        // The name the Geocoder itself gave the country, in the device's language.
        assertEquals("東京都, Japan", queries("東京都, 日本", "東京都, 日本", english, countryName = "日本").first())
    }

    @Test fun geocoderUsesTheRequestedLanguageAndTheSelectedCountry() {
        assertEquals("ja-JP", geocodingLocale(japanese, "JP").toLanguageTag())
        assertEquals("en-JP", geocodingLocale(english, "JP").toLanguageTag())
        assertEquals("zh-Hant-TW", geocodingLocale(AddressLanguage("zh-Hant"), "TW").toLanguageTag())
        assertEquals("zh-Hant-HK", geocodingLocale(AddressLanguage("zh-Hant"), "HK").toLanguageTag())
        // The Geocoder takes the script from the region, so it can't be the place's.
        assertEquals("zh-Hant-TW", geocodingLocale(AddressLanguage("zh-Hant"), "JP").toLanguageTag())
        assertEquals("zh-Hans-CN", geocodingLocale(AddressLanguage("zh-Hans"), "TW").toLanguageTag())
        assertEquals("zh-Hans-CN", geocodingLocale(AddressLanguage("zh-Hans"), null).toLanguageTag())
        assertEquals("fr", geocodingLocale(AddressLanguage("fr"), null).toLanguageTag())
        assertEquals("fr", geocodingLocale(AddressLanguage("fr"), "not a country").toLanguageTag())
    }

    @Test fun fallbackTextIsNotPresentedAsTheRequestedScript() {
        assertTrue(supportsRequestedScript("東京都千代田区丸の内1丁目9-1", "Jpan"))
        assertTrue(supportsRequestedScript("1 Apple Park Way クパティーノ アメリカ合衆国", "Jpan"))
        assertFalse(supportsRequestedScript("9-1 Marunouchi Chiyoda Tokyo Japan 100-0005", "Jpan"))
        assertFalse(supportsRequestedScript("１２３４５", "Jpan"))
        assertTrue(supportsRequestedScript("北京市东城区", "Hans"))
        assertTrue(supportsRequestedScript("臺北市中正區", "Hant"))
        assertTrue(supportsRequestedScript("서울특별시", "Kore"))
        assertFalse(supportsRequestedScript("Seoul South Korea", "Kore"))
        assertTrue(supportsRequestedScript("القاهرة مصر", "Arab"))
        assertFalse(supportsRequestedScript("Cairo Egypt ١٢٣", "Arab"))
        assertTrue(supportsRequestedScript("Москва Россия", "Cyrl"))
        assertFalse(supportsRequestedScript("Moscow Russia", "Cyrl"))
        assertTrue(supportsRequestedScript("1 Apple Park Way", "Latn"))
        assertFalse(supportsRequestedScript("東京都千代田区丸の内1丁目9-1", "Latn"))
        assertFalse(supportsRequestedScript("１２３４５", "Latn"))
        // A language whose script isn't known can't be checked.
        assertTrue(supportsRequestedScript("anything", null))
    }

    @Test fun numberedAddressesNeedATightMatch() {
        val street = "9-1, Marunouchi 1-Chōme, Tokyo 100-0005"
        val area = "Marunouchi, Chiyoda, Tokyo, Japan"
        assertTrue(isWithinLocationTolerance(0.0, street))
        assertTrue(isWithinLocationTolerance(49.99, street))
        assertTrue(isWithinLocationTolerance(50.0, street))
        assertFalse(isWithinLocationTolerance(50.01, street))
        assertFalse(isWithinLocationTolerance(499.0, street))
        assertTrue(isWithinLocationTolerance(235.5, area))
        assertTrue(isWithinLocationTolerance(500.0, area))
        assertFalse(isWithinLocationTolerance(500.01, area))
        assertFalse(isWithinLocationTolerance(51.0, "〒100-0005 東京都千代田区丸の内1丁目9-1"))
        assertFalse(isWithinLocationTolerance(51.0, "６−１０−１"))
        assertFalse(isWithinLocationTolerance(51.0, "٦-١٠-١"))
        assertTrue(isWithinLocationTolerance(235.5, "六本木"))
        assertFalse(isWithinLocationTolerance(-1.0, street))
        assertFalse(isWithinLocationTolerance(Double.NaN, street))
        assertFalse(isWithinLocationTolerance(Double.POSITIVE_INFINITY, area))
    }
}
