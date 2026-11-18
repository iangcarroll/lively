package sh.ian.lively.model

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.hypot
import kotlin.math.min

/** Relative orientation, independent of the phone's portrait/landscape layout. */
class ListeningPromptAttitude(val w: Double, val x: Double, val y: Double, val z: Double) {
    internal val normalized: ListeningPromptAttitude?
        get() {
            val length = hypot(hypot(w, x), hypot(y, z))
            if (!length.isFinite() || length <= 0) return null
            return ListeningPromptAttitude(w / length, x / length, y / length, z / length)
        }

    internal fun angle(other: ListeningPromptAttitude): Double {
        // q and -q describe the same attitude. The absolute dot product also
        // avoids a spurious full turn when the sensor changes quaternion sign.
        val dot = abs(w * other.w + x * other.x + y * other.y + z * other.z)
        return 2 * acos(min(1.0, dot))
    }
}

class ListeningPromptMotion(
    val attitude: ListeningPromptAttitude,
    /** Magnitude in radians per second. */
    val rotationRate: Double,
    /** Magnitude in g, excluding gravity. */
    val userAcceleration: Double,
)

/**
 * A short reminder after listening starts or the phone is handed to someone.
 * Uses monotonic time, in seconds, so clock changes cannot extend or suppress
 * the reminder.
 */
class ListeningPromptPolicy {
    var isActive = false
        private set
    var visibleUntil: Double? = null
        private set
    private var reference: ListeningPromptAttitude? = null
    private var lastReveal: Double? = null
    private var lastSampleTime: Double? = null
    private var settledSince: Double? = null
    private var needsSettling = false

    fun setActive(active: Boolean, time: Double) {
        if (!time.isFinite() || active == isActive) return
        isActive = active
        visibleUntil = if (active) time + DISPLAY_DURATION else null
        lastReveal = time.takeIf { active }
        lastSampleTime = time.takeIf { active }
        reference = null
        settledSince = null
        needsSettling = false
    }

    fun isVisible(time: Double): Boolean {
        val visibleUntil = visibleUntil
        if (!isActive || visibleUntil == null) return true
        return time < visibleUntil
    }

    /** Returns true only when a fresh movement reveals or extends the reminder. */
    fun receive(motion: ListeningPromptMotion, time: Double): Boolean {
        if (!isActive || !time.isFinite() ||
            !motion.rotationRate.isFinite() || motion.rotationRate < 0 ||
            !motion.userAcceleration.isFinite() || motion.userAcceleration < 0
        ) return false
        val attitude = motion.attitude.normalized ?: return false
        if (lastSampleTime?.let { time < it } == true) return false
        lastSampleTime = time
        val reference = reference
        if (reference == null) {
            this.reference = attitude
            return false
        }

        val coolingDown = lastReveal?.let { time - it < COOLDOWN_DURATION } ?: false
        if (coolingDown || needsSettling) {
            // Follow the phone while it is moving, then start measuring from its
            // new resting position. Holding it turned must not retrigger forever.
            this.reference = attitude
            if (motion.rotationRate < QUIET_ROTATION_THRESHOLD &&
                motion.userAcceleration < QUIET_ACCELERATION_THRESHOLD
            ) {
                val settledSince = settledSince ?: time.also { settledSince = it }
                if (!coolingDown && time - settledSince >= SETTLING_DURATION) needsSettling = false
            } else {
                settledSince = null
            }
            return false
        }

        if (reference.angle(attitude) < ROTATION_THRESHOLD &&
            motion.rotationRate < RAPID_ROTATION_THRESHOLD &&
            motion.userAcceleration < ACCELERATION_THRESHOLD
        ) return false
        this.reference = attitude
        lastReveal = time
        visibleUntil = time + DISPLAY_DURATION
        settledSince = null
        needsSettling = true
        return true
    }

    companion object {
        const val DISPLAY_DURATION = 5.0
        const val COOLDOWN_DURATION = 2.0
        const val SETTLING_DURATION = 0.6
        const val ROTATION_THRESHOLD = PI / 3
        const val RAPID_ROTATION_THRESHOLD = 2.5
        const val ACCELERATION_THRESHOLD = 0.55
        const val QUIET_ROTATION_THRESHOLD = 0.7
        const val QUIET_ACCELERATION_THRESHOLD = 0.18
    }
}
