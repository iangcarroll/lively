package sh.ian.lively

import android.hardware.SensorManager
import java.lang.ref.WeakReference
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.ian.lively.model.ListeningPromptMotion
import sh.ian.lively.ui.ListeningPromptMotionSource
import sh.ian.lively.ui.ListeningPromptVisibility
import sh.ian.lively.ui.listeningPromptIsActive
import sh.ian.lively.ui.listeningPromptMotion
import sh.ian.lively.ui.showsListeningPrompt

/**
 * The visibility owner with a virtual clock and timer and a stand-in for the
 * sensors, as in Tools/tests/ListeningPromptLifecycleRegression.swift.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ListeningPromptVisibilityTest {
    private class FakeMotionSource(override val isAvailable: Boolean = true) : ListeningPromptMotionSource {
        /** Every callback handed over, so one from an earlier session can still fire. */
        val callbacks = mutableListOf<(ListeningPromptMotion, Double) -> Unit>()
        var stops = 0
        var isRunning = false

        override fun start(onMotion: (ListeningPromptMotion, Double) -> Unit) {
            callbacks += onMotion
            isRunning = true
        }

        override fun stop() {
            stops += 1
            isRunning = false
        }
    }

    private val TestScope.now: Double get() = testScheduler.currentTime / 1000.0

    private fun TestScope.visibility(source: FakeMotionSource) =
        ListeningPromptVisibility(backgroundScope, source) { now }

    private fun TestScope.wait(seconds: Double) {
        advanceTimeBy((seconds * 1000).toLong())
        runCurrent()
    }

    /** A yaw of [degrees], through the same conversion the sensors use. */
    private fun sample(
        degrees: Double = 0.0,
        rotationRate: FloatArray = FloatArray(3),
        linearAcceleration: FloatArray = FloatArray(3),
    ): ListeningPromptMotion {
        val half = degrees * PI / 360
        return listeningPromptMotion(floatArrayOf(0f, 0f, sin(half).toFloat(), cos(half).toFloat()), rotationRate, linearAcceleration)
    }

    @Test fun fadesAfterFiveSecondsWithoutMotionSensors() = runTest {
        val source = FakeMotionSource(isAvailable = false)
        val owner = visibility(source)
        assertTrue("stopped guidance is visible", owner.isVisible)
        owner.setActive(true)
        assertTrue(owner.isVisible)
        assertTrue("unavailable sensors are not started", source.callbacks.isEmpty())
        wait(4.999)
        assertTrue("readable for the full five seconds", owner.isVisible)
        wait(0.001)
        assertFalse(owner.isVisible)
        owner.setActive(false)
        assertTrue("stopping restores persistent guidance", owner.isVisible)
    }

    @Test fun anUnchangedStateStartsNothingNew() = runTest {
        val source = FakeMotionSource()
        val owner = visibility(source)
        owner.setActive(true)
        wait(3.0)
        owner.setActive(true)
        assertEquals("one sensor stream", 1, source.callbacks.size)
        wait(2.0)
        assertFalse("the timer was not restarted", owner.isVisible)
    }

    @Test fun reactivationShowsAFreshCueAndStopsTheSensorsBetween() = runTest {
        val source = FakeMotionSource()
        val owner = visibility(source)
        owner.setActive(true)
        assertTrue(source.isRunning)
        wait(5.0)
        assertFalse(owner.isVisible)
        val stops = source.stops
        owner.setActive(false)
        assertEquals(stops + 1, source.stops)
        assertFalse(source.isRunning)
        assertTrue(owner.isVisible)
        wait(1.0)
        owner.setActive(true)
        assertTrue(source.isRunning)
        assertTrue(owner.isVisible)
        wait(5.0)
        assertFalse("the resumed session fades independently", owner.isVisible)
    }

    @Test fun aHandoffBringsItBackAndJitterDoesNot() = runTest {
        val source = FakeMotionSource()
        val owner = visibility(source)
        owner.setActive(true)
        val motion = source.callbacks.last()
        motion(sample(), now)
        wait(5.0)
        assertFalse(owner.isVisible)
        repeat(20) { index ->
            wait(0.1)
            motion(sample(sin(index.toDouble()) * 4, floatArrayOf(0.1f, 0.1f, 0f), floatArrayOf(0.3f, 0f, 0.2f)), now)
            assertFalse("jitter sample $index", owner.isVisible)
        }
        motion(sample(180.0), now)
        assertTrue("a portrait yaw handoff reveals the cue", owner.isVisible)
        wait(4.999)
        assertTrue(owner.isVisible)
        wait(0.001)
        assertFalse("the handoff's cue fades too", owner.isVisible)
    }

    @Test fun staleSamplesCannotRevealIt() = runTest {
        val source = FakeMotionSource()
        val owner = visibility(source)
        owner.setActive(true)
        val first = source.callbacks.last()
        first(sample(), now)
        owner.setActive(false)
        wait(1.0)
        owner.setActive(true)
        val second = source.callbacks.last()
        second(sample(), now)
        wait(5.0)
        assertFalse(owner.isVisible)
        first(sample(180.0), now)
        assertFalse("a previous session's callback", owner.isVisible)
        second(sample(180.0), now - 1)
        assertFalse("an old timestamp", owner.isVisible)
        second(sample(180.0), now + 1)
        assertFalse("a future timestamp", owner.isVisible)
        second(sample(180.0), now)
        assertTrue(owner.isVisible)
        owner.setActive(false)
        first(sample(linearAcceleration = floatArrayOf(0f, 0f, 20f)), now)
        second(sample(linearAcceleration = floatArrayOf(0f, 0f, 20f)), now)
        wait(10.0)
        assertTrue("callbacks after stopping leave stopped guidance alone", owner.isVisible)
    }

    @Test fun anEarlierSessionsDeadlineCannotHideANewCue() = runTest {
        val owner = visibility(FakeMotionSource())
        owner.setActive(true)
        owner.setActive(false)
        wait(2.0)
        owner.setActive(true)
        wait(3.0)
        assertTrue("the first session would have faded now", owner.isVisible)
        wait(2.0)
        assertFalse(owner.isVisible)
    }

    @Test fun aHandoffBeforeTheCueFadesExtendsIt() = runTest {
        val source = FakeMotionSource()
        val owner = visibility(source)
        owner.setActive(true)
        val motion = source.callbacks.last()
        motion(sample(), now)
        wait(3.0)
        motion(sample(180.0), now)
        wait(2.0)
        assertTrue("the original deadline cannot hide a refreshed cue", owner.isVisible)
        wait(2.999)
        assertTrue(owner.isVisible)
        wait(0.001)
        assertFalse(owner.isVisible)
    }

    @Test fun sensorVectorsRevealItOnEveryAxis() = runTest {
        for (axis in 0..2) {
            for (isAcceleration in listOf(false, true)) {
                val source = FakeMotionSource()
                val owner = visibility(source)
                owner.setActive(true)
                val motion = source.callbacks.last()
                motion(sample(), now)
                wait(5.0)
                assertFalse(owner.isVisible)
                // 3.2 rad/s, or 0.8 g in the sensor's metres per second squared.
                val vector = FloatArray(3).also { it[axis] = if (isAcceleration) 0.8f * SensorManager.GRAVITY_EARTH else 3.2f }
                motion(if (isAcceleration) sample(linearAcceleration = vector) else sample(rotationRate = vector), now)
                assertTrue("${if (isAcceleration) "acceleration" else "rotation"} axis $axis", owner.isVisible)
                owner.setActive(false)
            }
        }
    }

    @Test fun aRotationVectorWithoutItsScalarPartStillConverts() {
        val quarterTurn = listeningPromptMotion(floatArrayOf(0f, 0f, sin(PI / 4).toFloat()), FloatArray(3), FloatArray(3))
        assertEquals(cos(PI / 4), quarterTurn.attitude.w, 1e-6)
        val moving = listeningPromptMotion(floatArrayOf(0f, 0f, 0f, 1f), floatArrayOf(3f, 4f, 0f), floatArrayOf(0f, 0f, SensorManager.GRAVITY_EARTH))
        assertEquals(5.0, moving.rotationRate, 1e-6)
        assertEquals(1.0, moving.userAcceleration, 1e-6)
    }

    @Test fun onlyAResumedLiveUncoveredScreenSensesMotion() = runTest {
        val source = FakeMotionSource()
        val owner = visibility(source)

        /** What the screen does with its state; returns whether the guidance shows. */
        fun screen(isResumed: Boolean = true, isLive: Boolean = true, isCovered: Boolean = false, screenReader: Boolean = false): Boolean {
            owner.setActive(listeningPromptIsActive(isResumed, isLive, isCovered, screenReader))
            return showsListeningPrompt(isLive, screenReader, owner.isVisible)
        }

        /** A live conversation whose cue has faded. */
        fun faded() {
            screen()
            wait(5.0)
            assertTrue(source.isRunning)
            assertFalse(screen())
        }

        assertTrue("going live starts with the guidance", screen())
        faded()
        assertTrue("TalkBack keeps the instructions readable", screen(screenReader = true))
        assertFalse("and needs no motion sensing", source.isRunning)
        faded()
        assertTrue("stopped, connecting or offline guidance stays", screen(isLive = false))
        assertFalse(source.isRunning)
        faded()
        assertTrue("the background restores an expired cue", screen(isResumed = false))
        assertFalse(source.isRunning)
        faded()
        assertTrue(screen(isCovered = true))
        assertFalse("a covering sheet stops handoff sensing", source.isRunning)
        assertTrue("returning to the conversation starts a fresh cue", screen())
        assertTrue(source.isRunning)
    }

    @Test fun aReleasedOwnerStopsItsSensors() = runTest {
        val source = FakeMotionSource()
        val reference = activeOwner(source)
        runCurrent()
        repeat(100) {
            if (reference.get() == null) return@repeat
            System.gc()
            Thread.sleep(10)
        }
        assertNull("the timer and the sensor callback cannot retain their owner", reference.get())
        val stops = source.stops
        source.callbacks.last()(sample(180.0), now)
        assertEquals(stops + 1, source.stops)
        assertFalse(source.isRunning)
    }

    /** In its own frame, so no local variable keeps the owner alive. */
    private fun TestScope.activeOwner(source: FakeMotionSource): WeakReference<ListeningPromptVisibility> {
        val owner = visibility(source)
        owner.setActive(true)
        return WeakReference(owner)
    }
}
