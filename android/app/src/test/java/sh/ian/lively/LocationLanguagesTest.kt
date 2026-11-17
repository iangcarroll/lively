package sh.ian.lively

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.ian.lively.model.AppSettings
import sh.ian.lively.model.ChineseScript
import sh.ian.lively.model.Language
import sh.ian.lively.model.LanguagePair
import sh.ian.lively.model.LocationLanguages
import sh.ian.lively.model.RegionLocating
import sh.ian.lively.model.SpeechProvider
import sh.ian.lively.model.SpeechProviders
import sh.ian.lively.support.MemoryStore

class LocationLanguagesSuggestionTest {
    private fun suggest(region: String, own: String = "en", script: ChineseScript = ChineseScript.SIMPLIFIED, supported: List<Language> = Language.SONIOX) =
        LocationLanguages.suggestion(region, Language(own), script, supported)

    private fun pair(first: String, second: String) = LanguagePair(Language(first), Language(second))

    @Test fun englishAndTheLocalLanguage() = assertEquals(pair("en", "ja"), suggest("JP")?.languages)

    @Test fun systemLanguageReplacesEnglish() = assertEquals(pair("fr", "ja"), suggest("jp", own = "fr")?.languages)

    @Test fun unsupportedSystemLanguageFallsBackToEnglish() = assertEquals(pair("en", "de"), suggest("DE", own = "is")?.languages)

    @Test fun anEnglishSpeakingCountryForAnotherLanguage() = assertEquals(pair("de", "en"), suggest("US", own = "de")?.languages)

    @Test fun nothingWhereTheLocalLanguageIsYourOwn() {
        assertNull(suggest("US"))
        assertNull(suggest("FR", own = "fr"))
    }

    @Test fun nothingForACountryWithoutALanguage() = assertNull(suggest("IS"))

    @Test fun nothingWhenTheEngineLacksTheLanguage() = assertNull(suggest("TH", supported = Language.VOXTRAL))

    @Test fun chineseScriptFollowsTheCountry() {
        assertEquals(ChineseScript.SIMPLIFIED, suggest("CN")?.script)
        assertEquals(ChineseScript.TRADITIONAL, suggest("HK")?.script)
        assertEquals(ChineseScript.TRADITIONAL, suggest("TW")?.script)
        assertNull(suggest("JP")?.script)
    }

    @Test fun chineseScriptFollowsTheSystemAbroad() =
        assertEquals(LocationLanguages.Suggestion(pair("zh", "ja"), ChineseScript.TRADITIONAL), suggest("JP", own = "zh", script = ChineseScript.TRADITIONAL))

    @Test fun systemCodes() {
        assertEquals(Language("no"), LocationLanguages.languageForSystemCode("nb"))
        assertEquals(Language("tl"), LocationLanguages.languageForSystemCode("fil"))
        assertEquals(Language("he"), LocationLanguages.languageForSystemCode("iw"))
        assertEquals(Language("es"), LocationLanguages.languageForSystemCode("ES"))
    }

    @Test fun everyMappedLanguageIsOneSonioxHas() {
        for (region in java.util.Locale.getISOCountries()) {
            LocationLanguages.languageForRegion(region)?.let { assertTrue("$region → $it", it in Language.SONIOX) }
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class LocationLanguagesTest {
    private class FakeLocator(var region: String?, override var isAuthorized: Boolean = true) : RegionLocating {
        override suspend fun region() = region
    }

    private val memory = MemoryStore()
    private val provider = SpeechProvider(SpeechProviders.SONIOX_ID, "x", "", emptyList(), emptySet(), Language.SONIOX) { error("unused") }
    private val settings = AppSettings(memory, memory, listOf(provider))
    private val locator = FakeLocator("JP")
    private val english = { Language.ENGLISH to ChineseScript.SIMPLIFIED }

    @Test fun offUntilTurnedOn() = runTest {
        val location = LocationLanguages(settings, locator, backgroundScope, english)
        assertFalse(location.update())
        assertEquals(LanguagePair.DEFAULT, settings.languages)
    }

    @Test fun turningItOnSetsThePair() = runTest {
        val location = LocationLanguages(settings, locator, backgroundScope, english)
        location.enable(granted = true); runCurrent()
        assertEquals(LanguagePair(Language.ENGLISH, Language("ja")), settings.languages)
        assertEquals(LocationLanguages.Status.Applied("JP"), location.status)
        assertEquals("JP", settings.locationLanguageRegion)
    }

    @Test fun refusedAccessLeavesItOff() = runTest {
        val location = LocationLanguages(settings, locator, backgroundScope, english)
        location.enable(granted = false); runCurrent()
        assertFalse(settings.usesLocationLanguages)
        assertEquals(LocationLanguages.Status.Denied, location.status)
        assertEquals(LanguagePair.DEFAULT, settings.languages)
    }

    @Test fun aChoiceMadeByHandSticksUntilAnotherCountry() = runTest {
        val location = LocationLanguages(settings, locator, backgroundScope, english)
        location.enable(granted = true); runCurrent()
        settings.languages = LanguagePair(Language.ENGLISH, Language("ko"))
        assertFalse(location.update())
        assertEquals(Language("ko"), settings.languages.second)
        locator.region = "FR"
        assertTrue(location.update())
        assertEquals(LanguagePair(Language.ENGLISH, Language("fr")), settings.languages)
    }

    @Test fun waitsWhileAConversationIsUnderWay() = runTest {
        val location = LocationLanguages(settings, locator, backgroundScope, english)
        location.enable(granted = true); runCurrent()
        locator.region = "FR"
        assertFalse(location.update(canChange = false))
        assertEquals(Language("ja"), settings.languages.second)
        assertTrue(location.update())
        assertEquals(Language("fr"), settings.languages.second)
    }

    @Test fun hongKongSetsTraditional() = runTest {
        settings.languages = LanguagePair(Language.ENGLISH, Language("es"))
        val location = LocationLanguages(settings, FakeLocator("HK"), backgroundScope, english)
        location.enable(granted = true); runCurrent()
        assertEquals(LanguagePair.DEFAULT, settings.languages)
        assertEquals(ChineseScript.TRADITIONAL, settings.chineseScript)
    }

    @Test fun turnsOffWhenAccessIsTakenAway() = runTest {
        val location = LocationLanguages(settings, locator, backgroundScope, english)
        location.enable(granted = true); runCurrent()
        locator.isAuthorized = false
        locator.region = "FR"
        assertFalse(location.update())
        assertFalse(settings.usesLocationLanguages)
        assertEquals(Language("ja"), settings.languages.second)
    }

    @Test fun aFailedLookupChangesNothing() = runTest {
        val location = LocationLanguages(settings, FakeLocator(null), backgroundScope, english)
        location.enable(granted = true); runCurrent()
        assertEquals(LocationLanguages.Status.Failed, location.status)
        assertEquals(LanguagePair.DEFAULT, settings.languages)
        assertTrue(settings.usesLocationLanguages)
    }
}
