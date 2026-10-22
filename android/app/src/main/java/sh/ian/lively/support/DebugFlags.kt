package sh.ian.lively.support

import android.content.Intent
import android.os.Bundle
import sh.ian.lively.BuildConfig

/**
 * Launch options, the Android version of the iOS app's launch arguments.
 * Pass them as intent extras:
 *
 *     adb shell am start -n sh.ian.lively/.MainActivity --ez LivelyDemo true
 *
 * - `LivelyDemo` plays a scripted conversation through the real pipeline,
 *   without a key. `LivelyDemoAutoPlay` starts it when the screen appears.
 * - `LivelyOnboarding` shows the welcome tour on every launch.
 *
 * Debug builds also take, for testing recovery on bad networks:
 * - `LivelyAudioFile PATH`: plays a 16-bit WAV file into the app instead of the mic.
 * - `LivelyDropout "AT,FOR"`: blackholes the network FOR seconds, AT seconds in.
 * - `LivelySlowConnect SECONDS`: holds up each primary connection attempt.
 * - `LivelyPathChange AT`: reports a network change AT seconds in.
 */
object DebugFlags {
    var demo = false
    var demoAutoPlay = false
    var forceOnboarding = false
    var audioFile: String? = null
    var dropout: Pair<Double, Double>? = null
    var slowConnectSeconds = 0.0
    var pathChangeAt = 0.0

    fun read(intent: Intent?) {
        val extras: Bundle = intent?.extras ?: return
        demo = extras.flag("LivelyDemo") ?: demo
        demoAutoPlay = extras.flag("LivelyDemoAutoPlay") ?: demoAutoPlay
        forceOnboarding = extras.flag("LivelyOnboarding") ?: forceOnboarding
        if (!BuildConfig.DEBUG) return
        audioFile = extras.getString("LivelyAudioFile") ?: audioFile
        extras.getString("LivelyDropout")?.split(",")?.mapNotNull { it.trim().toDoubleOrNull() }?.let {
            if (it.size == 2) dropout = it[0] to it[1]
        }
        extras.number("LivelySlowConnect")?.let { slowConnectSeconds = it }
        extras.number("LivelyPathChange")?.let { pathChangeAt = it }
    }

    /** `--ez KEY true` or `-e KEY YES`. */
    private fun Bundle.flag(key: String): Boolean? {
        if (!containsKey(key)) return null
        getString(key)?.let { return it.equals("yes", true) || it.equals("true", true) || it == "1" }
        return getBoolean(key)
    }

    private fun Bundle.number(key: String): Double? {
        if (!containsKey(key)) return null
        getString(key)?.let { return it.toDoubleOrNull() }
        return getDouble(key, getInt(key, 0).toDouble())
    }
}
