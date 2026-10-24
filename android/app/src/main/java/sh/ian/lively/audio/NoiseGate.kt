package sh.ian.lively.audio

import kotlin.math.max
import kotlin.math.min

/**
 * How far away Lively listens. Sound quieter than the range's threshold is
 * sent as silence, so a conversation across the room isn't translated.
 */
enum class PickupRange(val id: String, val label: String, val summary: String) {
    AUTO("auto", "Auto", "Follows how loud the room is, and only hears people noticeably louder than the background."),
    CLOSE("close", "Close", "Only the people right by the phone. For loud places like restaurants and stations."),
    NEARBY("nearby", "Nearby", "People around the table. Conversations across the room are ignored."),
    ROOM("room", "Whole room", "Everything the mic can hear, even far away.");

    companion object {
        val DEFAULT = NEARBY
        fun from(id: String?) = entries.firstOrNull { it.id == id } ?: DEFAULT
    }
}

/**
 * Decides, chunk by chunk, whether the mic is hearing someone close enough
 * to translate. Sound gets about 6 dB quieter each time the distance
 * doubles, so a level threshold separates the person across the table from
 * a conversation 25 feet away.
 *
 * Shared with iOS (`Audio/NoiseGate.swift`); keep the numbers in step.
 */
class NoiseGate {
    var isOpen = true
        private set
    /**
     * The room's background level, in dBFS. Tracked in every range, so Auto
     * is ready the moment it's chosen.
     */
    var noiseFloor = -60f
        private set
    private var hold = 0

    /** The level speech must reach to open the gate, or null to hear everything. */
    fun threshold(range: PickupRange): Float? = when (range) {
        PickupRange.ROOM -> null
        PickupRange.NEARBY -> NEARBY_THRESHOLD
        PickupRange.CLOSE -> CLOSE_THRESHOLD
        PickupRange.AUTO -> min(max(noiseFloor + AUTO_MARGIN, NEARBY_THRESHOLD), AUTO_CEILING)
    }

    /** Takes one chunk's level and returns whether to send it as heard. */
    fun process(decibels: Float, range: PickupRange): Boolean {
        // Falls quickly into quiet gaps, rises slowly, and never above what's heard.
        noiseFloor = if (decibels < noiseFloor) {
            noiseFloor + (decibels - noiseFloor) * 0.25f
        } else {
            min(noiseFloor + FLOOR_RISE, decibels)
        }
        noiseFloor = max(noiseFloor, -90f)

        val threshold = threshold(range)
        if (threshold == null) {
            isOpen = true
            hold = 0
            return true
        }
        if (decibels >= threshold || (isOpen && decibels >= threshold - HYSTERESIS)) {
            isOpen = true
            hold = HOLD_CHUNKS
        } else {
            hold = max(0, hold - 1)
            isOpen = hold > 0
        }
        return isOpen
    }

    /** Closes the gate for a new session, keeping what it learned about the room. */
    fun reset() {
        isOpen = false
        hold = 0
    }

    companion object {
        /** Nearby's threshold, in dBFS of an 80 ms chunk. */
        const val NEARBY_THRESHOLD = -40f
        /** Close's threshold. */
        const val CLOSE_THRESHOLD = -32f
        /**
         * How far below the threshold sound can dip and keep an open gate open,
         * so it doesn't flicker mid-word.
         */
        const val HYSTERESIS = 6f
        /**
         * Chunks the gate stays open after the level drops (640 ms), so quiet
         * word endings and short pauses aren't cut.
         */
        const val HOLD_CHUNKS = 8
        /** In Auto, how much louder than the room's noise floor speech must be. */
        const val AUTO_MARGIN = 12f
        /** Auto's strictest threshold. Its laxest is Nearby's. */
        const val AUTO_CEILING = -28f
        /**
         * How fast the noise floor estimate rises, in dB per chunk (1.5 dB a
         * second), so speech doesn't count as background but a noisier room does.
         */
        const val FLOOR_RISE = 0.12f
    }
}
