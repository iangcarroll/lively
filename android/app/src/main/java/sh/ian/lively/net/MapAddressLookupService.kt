package sh.ian.lively.net

import android.content.Context
import android.content.res.Resources
import android.icu.util.ULocale
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.os.Build
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import sh.ian.lively.model.AddressLanguage
import sh.ian.lively.model.AddressLookupError
import sh.ian.lively.model.AddressLookupException
import sh.ian.lively.model.AddressLookupProviding
import sh.ian.lively.model.AddressPlace
import java.io.IOException
import java.util.Locale
import java.util.UUID
import java.util.regex.Pattern
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Looks up map data without using the conversation or speech providers.
 *
 * Swift uses MapKit. Android has no map service of its own to link, and the
 * Places SDK needs a paid key, so this uses the system Geocoder: Google's on
 * phones with Play services, another vendor's or none elsewhere. It matches
 * addresses and well-known places, but it isn't a place search: it has no
 * points-of-interest index, completions or result types, it doesn't say when
 * it is throttled, and a request can't be cancelled, only ignored.
 *
 * Its state belongs to the main thread, where the store calls it.
 */
class MapAddressLookupService(
    context: Context,
    /** The device has a network, so a failure isn't for want of one. */
    private val isOnline: () -> Boolean,
) : AddressLookupProviding {
    private class Candidate(val result: Address, val place: AddressPlace, val address: String, val query: String, val language: AddressLanguage)

    private data class CacheKey(val placeID: String, val languageCode: String)

    private val context = context.applicationContext
    private var operation = Any()
    private val candidates = mutableMapOf<String, Candidate>()

    /** In insertion order, so the oldest is dropped first. */
    private val localizedAddresses = LinkedHashMap<CacheKey, String>()

    override fun cancel() {
        operation = Any()
    }

    override suspend fun findPlaces(query: String): List<AddressPlace> {
        cancel()
        candidates.clear()
        localizedAddresses.clear()
        val input = query.trim()
        if (input.isEmpty() || input.codePointCount(0, input.length) > 1_000) return emptyList()
        val token = operation

        // The Geocoder answers in the language it is made with: the device's here.
        val device = Resources.getSystem().configuration.locales[0]
        val language = AddressLanguage.matching(ULocale.addLikelySubtags(ULocale.forLocale(device)).toLanguageTag())
        val results = geocode(Geocoder(context, device), input, MAXIMUM_PLACES, near = null)
        checkCurrent(token)

        // One request, so the places keep the Geocoder's order. Swift ranks
        // them because it merges a landmark search with an address search.
        val seen = mutableSetOf<String>()
        val places = mutableListOf<AddressPlace>()
        for (result in results) {
            if (!result.hasLatitude() || !result.hasLongitude()) continue
            val address = formattedAddress(result)
            // The Geocoder often names a result after its house number.
            val name = result.featureName?.trim().orEmpty().takeIf { it.any(Char::isLetter) }.orEmpty()
            if (address.isEmpty() && name.isEmpty()) continue
            if (!seen.add("$name|${result.latitude}|${result.longitude}")) continue
            val place = AddressPlace(
                id = UUID.randomUUID().toString(),
                name = name.ifEmpty { address },
                subtitle = address,
                latitude = result.latitude,
                longitude = result.longitude,
                countryCode = result.countryCode,
            )
            candidates[place.id] = Candidate(result, place, address, input, language)
            places += place
        }
        return places
    }

    override suspend fun address(place: AddressPlace, language: AddressLanguage): String {
        val candidate = candidates[place.id]?.takeIf { it.place == place }
            ?: throw AddressLookupException(AddressLookupError.EXPIRED_SELECTION)
        cancel()
        val token = operation
        val key = CacheKey(place.id, language.code)
        localizedAddresses[key]?.let { return it }
        if (candidate.address.isEmpty()) throw AddressLookupException(AddressLookupError.MISSING_ADDRESS)
        val script = ULocale.addLikelySubtags(ULocale.forLocale(language.locale)).script.ifEmpty { null }
        // The search already supplies an address in the device's language.
        // Re-geocoding it can lose details or return another locale's cached text.
        if (language == candidate.language && AddressVerification.supportsRequestedScript(candidate.address, script)) {
            return candidate.address
        }

        // Forward lookup preserves an area's address. Reverse lookup of a city
        // centroid can incorrectly turn it into a nearby building's address.
        val geocoder = Geocoder(context, AddressVerification.geocodingLocale(language, place.countryCode))
        val queries = AddressVerification.geocodingQueries(
            candidate.address, candidate.query, place.countryCode, candidate.result.countryName, language,
        )
        for (query in queries) {
            checkCurrent(token)
            val results = geocode(geocoder, query, MAXIMUM_LOCALIZATIONS, near = place)
            checkCurrent(token)
            for (result in results) {
                val text = formattedAddress(result)
                if (text.isEmpty() || !representsSameAddress(result, text, candidate) ||
                    !AddressVerification.supportsRequestedScript(text, script)
                ) continue
                localizedAddresses[key] = text
                while (localizedAddresses.size > MAXIMUM_CACHED_ADDRESSES) localizedAddresses.remove(localizedAddresses.keys.first())
                return text
            }
        }
        throw AddressLookupException(AddressLookupError.MISSING_ADDRESS)
    }

    private fun checkCurrent(token: Any) {
        if (operation !== token) throw CancellationException()
    }

    /** No matches is an empty list; anything else that goes wrong is a lookup error. */
    private suspend fun geocode(geocoder: Geocoder, query: String, limit: Int, near: AddressPlace?): List<Address> {
        if (!isOnline()) throw AddressLookupException(AddressLookupError.NETWORK)
        if (!Geocoder.isPresent()) throw AddressLookupException(AddressLookupError.UNAVAILABLE)
        // The Geocoder answers on a binder thread; come back to the main one.
        return withContext(Dispatchers.Main.immediate) {
            withTimeoutOrNull(TIMEOUT_MS) { request(geocoder, query, limit, near) }
        } ?: throw AddressLookupException(AddressLookupError.UNAVAILABLE)
    }

    private suspend fun request(geocoder: Geocoder, query: String, limit: Int, near: AddressPlace?): List<Address> {
        // Around the chosen place, like the region of MapKit's geocoding request.
        val south = ((near?.latitude ?: 0.0) - SEARCH_SPAN / 2).coerceIn(-90.0, 90.0)
        val north = ((near?.latitude ?: 0.0) + SEARCH_SPAN / 2).coerceIn(-90.0, 90.0)
        val west = ((near?.longitude ?: 0.0) - SEARCH_SPAN / 2).coerceIn(-180.0, 180.0)
        val east = ((near?.longitude ?: 0.0) + SEARCH_SPAN / 2).coerceIn(-180.0, 180.0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            suspendCancellableCoroutine { continuation ->
                val listener = object : Geocoder.GeocodeListener {
                    override fun onGeocode(addresses: MutableList<Address>) {
                        if (continuation.isActive) continuation.resume(addresses.toList())
                    }

                    override fun onError(errorMessage: String?) {
                        if (continuation.isActive) continuation.resumeWithException(failure())
                    }
                }
                if (near == null) {
                    geocoder.getFromLocationName(query, limit, listener)
                } else {
                    geocoder.getFromLocationName(query, limit, south, west, north, east, listener)
                }
            }
        } else {
            // The listener version needs API 33; before it, the call blocks.
            runInterruptible(Dispatchers.IO) {
                try {
                    @Suppress("DEPRECATION")
                    if (near == null) {
                        geocoder.getFromLocationName(query, limit)
                    } else {
                        geocoder.getFromLocationName(query, limit, south, west, north, east)
                    }.orEmpty()
                } catch (_: IOException) {
                    throw failure()
                }
            }
        }
    }

    /** The Geocoder doesn't say why it failed, so the network's state has to. */
    private fun failure() = AddressLookupException(if (isOnline()) AddressLookupError.UNAVAILABLE else AddressLookupError.NETWORK)

    private fun formattedAddress(result: Address): String =
        (0..result.maxAddressLineIndex).mapNotNull { result.getAddressLine(it) }.joinToString("\n").trim()

    private fun representsSameAddress(result: Address, text: String, source: Candidate): Boolean {
        val country = source.place.countryCode ?: return false
        if (result.countryCode != country || !result.hasLatitude() || !result.hasLongitude()) return false
        val distance = FloatArray(1)
        Location.distanceBetween(source.place.latitude, source.place.longitude, result.latitude, result.longitude, distance)
        if (!AddressVerification.isWithinLocationTolerance(distance[0].toDouble(), source.address)) return false
        // Preserve the numbers supplied by the search, including postal codes and units.
        // Added or dropped numbers may identify a different address or precision.
        return AddressVerification.numberParts(text) == AddressVerification.numberParts(source.address)
    }

    private companion object {
        const val MAXIMUM_PLACES = 12
        const val MAXIMUM_LOCALIZATIONS = 5
        const val MAXIMUM_CACHED_ADDRESSES = 24
        const val TIMEOUT_MS = 20_000L

        /** Degrees of latitude and longitude searched around the chosen place. */
        const val SEARCH_SPAN = 0.05
    }
}

/**
 * What a localized address must pass before it stands in for the chosen
 * place. Kept apart from the Geocoder so plain JVM tests can check it.
 */
internal object AddressVerification {
    fun geocodingQueries(address: String, query: String, countryCode: String?, countryName: String?, language: AddressLanguage): List<String> {
        // The Geocoder may fail to parse its own formatted address even when the
        // user's original street-address query resolves fully. Both must pass the
        // same destination and number checks before becoming a result.
        val original = listOf(address, query)
        val localized = mutableListOf<String>()
        val region = countryCode?.let(::region)
        val country = region?.getDisplayCountry(language.locale)?.takeIf { it.isNotEmpty() && it != countryCode }
        if (region != null && country != null) {
            val names = listOfNotNull(countryName, region.getDisplayCountry(Locale.ENGLISH))
            for (text in original) {
                for (name in names) {
                    if (name == country) continue
                    // Change a country component, never words in a street or venue name.
                    val matcher = Pattern.compile(
                        "(?:^|[,\\n、])\\s*(" + Pattern.quote(name) + ")(?=\\s*(?:[,\\n、]|$|〒|\\p{Nd}))",
                        Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE,
                    ).matcher(text)
                    var range: IntRange? = null
                    while (matcher.find()) range = matcher.start(1) until matcher.end(1)
                    localized += text.replaceRange(range ?: continue, country)
                    break
                }
            }
        }
        return (localized + original).filter { it.isNotEmpty() }.distinct()
    }

    fun geocodingLocale(language: AddressLanguage, countryCode: String?): Locale {
        // The Geocoder reads the language and region and ignores the script, so
        // for Chinese the region has to say which one: "zh-Hant-JP" is answered
        // in Simplified. For other languages it is the chosen place's country, as in Swift.
        val region = when (language.code) {
            "zh-Hant" -> countryCode?.takeIf { it in TRADITIONAL_REGIONS } ?: "TW"
            "zh-Hans" -> "CN"
            else -> countryCode?.takeIf { region(it) != null } ?: return language.locale
        }
        return Locale.Builder().setLocale(language.locale).setRegion(region).build()
    }

    /** [script] is the ISO 15924 code the language is written in, like "Jpan", or null when unknown. */
    fun supportsRequestedScript(text: String, script: String?): Boolean {
        script ?: return true
        val scripts = when (script) {
            "Jpan" -> listOf("Han", "Hiragana", "Katakana")
            "Hans", "Hant" -> listOf("Han")
            "Kore" -> listOf("Hangul", "Han")
            else -> listOf(script)
        }
        // A locale hint can still yield fallback text. Require a letter from the
        // requested script before presenting a non-Latin-language result.
        val alternatives = scripts.joinToString("|") { "\\p{sc=$it}" }
        return Regex("(?=\\p{L})(?:$alternatives)").containsMatchIn(text)
    }

    fun isWithinLocationTolerance(distance: Double, sourceAddress: String): Boolean {
        if (!distance.isFinite() || distance < 0) return false
        // Numbered addresses need a tight match. Unnumbered areas can have a
        // representative point away from the selected landmark's own pin.
        val limit = if (numberParts(sourceAddress).isEmpty()) 500.0 else 50.0
        return distance <= limit
    }

    fun numberParts(text: String): List<String> {
        val parts = mutableListOf<String>()
        val digits = StringBuilder()
        text.codePoints().forEach { point ->
            if (Character.getType(point) == Character.DECIMAL_DIGIT_NUMBER.toInt()) {
                digits.append(Character.digit(point, 10))
            } else if (digits.isNotEmpty()) {
                parts += digits.toString()
                digits.clear()
            }
        }
        if (digits.isNotEmpty()) parts += digits.toString()
        return parts.sorted()
    }

    private val TRADITIONAL_REGIONS = setOf("TW", "HK", "MO")

    /** A locale for just this country, or null when the code isn't one. */
    private fun region(countryCode: String): Locale? =
        runCatching { Locale.Builder().setRegion(countryCode).build() }.getOrNull()?.takeIf { it.country.isNotEmpty() }
}
