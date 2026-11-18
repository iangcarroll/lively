package sh.ian.lively.ui

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.accessibility.AccessibilityManager
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import java.lang.ref.WeakReference
import kotlin.math.ceil
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.sqrt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import sh.ian.lively.model.ListeningPromptAttitude
import sh.ian.lively.model.ListeningPromptMotion
import sh.ian.lively.model.ListeningPromptPolicy

/**
 * The phone's movement, as Core Motion's device motion reports it on iOS.
 * Samples arrive on the main thread with their time in seconds on the
 * owner's clock.
 */
interface ListeningPromptMotionSource {
    val isAvailable: Boolean
    fun start(onMotion: (ListeningPromptMotion, Double) -> Unit)
    fun stop()
}

/** One owner for both readers and every conversation layout. */
class ListeningPromptVisibility(
    /** Runs the hide timer, on the main thread. */
    private val scope: CoroutineScope,
    private val motionSource: ListeningPromptMotionSource,
    /** Monotonic seconds, on the clock the motion source stamps its samples with. */
    private val now: () -> Double = { SystemClock.elapsedRealtimeNanos() / 1e9 },
) {
    var isVisible by mutableStateOf(true)
        private set
    private val policy = ListeningPromptPolicy()
    private var hideJob: Job? = null
    private var generation = 0

    fun setActive(active: Boolean) {
        if (active == policy.isActive) return
        generation += 1
        policy.setActive(active, now())
        motionSource.stop()
        updateVisibility()
        if (!active || !motionSource.isAvailable) return
        val token = generation
        // Swift's deinit stops Core Motion. Nothing runs when a Kotlin object
        // is collected, so the callback holds its owner weakly and stops the
        // sensors itself once the owner is gone.
        val owner = WeakReference(this)
        val source = motionSource
        source.start { motion, timestamp ->
            val visibility = owner.get()
            if (visibility == null) source.stop() else visibility.receive(motion, timestamp, token)
        }
    }

    private fun receive(motion: ListeningPromptMotion, timestamp: Double, token: Int) {
        // A queued callback from a previous listening session must not update
        // its successor.
        if (generation != token || !policy.isActive) return
        val time = now()
        if (timestamp > time || time - timestamp >= 0.5) return
        if (policy.receive(motion, time)) updateVisibility()
    }

    private fun updateVisibility() {
        hideJob?.cancel()
        hideJob = null
        val time = now()
        isVisible = policy.isVisible(time)
        val deadline = policy.visibleUntil ?: return
        if (!policy.isActive || deadline <= time) return
        val owner = WeakReference(this)
        hideJob = scope.launch {
            // Rounded up, so the timer cannot wake just short of its deadline.
            delay(ceil((deadline - time) * 1000).toLong())
            owner.get()?.updateVisibility()
        }
    }
}

/** Swift's `listeningPromptIsActive`: only live, visible conversations need a temporary handoff reminder. */
internal fun listeningPromptIsActive(isResumed: Boolean, isLive: Boolean, isCovered: Boolean, screenReaderEnabled: Boolean) =
    isResumed && isLive && !isCovered && !screenReaderEnabled

/** Swift's `showsListeningPrompt`. */
internal fun showsListeningPrompt(isLive: Boolean, screenReaderEnabled: Boolean, isVisible: Boolean) =
    !isLive || screenReaderEnabled || isVisible

/**
 * One device-motion sample from Android's separate sensors: a rotation
 * vector, the gyroscope's radians per second and linear acceleration in
 * metres per second squared.
 */
internal fun listeningPromptMotion(rotationVector: FloatArray, rotationRate: FloatArray, linearAcceleration: FloatArray): ListeningPromptMotion {
    val x = rotationVector[0].toDouble()
    val y = rotationVector[1].toDouble()
    val z = rotationVector[2].toDouble()
    // The scalar part is optional; a unit quaternion implies it, as in
    // SensorManager.getQuaternionFromVector.
    val w = rotationVector.getOrNull(3)?.toDouble() ?: sqrt(max(0.0, 1 - x * x - y * y - z * z))
    return ListeningPromptMotion(
        attitude = ListeningPromptAttitude(w, x, y, z),
        rotationRate = magnitude(rotationRate),
        userAcceleration = magnitude(linearAcceleration) / SensorManager.GRAVITY_EARTH,
    )
}

private fun magnitude(vector: FloatArray) =
    hypot(hypot(vector[0].toDouble(), vector[1].toDouble()), vector[2].toDouble())

/**
 * CMMotionManager's device motion has no single Android sensor. The closest
 * are the game rotation vector (attitude without the magnetometer, like
 * iOS's `xArbitraryZVertical` frame: no compass or location data, and it
 * measures a turn around the phone's vertical axis), the gyroscope (rotation
 * rate) and linear acceleration (acceleration without gravity). None needs a
 * permission at this rate.
 */
private class SensorMotionSource(private val sensors: SensorManager) : ListeningPromptMotionSource, SensorEventListener {
    private val attitude: Sensor? = sensors.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
    private val gyroscope: Sensor? = sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val acceleration: Sensor? = sensors.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
    private val main = Handler(Looper.getMainLooper())
    private val rotationRate = FloatArray(3)
    private val linearAcceleration = FloatArray(3)
    private var onMotion: ((ListeningPromptMotion, Double) -> Unit)? = null

    /** Attitude alone still detects a turn; the other two add abrupt movement. */
    override val isAvailable: Boolean get() = attitude != null

    override fun start(onMotion: (ListeningPromptMotion, Double) -> Unit) {
        stop()
        this.onMotion = onMotion
        for (sensor in listOfNotNull(attitude, gyroscope, acceleration)) {
            sensors.registerListener(this, sensor, SAMPLING_PERIOD_US, main)
        }
    }

    override fun stop() {
        sensors.unregisterListener(this)
        onMotion = null
        rotationRate.fill(0f)
        linearAcceleration.fill(0f)
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_GYROSCOPE -> event.values.copyInto(rotationRate, endIndex = 3)
            Sensor.TYPE_LINEAR_ACCELERATION -> event.values.copyInto(linearAcceleration, endIndex = 3)
            // Each attitude reading carries the latest of the other two, like
            // one CMDeviceMotion. Sensor events are stamped in nanoseconds on
            // the elapsed-realtime clock.
            Sensor.TYPE_GAME_ROTATION_VECTOR ->
                onMotion?.invoke(listeningPromptMotion(event.values, rotationRate, linearAcceleration), event.timestamp / 1e9)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) = Unit

    private companion object {
        /** Ten hertz, as on iOS. */
        const val SAMPLING_PERIOD_US = 100_000
    }
}

/** What a conversation layout needs to draw the listening guidance. */
@Immutable
class ListeningPromptState(
    val showsListeningPrompt: Boolean,
    /** The guidance's fade in and out; immediate when animations are turned off. */
    val fade: FiniteAnimationSpec<Float>,
)

/**
 * Owns the conversation's [ListeningPromptVisibility]. The reminder fades
 * only while [isLive] (listening, with a live connection), the screen is
 * resumed (iOS's active scene phase; another destination on top pauses this
 * one) and nothing in the same window covers it ([isCovered]: a sheet, which
 * doesn't pause the screen). Leaving the composition stops the sensors.
 *
 * TalkBack's touch exploration is the closest to iOS's VoiceOver check: the
 * guidance stays up for it, with no motion sensing. A zero animator duration
 * scale ("Remove animations") is the closest to iOS's Reduce Motion.
 */
@Composable
fun rememberListeningPromptVisibility(isLive: Boolean, isCovered: Boolean = false): ListeningPromptState {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val visibility = remember(context) {
        ListeningPromptVisibility(scope, SensorMotionSource(context.getSystemService(SensorManager::class.java)))
    }
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val isResumed = lifecycleState.isAtLeast(Lifecycle.State.RESUMED)
    val screenReaderEnabled = rememberTouchExplorationEnabled()
    val active = listeningPromptIsActive(isResumed, isLive, isCovered, screenReaderEnabled)
    DisposableEffect(visibility, active) {
        visibility.setActive(active)
        onDispose { visibility.setActive(false) }
    }
    // Read again on each return to the app, where the setting may have changed.
    val reduceMotion = remember(context, isResumed) {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    return ListeningPromptState(
        showsListeningPrompt = showsListeningPrompt(isLive, screenReaderEnabled, visibility.isVisible),
        fade = if (reduceMotion) snap() else tween(durationMillis = 250, easing = EaseInOut),
    )
}

@Composable
private fun rememberTouchExplorationEnabled(): Boolean {
    val manager = LocalContext.current.getSystemService(AccessibilityManager::class.java)
    var enabled by remember(manager) { mutableStateOf(manager.isTouchExplorationEnabled) }
    DisposableEffect(manager) {
        val listener = AccessibilityManager.TouchExplorationStateChangeListener { enabled = it }
        manager.addTouchExplorationStateChangeListener(listener)
        enabled = manager.isTouchExplorationEnabled
        onDispose { manager.removeTouchExplorationStateChangeListener(listener) }
    }
    return enabled
}
