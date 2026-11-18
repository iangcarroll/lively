package sh.ian.lively

import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import sh.ian.lively.model.AddressLanguage
import sh.ian.lively.model.AddressLookupError
import sh.ian.lively.model.AddressLookupException
import sh.ian.lively.model.AddressLookupProviding
import sh.ian.lively.model.AddressLookupStore
import sh.ian.lively.model.AddressPlace
import sh.ian.lively.ui.AddressLookupContent
import sh.ian.lively.ui.LivelyTheme

/** The address screen over a scripted service, so it needs no network or Geocoder. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class AddressLookupUiTest {
    @get:Rule val compose = createComposeRule()

    private val station = AddressPlace("station", "Tokyo Station", "1 Chome Marunouchi, Chiyoda City, Tokyo, Japan", 35.681236, 139.767125, "JP")
    private val museum = AddressPlace("museum", "Tokyo National Museum", "13-9 Uenokoen, Taito City, Tokyo, Japan", 35.718835, 139.776527, "JP")

    private class ScriptedService(private val places: List<AddressPlace>, var offline: Boolean = false) : AddressLookupProviding {
        override suspend fun findPlaces(query: String): List<AddressPlace> {
            if (offline) throw AddressLookupException(AddressLookupError.NETWORK)
            return places
        }

        override suspend fun address(place: AddressPlace, language: AddressLanguage) = when (language.code) {
            "ja" -> "〒100-0005\n東京都千代田区丸の内1丁目9−1"
            "ar" -> "اليابان، طوكيو"
            else -> throw AddressLookupException(AddressLookupError.MISSING_ADDRESS)
        }

        override fun cancel() {}
    }

    private var saved: AddressLanguage? = null

    private fun show(service: AddressLookupProviding) {
        compose.setContent {
            val scope = rememberCoroutineScope()
            val store = remember { AddressLookupStore(service, AddressLanguage("ja"), scope) }
            LivelyTheme {
                AddressLookupContent(
                    store,
                    onLanguage = {
                        store.language = it
                        saved = it
                    },
                    onBack = {},
                )
            }
        }
    }

    private fun search(text: String) {
        compose.onNodeWithTag("address-query").performTextInput(text)
        compose.onNodeWithTag("address-find").assertIsEnabled().performClick()
    }

    @Test fun findingAPlaceShowsItsAddressInTheChosenLanguage() {
        show(ScriptedService(listOf(station, museum)))
        compose.onNodeWithTag("address-find").assertIsNotEnabled()
        search("Tokyo")
        compose.waitUntilAtLeastOneExists(hasText("Choose a place"))
        compose.onAllNodesWithTag("address-result").assertCountEquals(2)
        compose.onNodeWithText("Tokyo Station").performClick()
        compose.waitUntilAtLeastOneExists(hasTestTag("address-text"))
        compose.onNodeWithTag("address-text").assertTextEquals("〒100-0005\n東京都千代田区丸の内1丁目9−1")
        compose.onNodeWithText("Address in Japanese").assertExists()
        compose.onNodeWithText("Copy address").performScrollTo().performClick()
        compose.waitUntilAtLeastOneExists(hasText("Copied"))
    }

    @Test fun changingTheLanguageResolvesTheSamePlaceAgain() {
        show(ScriptedService(listOf(station)))
        search("Tokyo Station")
        compose.waitUntilAtLeastOneExists(hasText("Confirm the place"))
        compose.onNodeWithTag("address-result").performClick()
        compose.waitUntilAtLeastOneExists(hasTestTag("address-text"))
        compose.onNodeWithTag("address-language").performClick()
        compose.onNodeWithTag("address-language-search").performTextInput("Arabic")
        compose.onNodeWithTag("address-language-ar").performClick()
        compose.waitUntilAtLeastOneExists(hasText("Address in Arabic"))
        compose.onNodeWithTag("address-text").assertTextEquals("اليابان، طوكيو")
        assertEquals(AddressLanguage("ar"), saved)
    }

    @Test fun errorsOfferAnotherTry() {
        val service = ScriptedService(listOf(station), offline = true)
        show(service)
        search("Tokyo Station")
        compose.waitUntilAtLeastOneExists(hasTestTag("address-error"))
        compose.onNodeWithTag("address-error").assertTextEquals(AddressLookupError.NETWORK.message)
        service.offline = false
        compose.onNodeWithText("Try again").performClick()
        compose.waitUntilAtLeastOneExists(hasText("Confirm the place"))
        // No address in this language: back to the choices, with the reason.
        compose.onNodeWithTag("address-language").performClick()
        compose.onNodeWithTag("address-language-search").performTextInput("French")
        compose.onNodeWithTag("address-language-fr").performClick()
        compose.onNodeWithTag("address-result").performClick()
        compose.waitUntilAtLeastOneExists(hasTestTag("address-error"))
        compose.onNodeWithTag("address-error").assertTextEquals(AddressLookupError.MISSING_ADDRESS.message)
        compose.onAllNodesWithTag("address-text").assertCountEquals(0)
    }
}
