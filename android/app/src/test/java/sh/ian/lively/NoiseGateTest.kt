package sh.ian.lively

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.ian.lively.audio.MicCapture
import sh.ian.lively.audio.NoiseGate
import sh.ian.lively.audio.PickupRange

class NoiseGateTest {
    private fun gate() = NoiseGate().apply { reset() }

    @Test fun wholeRoomHearsEverything() {
        val gate = gate()
        assertTrue(gate.process(-80f, PickupRange.ROOM))
    }

    @Test fun nearbyIgnoresDistantSpeech() {
        val gate = gate()
        repeat(20) { assertFalse(gate.process(-48f, PickupRange.NEARBY)) }
        assertTrue(gate.process(-30f, PickupRange.NEARBY))
    }

    @Test fun closeIsStricterThanNearby() {
        val gate = gate()
        assertTrue(gate.process(-36f, PickupRange.NEARBY))
        assertFalse(gate().process(-36f, PickupRange.CLOSE))
    }

    @Test fun holdsOpenThroughShortPausesThenCloses() {
        val gate = gate()
        assertTrue(gate.process(-25f, PickupRange.NEARBY))
        repeat(NoiseGate.HOLD_CHUNKS - 1) { assertTrue(gate.process(-70f, PickupRange.NEARBY)) }
        assertFalse(gate.process(-70f, PickupRange.NEARBY))
    }

    @Test fun staysOpenWhenSpeechDipsJustBelowThreshold() {
        val gate = gate()
        gate.process(-30f, PickupRange.NEARBY)
        repeat(30) { assertTrue(gate.process(-44f, PickupRange.NEARBY)) }
    }

    @Test fun autoMatchesNearbyInAQuietRoom() {
        val gate = gate()
        repeat(100) { gate.process(-70f, PickupRange.AUTO) }
        assertEquals(NoiseGate.NEARBY_THRESHOLD, gate.threshold(PickupRange.AUTO)!!, 0.01f)
    }

    @Test fun autoRisesAboveALoudRoom() {
        val gate = gate()
        // A minute of restaurant chatter at -36 dBFS.
        repeat(750) { gate.process(-36f, PickupRange.AUTO) }
        assertEquals(-36f, gate.noiseFloor, 0.5f)
        assertEquals(NoiseGate.AUTO_CEILING, gate.threshold(PickupRange.AUTO)!!, 0.01f)
        assertFalse(gate.process(-36f, PickupRange.AUTO))
        assertTrue(gate.process(-20f, PickupRange.AUTO))
    }

    @Test fun speechDoesNotCountAsBackground() {
        val gate = gate()
        // Ten seconds of talking with quiet gaps between words.
        repeat(125) { gate.process(if (it % 4 == 3) -65f else -25f, PickupRange.AUTO) }
        assertTrue(gate.noiseFloor < -50f)
    }

    @Test fun measuresChunksInDecibels() {
        assertTrue(MicCapture.decibels(ByteArray(2560)) < -100f)
        val fullScale = ByteArray(2560) { if (it % 2 == 0) 0xFF.toByte() else 0x7F }
        assertEquals(0f, MicCapture.decibels(fullScale), 0.1f)
    }
}
