package sh.ian.lively.model

import androidx.annotation.StringRes
import sh.ian.lively.R
import sh.ian.lively.support.modelString
import java.util.Locale

/** The lookup language is independent of the conversation and speech provider. */
data class AddressLanguage(val code: String) {
    val locale: Locale get() = Locale.forLanguageTag(code)

    val englishName: String
        get() = when (code) {
            "zh-Hans" -> "Chinese (Simplified)"
            "zh-Hant" -> "Chinese (Traditional)"
            else -> locale.getDisplayLanguage(Locale.ENGLISH).ifEmpty { code }
        }

    val displayName: String get() = locale.getDisplayName(Locale.getDefault()).ifEmpty { englishName }

    val nativeName: String
        get() = when (code) {
            "zh-Hans" -> "简体中文"
            "zh-Hant" -> "繁體中文"
            else -> {
                val name = locale.getDisplayLanguage(locale)
                // Capitalized as in the conversation's language list.
                if (name.isEmpty() || name == code) englishName else name.substring(0, 1).uppercase(locale) + name.substring(1)
            }
        }

    companion object {
        val all: List<AddressLanguage> by lazy {
            val codes = Locale.getISOLanguages().filter { it.length == 2 && it != "zh" } + listOf("zh-Hans", "zh-Hant")
            codes.map(::AddressLanguage)
                // Codes the platform has no name for can't be picked by name.
                // The platform may also list a language under an old code ("iw") and its new one.
                .filter { it.englishName != it.code }
                .distinctBy { it.englishName }
                .sortedWith(compareBy(java.text.Collator.getInstance()) { it.displayName })
        }

        fun matching(code: String): AddressLanguage {
            val normalized = code.replace('_', '-').lowercase(Locale.ROOT)
            if (normalized == "zh" || normalized.startsWith("zh-")) {
                val traditional = "hans" !in normalized &&
                    ("hant" in normalized || normalized.substringAfterLast('-') in setOf("tw", "hk", "mo"))
                return AddressLanguage(if (traditional) "zh-Hant" else "zh-Hans")
            }
            val base = normalized.substringBefore('-')
            return all.firstOrNull { it.code == normalized || it.code == base } ?: AddressLanguage("en")
        }
    }
}

/** Only the selected map location is opened; localization cannot replace it. */
data class AddressPlace(
    val id: String,
    val name: String,
    val subtitle: String,
    val latitude: Double,
    val longitude: Double,
    val countryCode: String?,
) {
    val hasValidCoordinate: Boolean
        get() = latitude.isFinite() && longitude.isFinite() && latitude in -90.0..90.0 && longitude in -180.0..180.0
}

/**
 * Why a lookup failed, with the line shown for it. Swift also has
 * `rateLimited`, which MapKit reports and Android's Geocoder doesn't.
 */
enum class AddressLookupError(@param:StringRes private val messageRes: Int, private val english: String) {
    UNAVAILABLE(R.string.address_lookup_unavailable, "Address lookup is unavailable right now. Try again."),
    NETWORK(R.string.address_lookup_requires_internet, "Connect to the internet to look up an address."),
    MISSING_ADDRESS(R.string.localized_address_unavailable, "An address in this language wasn’t available for this place. Try another language or a more specific address."),
    EXPIRED_SELECTION(R.string.search_again_to_choose_this_place, "Search again to choose this place.");

    val message: String get() = modelString(messageRes) { english }
}

class AddressLookupException(val error: AddressLookupError) : Exception(error.message)

interface AddressLookupProviding {
    suspend fun findPlaces(query: String): List<AddressPlace>
    suspend fun address(place: AddressPlace, language: AddressLanguage): String
    fun cancel()
}
