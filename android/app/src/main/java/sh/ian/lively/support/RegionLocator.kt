package sh.ian.lively.support

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Resources
import android.icu.util.ULocale
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import sh.ian.lively.model.ChineseScript
import sh.ian.lively.model.Language
import sh.ian.lively.model.LocationLanguages
import sh.ian.lively.model.RegionLocating
import java.util.Locale
import kotlin.coroutines.resume

/**
 * Finds the country the device is in: an approximate fix from the platform
 * LocationManager, then the system Geocoder (Core Location and MapKit on
 * iOS). Neither needs Play services to be linked in.
 */
class RegionLocator(private val context: Context) : RegionLocating {
    override val isAuthorized: Boolean
        get() = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    override suspend fun region(): String? {
        // Launch with `-e LivelyRegion JP` to stand in for being there.
        DebugFlags.region?.let { return it }
        if (!isAuthorized) return null
        // A device without a geocoder (no Play services) or without a
        // network for it still knows which country its mobile network is in.
        // iOS has no equivalent, so it waits for the geocoder there.
        return location()?.let { geocode(it) } ?: networkCountry()
    }

    @SuppressLint("MissingPermission")
    private suspend fun location(): Location? {
        val manager = context.getSystemService(LocationManager::class.java) ?: return null
        // GPS needs precise access, which Lively doesn't ask for.
        val provider = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && manager.hasProvider(LocationManager.FUSED_PROVIDER) -> LocationManager.FUSED_PROVIDER
            manager.allProviders.contains(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            else -> LocationManager.PASSIVE_PROVIDER
        }
        val current = runCatching {
            withTimeoutOrNull(10_000) {
                suspendCancellableCoroutine { continuation ->
                    val signal = CancellationSignal()
                    continuation.invokeOnCancellation { signal.cancel() }
                    LocationManagerCompat.getCurrentLocation(manager, provider, signal, ContextCompat.getMainExecutor(context)) { location ->
                        if (continuation.isActive) continuation.resume(location)
                    }
                }
            }
        }.getOrNull()
        // The country is all that's needed, so an older fix will do.
        return current ?: manager.getProviders(true).firstNotNullOfOrNull { name ->
            runCatching { manager.getLastKnownLocation(name) }.getOrNull()
        }
    }

    private suspend fun geocode(location: Location): String? {
        if (!Geocoder.isPresent()) return null
        return withContext(Dispatchers.IO) {
            runCatching {
                @Suppress("DEPRECATION") // The listener version needs API 33; this is off the main thread.
                Geocoder(context, Locale.US).getFromLocation(location.latitude, location.longitude, 1)
            }.getOrNull()?.firstOrNull()?.countryCode?.takeIf { it.length == 2 }?.uppercase(Locale.ROOT)
        }
    }

    private fun networkCountry(): String? =
        context.getSystemService(TelephonyManager::class.java)?.networkCountryIso?.takeIf { it.length == 2 }?.uppercase(Locale.ROOT)

    companion object {
        /** The first language in the system's list, and its Chinese script. */
        fun systemLanguage(): Pair<Language, ChineseScript> {
            val locale = Resources.getSystem().configuration.locales[0]
            // "zh-HK" has no script of its own; the likely subtags add "Hant".
            val script = ULocale.addLikelySubtags(ULocale.forLocale(locale)).script
            val traditional = script == "Hant" || locale.language == "yue"
            return LocationLanguages.languageForSystemCode(locale.language) to
                (if (traditional) ChineseScript.TRADITIONAL else ChineseScript.SIMPLIFIED)
        }
    }
}
