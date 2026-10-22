package sh.ian.lively

import android.content.Context
import android.content.Intent
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import sh.ian.lively.support.DebugFlags

/**
 * Drives the real app in demo mode, which needs no network or keys: the
 * scripted conversation runs through the real turn and translation logic.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class LivelyUiTest {
    @get:Rule val compose = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Before fun reset() {
        context.getSharedPreferences("lively", Context.MODE_PRIVATE).edit().clear().commit()
        DebugFlags.demo = false
        DebugFlags.demoAutoPlay = false
        DebugFlags.forceOnboarding = false
    }

    @After fun close() {
        scenario?.close()
    }

    private fun launch(vararg flags: String) {
        val intent = Intent(context, MainActivity::class.java)
        flags.forEach { intent.putExtra(it, true) }
        scenario = ActivityScenario.launch(intent)
    }

    private fun waitForText(text: String, timeout: Long = 15_000) =
        compose.waitUntilAtLeastOneExists(hasText(text, substring = true), timeout)

    @Test fun onboardingLeadsToTheConversation() {
        launch()
        waitForText("Get started")
        compose.onNodeWithText("Get started").performClick()
        waitForText("Lay it flat between you")
        compose.onNodeWithText("Continue").performClick()
        waitForText("Pick your languages")
        compose.onNodeWithContentDescription("Swap languages").performClick()
        compose.onNodeWithContentDescription("Swap languages").performClick()
        compose.onNodeWithText("Continue").performClick()
        waitForText("Sign in to Lively")
        compose.onNodeWithText("Not now").performClick()
        compose.waitUntilAtLeastOneExists(hasContentDescription("Start listening"), 10_000)
        compose.onNodeWithText("Tap the mic to start").assertExists()
    }

    @Test fun demoConversationIsTranslatedFaceToFace() {
        launch("LivelyDemo", "LivelyDemoAutoPlay")
        // The last line of the script, translated into Chinese for the far half.
        waitForText("太好了，非常感谢你的帮助。", timeout = 60_000)
        compose.onAllNodesWithText("Perfect, thank you so much for your help.", substring = true)[0].assertExists()
        compose.onNodeWithContentDescription("Stop listening").performClick()
        compose.waitUntilAtLeastOneExists(hasContentDescription("Start listening"), 5_000)
    }

    @Test fun transcriptViewAndClear() {
        launch("LivelyDemo", "LivelyDemoAutoPlay")
        waitForText("Hi! Is this the right place", timeout = 30_000)
        compose.onNodeWithContentDescription("More").performClick()
        compose.onNodeWithText("Transcript view").performClick()
        compose.waitUntilAtLeastOneExists(hasContentDescription("Clear conversation"), 5_000)
        compose.waitUntilAtLeastOneExists(hasContentDescription("Spoken in English"), 10_000)
        compose.onNodeWithContentDescription("Stop listening").performClick()
        compose.onNodeWithContentDescription("Clear conversation").performClick()
        waitForText("Tap the mic to start")
        compose.onNodeWithContentDescription("Face-to-face mode").performClick()
        compose.waitUntilAtLeastOneExists(hasContentDescription("Swap sides"), 5_000)
    }

    @Test fun settingsPickALanguage() {
        launch("LivelyDemo")
        compose.waitUntilAtLeastOneExists(hasContentDescription("More"), 10_000)
        compose.onNodeWithContentDescription("More").performClick()
        compose.onNodeWithText("Settings").performClick()
        waitForText("Second language")
        compose.onNodeWithText("Second language").performClick()
        waitForText("Search languages")
        compose.onNodeWithText("Search languages").performTextInput("japan")
        waitForText("日本語")
        compose.onNodeWithText("日本語").performClick()
        // Back in Settings; Chinese script goes away with Chinese.
        waitForText("First language")
        compose.onNodeWithText("Chinese script").assertDoesNotExist()
        compose.onNodeWithText("日本語").assertExists()
        // Swap by picking the other side's language.
        compose.onNodeWithText("First language").performClick()
        waitForText("Swap")
        compose.onNodeWithText("Swap").performClick()
        waitForText("First language")
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        val prefs = context.getSharedPreferences("lively", Context.MODE_PRIVATE)
        assert(prefs.getString("firstLanguage", null) == "ja") { "first language should now be Japanese" }
        assert(prefs.getString("secondLanguage", null) == "en")
        prefs.edit().remove("firstLanguage").remove("secondLanguage").commit()
    }

    @Test fun demoSignIn() {
        launch("LivelyDemo")
        compose.waitUntilAtLeastOneExists(hasContentDescription("More"), 10_000)
        compose.onNodeWithContentDescription("More").performClick()
        compose.onNodeWithText("Settings").performClick()
        waitForText("Sign in to Lively")
        compose.onNodeWithText("Sign in to Lively").performClick()
        compose.waitUntilAtLeastOneExists(hasContentDescription("Email"), 5_000)
        compose.onNodeWithContentDescription("Email").performTextInput("test@example.com")
        compose.onNodeWithText("Email me a code").performClick()
        waitForText("Enter the code we emailed to")
        compose.onNodeWithContentDescription("6-digit code").performTextInput("123456")
        waitForText("You're signed in")
        compose.onNodeWithText("Sign out").performClick()
        compose.onAllNodesWithText("Sign out")[1].performClick()
        waitForText("Sign in to Lively")
    }
}
