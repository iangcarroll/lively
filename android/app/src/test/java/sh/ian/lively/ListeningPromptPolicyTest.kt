package sh.ian.lively

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.ian.lively.model.ListeningPromptAttitude
import sh.ian.lively.model.ListeningPromptMotion
import sh.ian.lively.model.ListeningPromptPolicy

/** Synthetic monotonic time and motion, as in Tools/tests/ListeningPromptRegression.swift. */
class ListeningPromptPolicyTest {
    private fun attitude(degrees: Double, axis: Int = 2): ListeningPromptAttitude {
        val half = degrees * PI / 360
        val sine = sin(half)
        return ListeningPromptAttitude(cos(half), if (axis == 0) sine else 0.0, if (axis == 1) sine else 0.0, if (axis == 2) sine else 0.0)
    }

    private fun motion(degrees: Double = 0.0, axis: Int = 2, rate: Double = 0.0, acceleration: Double = 0.0) =
        ListeningPromptMotion(attitude(degrees, axis), rate, acceleration)

    /** Listening since 0, with a first sample as the baseline. */
    private fun listening(start: Double = 0.0) = ListeningPromptPolicy().apply {
        setActive(true, start)
        receive(motion(), start)
    }

    @Test fun staysUpForFiveSecondsThenFades() {
        val policy = ListeningPromptPolicy()
        assertTrue("stopped guidance remains visible", policy.isVisible(100.0))
        policy.setActive(true, 100.0)
        assertTrue(policy.isVisible(100.0))
        assertTrue(policy.isVisible(104.999))
        assertFalse(policy.isVisible(105.0))
        assertFalse("stays hidden without a handoff", policy.isVisible(1_000.0))
    }

    @Test fun onlyANewSessionShowsAFreshCue() {
        val policy = ListeningPromptPolicy()
        policy.setActive(true, 100.0)
        policy.setActive(true, 1_000.0)
        assertFalse("an unchanged active state cannot restart its timer", policy.isVisible(1_000.0))
        policy.setActive(false, 1_001.0)
        assertTrue("inactive guidance never expires", policy.isVisible(50_000.0))
        policy.setActive(true, 1_002.0)
        assertTrue(policy.isVisible(1_002.0))
        assertFalse(policy.isVisible(1_007.0))
    }

    @Test fun aTurnAroundAnyAxisRevealsIt() {
        for (axis in 0..2) {
            val policy = ListeningPromptPolicy()
            policy.setActive(true, 0.0)
            assertFalse("first attitude is a baseline", policy.receive(motion(0.0, axis), 0.0))
            assertFalse("small attitude change is ignored", policy.receive(motion(30.0, axis), 6.0))
            assertTrue("a half turn reveals guidance", policy.receive(motion(180.0, axis), 6.1))
            assertTrue(policy.isVisible(6.1))
            assertFalse(policy.isVisible(11.1))
        }
    }

    @Test fun aGradualTurnIsMeasuredFromItsBaseline() {
        val policy = listening()
        for ((index, degrees) in listOf(10.0, 20.0, 30.0, 40.0, 50.0).withIndex()) {
            assertFalse("$degrees° is below the threshold", policy.receive(motion(degrees), 6 + index * 0.1))
        }
        assertTrue(policy.receive(motion(70.0), 6.6))
    }

    @Test fun aQuaternionSignFlipIsNotAHandoff() {
        val policy = listening()
        val flipped = ListeningPromptMotion(ListeningPromptAttitude(-1.0, 0.0, 0.0, 0.0), 0.0, 0.0)
        assertFalse(policy.receive(flipped, 6.0))
        // A yaw turn can hand the phone to someone else while remaining portrait.
        assertTrue(policy.receive(motion(180.0), 6.1))
    }

    @Test fun handJitterDoesNotRevealIt() {
        val policy = listening()
        for (index in 1..400) {
            val time = index * 0.05
            assertFalse("sample $index", policy.receive(motion(sin(time * 7) * 4, rate = 0.15, acceleration = 0.04), time))
        }
        assertFalse("jitter cannot keep active instructions visible", policy.isVisible(20.0))
    }

    @Test fun abruptMovementRevealsItWithoutATurn() {
        val moved = listening()
        assertFalse("modest acceleration is ignored", moved.receive(motion(acceleration = 0.4), 6.0))
        assertTrue(moved.receive(motion(acceleration = 0.8), 6.1))

        val turned = listening()
        assertFalse("ordinary angular velocity is ignored", turned.receive(motion(3.0, rate = 1.0), 6.0))
        assertTrue("before a large angle accumulates", turned.receive(motion(5.0, rate = 3.0), 6.1))
    }

    @Test fun holdingTheTurnedPhoneDoesNotRenewIt() {
        val policy = listening()
        assertTrue(policy.receive(motion(180.0), 6.0))
        for (index in 1..160) {
            assertFalse("sample $index", policy.receive(motion(180.0), 6 + index * 0.05))
        }
        assertFalse(policy.isVisible(14.0))
        assertTrue("a separate return handoff reveals after settling", policy.receive(motion(), 14.1))
        assertTrue(policy.isVisible(14.1))
    }

    @Test fun ongoingMovementMustSettleBeforeItRevealsAgain() {
        val policy = listening()
        assertTrue(policy.receive(motion(acceleration = 1.0), 6.0))
        for (index in 1..80) {
            assertFalse("sample $index", policy.receive(motion(acceleration = 1.0), 6 + index * 0.1))
        }
        assertFalse(policy.isVisible(14.0))
        assertFalse("quiet begins a settling interval", policy.receive(motion(), 14.1))
        assertFalse("a short quiet pause is not a new handoff", policy.receive(motion(), 14.5))
        assertFalse("a too-short pause does not rearm a continuing movement", policy.receive(motion(acceleration = 0.9), 14.6))
        assertFalse(policy.receive(motion(), 14.8))
        assertFalse("a settled baseline does not reveal itself", policy.receive(motion(), 15.5))
        assertTrue(policy.receive(motion(acceleration = 0.9), 15.6))
    }

    @Test fun aQuickBounceDuringTheCooldownIsIgnored() {
        val policy = listening()
        assertTrue(policy.receive(motion(180.0), 6.0))
        policy.receive(motion(180.0), 6.1)
        policy.receive(motion(180.0), 6.8)
        assertFalse(policy.receive(motion(), 7.0))
        policy.receive(motion(), 7.1)
        policy.receive(motion(), 8.1)
        assertTrue("the cooldown eventually permits another handoff", policy.receive(motion(180.0), 8.2))
    }

    @Test fun motionAfterStoppingIsIgnoredAndResumingStartsAfresh() {
        val policy = listening()
        policy.setActive(false, 6.0)
        assertTrue("stopped guidance stays visible after the old deadline", policy.isVisible(100.0))
        assertFalse(policy.receive(motion(180.0, acceleration = 1.0), 7.0))
        assertFalse(policy.receive(motion(acceleration = 1.0), 7.1))
        policy.setActive(true, 8.0)
        assertFalse("resuming establishes a fresh baseline", policy.receive(motion(180.0), 8.0))
        assertFalse("stopped time cannot extend the next cue", policy.isVisible(13.0))
        assertTrue(policy.receive(motion(), 14.0))
    }

    @Test fun aDelayedFirstSampleCannotReuseAnEarlierBaseline() {
        val policy = listening()
        policy.setActive(false, 6.0)
        policy.setActive(true, 8.0)
        assertFalse(policy.receive(motion(180.0), 14.0))
        assertFalse(policy.isVisible(14.0))
    }

    @Test fun badTimestampsAreRejected() {
        val policy = listening(start = 10.0)
        assertFalse("out of order", policy.receive(motion(180.0, acceleration = 1.0), 9.0))
        assertFalse(policy.receive(motion(180.0, acceleration = 1.0), Double.NaN))
        assertFalse(policy.receive(motion(180.0, acceleration = 1.0), Double.POSITIVE_INFINITY))
        assertFalse(policy.isVisible(16.0))
        assertTrue("the baseline survives them", policy.receive(motion(180.0), 16.1))
    }

    @Test fun malformedMotionIsRejected() {
        val malformed = listOf(
            motion(rate = Double.NEGATIVE_INFINITY), motion(rate = Double.NaN), motion(rate = -1.0),
            motion(acceleration = Double.POSITIVE_INFINITY), motion(acceleration = Double.NaN), motion(acceleration = -1.0),
            ListeningPromptMotion(ListeningPromptAttitude(0.0, 0.0, 0.0, 0.0), 3.0, 1.0),
            ListeningPromptMotion(ListeningPromptAttitude(Double.NaN, 0.0, 0.0, 0.0), 3.0, 1.0),
        )
        for ((index, sample) in malformed.withIndex()) {
            val policy = listening()
            assertFalse("sample $index", policy.receive(sample, 6.0))
            assertFalse("sample $index", policy.isVisible(6.0))
            assertTrue("valid motion still works after sample $index", policy.receive(motion(180.0), 6.1))
        }
    }

    @Test fun theQuaternionIsNormalizedBeforeComparing() {
        val policy = listening()
        val halfTurn = ListeningPromptMotion(ListeningPromptAttitude(0.0, 0.0, 0.0, 2.0), 0.0, 0.0)
        assertTrue(policy.receive(halfTurn, 6.0))
    }
}
