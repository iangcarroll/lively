package sh.ian.lively.model

import sh.ian.lively.R
import sh.ian.lively.support.modelString
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.Locale

/**
 * Finds the country the device is in. The Android one is
 * `support/RegionLocator.kt`; Swift keeps its locator in the same file.
 */
interface RegionLocating {
    /** The app may read the approximate location. */
    val isAuthorized: Boolean

    /** The ISO 3166 code of the country the device is in, or null when it can't be found. */
    suspend fun region(): String?
}

/**
 * Optional: sets the conversation's languages from where the device is.
 * Your side is the system language when the engine supports it, or English;
 * the other side is the language of the country you're in.
 *
 * Off until turned on in Settings or the welcome tour, which is when Lively
 * asks for location access. After that the pair is set again only on
 * arriving in another country, so a choice made by hand sticks.
 */
class LocationLanguages(
    private val settings: AppSettings,
    private val locator: RegionLocating,
    private val scope: CoroutineScope,
    /** The first language in the system's list, and its Chinese script. */
    private val systemLanguage: () -> Pair<Language, ChineseScript>,
) {
    sealed interface Status {
        data object Idle : Status
        data object Locating : Status

        /** The pair was set for this country. */
        data class Applied(val region: String) : Status

        /** This country has no language that differs from yours, or none the engine supports. */
        data class Unchanged(val region: String) : Status
        data object Denied : Status
        data object Failed : Status

        /** A line for under the switch, or null when there's nothing to say. */
        val message: String?
            get() = when (this) {
                Idle -> null
                Locating -> modelString(R.string.finding_where_you_are) { "Finding where you are…" }
                is Applied -> modelString(R.string.languages_set_for_value, nameOfRegion(region)) { "Languages set for ${nameOfRegion(region)}." }
                is Unchanged -> modelString(R.string.no_local_language_suggestion, nameOfRegion(region)) { "No different language to suggest for ${nameOfRegion(region)}, so your languages stay as they are." }
                Denied -> modelString(R.string.location_permission_denied) { "Lively doesn't have location access. Allow it in the system settings, then turn this on again." }
                Failed -> modelString(R.string.location_not_found) { "Couldn't find where you are. Lively will try again the next time it opens." }
            }
    }

    var status: Status by mutableStateOf(Status.Idle)
        private set

    private var isUpdating = false

    /**
     * Turns the feature on and sets the pair. The screen asks for location
     * access first and passes the answer, since on Android only an activity
     * can show the prompt.
     */
    fun enable(granted: Boolean) {
        if (!granted) {
            status = Status.Denied
            return
        }
        settings.usesLocationLanguages = true
        // Not the screen's scope: leaving Settings shouldn't drop the lookup.
        scope.launch { update(force = true) }
    }

    fun disable() {
        settings.usesLocationLanguages = false
        status = Status.Idle
    }

    /**
     * Looks up the country and sets the pair if it's a new one (or [force]).
     * `canChange` is false while a conversation is under way; the lookup
     * then waits for a later call. It's asked again once the country is
     * known, since finding it takes long enough to start talking.
     * Returns true when the pair changed.
     */
    suspend fun update(force: Boolean = false, canChange: () -> Boolean = { true }): Boolean {
        if (!settings.usesLocationLanguages || !canChange() || isUpdating) return false
        if (!locator.isAuthorized) {
            // Access was taken away in the system settings.
            settings.usesLocationLanguages = false
            status = Status.Denied
            return false
        }
        isUpdating = true
        try {
            if (force) status = Status.Locating
            val region = locator.region()
            if (region == null) {
                if (force) status = Status.Failed
                return false
            }
            if (!settings.usesLocationLanguages || !canChange() || (!force && region == settings.locationLanguageRegion)) return false
            settings.locationLanguageRegion = region
            val (own, ownScript) = systemLanguage()
            val suggestion = suggestion(region, own, ownScript, settings.provider.languages)
            if (suggestion == null) {
                status = Status.Unchanged(region)
                return false
            }
            val changed = settings.languages != suggestion.languages
            settings.languages = suggestion.languages
            suggestion.script?.let { settings.chineseScript = it }
            status = Status.Applied(region)
            return changed
        } finally {
            isUpdating = false
        }
    }

    data class Suggestion(
        val languages: LanguagePair,
        /** Set when one side is Chinese: Traditional in Taiwan, Hong Kong and Macau. */
        val script: ChineseScript? = null,
    )

    companion object {
        val SUMMARY get() = modelString(R.string.location_travel_summary) {
            "Sets your language and the local language when you arrive in another country. Lively uses your approximate location only to look up the country."
        }

        /**
         * The pair for someone whose system language is [own], in [region] (an
         * ISO 3166 code). Null when the country's language is their own, isn't
         * known, or isn't one the engine supports.
         */
        fun suggestion(region: String, own: Language, ownScript: ChineseScript, supported: List<Language>): Suggestion? {
            val code = region.uppercase(Locale.ROOT)
            val first = if (own in supported) own else Language.ENGLISH
            val local = languageForRegion(code) ?: return null
            if (local == first || local !in supported || first !in supported) return null
            val script = when {
                local == Language.CHINESE -> if (code in TRADITIONAL_REGIONS) ChineseScript.TRADITIONAL else ChineseScript.SIMPLIFIED
                first == Language.CHINESE -> ownScript
                else -> null
            }
            return Suggestion(LanguagePair(first, local), script)
        }

        /** The most widely spoken language of a country, among those Lively has. */
        fun languageForRegion(region: String): Language? = REGION_LANGUAGES[region.uppercase(Locale.ROOT)]?.let(::Language)

        /**
         * A system language code as one of Lively's, which uses "no" for
         * Norwegian and "tl" for Filipino.
         */
        fun languageForSystemCode(code: String): Language = when (val lower = code.lowercase(Locale.ROOT)) {
            "nb", "nn" -> Language("no")
            "fil" -> Language("tl")
            "iw" -> Language("he")
            "in" -> Language("id")
            "yue" -> Language.CHINESE
            else -> Language(lower)
        }

        fun nameOfRegion(region: String): String =
            Locale.Builder().setRegion(region).build().getDisplayCountry(Locale.getDefault()).ifEmpty { region }

        private val TRADITIONAL_REGIONS = setOf("TW", "HK", "MO")

        /**
         * Country codes by language. Countries whose main language Lively
         * doesn't have (Iceland, Nepal, Ethiopia…) are left out, and the pair
         * stays as it is there.
         */
        private val REGION_LANGUAGES: Map<String, String> = mapOf(
            "en" to "US GB AU NZ IE CA SG ZA NG GH UG ZW ZM LR SL GM BW NA MW FJ PG MT JM TT BS BB GY BZ " +
                "AG DM GD KN LC VC GI GG JE IM BM KY VG VI GU AS MP",
            "zh" to "CN TW HK MO",
            "es" to "ES MX AR CO CL PE VE EC GT CU BO DO HN PY SV NI CR PA UY PR GQ",
            "fr" to "FR MC LU SN CI ML BF NE TD GN BJ TG CM GA CG CD MG HT DJ CF KM BI GP MQ GF RE PF NC YT BL MF PM WF",
            "pt" to "PT BR AO MZ CV GW ST TL",
            "de" to "DE AT CH LI",
            "it" to "IT SM VA",
            "nl" to "NL BE SR AW CW SX BQ",
            "ru" to "RU BY KG TJ TM UZ",
            "ar" to "SA AE EG IQ JO KW LB LY MA DZ TN OM QA BH YE SY SD PS MR",
            "he" to "IL", "fa" to "IR AF", "tr" to "TR", "el" to "GR CY",
            "hi" to "IN", "bn" to "BD", "ur" to "PK",
            "ja" to "JP", "ko" to "KR KP", "vi" to "VN", "th" to "TH", "id" to "ID", "ms" to "MY BN", "tl" to "PH",
            "sv" to "SE AX", "da" to "DK GL FO", "no" to "NO SJ", "fi" to "FI",
            "pl" to "PL", "cs" to "CZ", "sk" to "SK", "hu" to "HU", "ro" to "RO MD", "bg" to "BG", "hr" to "HR",
            "sr" to "RS ME", "bs" to "BA", "sl" to "SI", "mk" to "MK", "sq" to "AL XK", "uk" to "UA",
            "et" to "EE", "lv" to "LV", "lt" to "LT", "az" to "AZ", "kk" to "KZ", "sw" to "TZ KE", "ca" to "AD",
        ).flatMap { (language, regions) -> regions.split(" ").map { it to language } }.toMap()
    }
}
