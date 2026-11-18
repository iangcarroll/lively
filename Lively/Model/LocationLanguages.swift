import CoreLocation
import MapKit
import Observation

/// Optional: sets the conversation's languages from where the device is.
/// Your side is the system language when the engine supports it, or English;
/// the other side is the language of the country you're in.
///
/// Off until turned on in Settings or the welcome tour, which is when Lively
/// asks for location access. After that the pair is set again only on
/// arriving in another country, so a choice made by hand sticks.
@Observable
final class LocationLanguages {
    static let shared = LocationLanguages()

    enum Status: Equatable {
        case idle, locating
        /// The pair was set for this country.
        case applied(region: String)
        /// This country has no language that differs from yours, or none the engine supports.
        case unchanged(region: String)
        case denied, failed

        /// A line for under the switch, or nil when there's nothing to say.
        var message: String? {
            switch self {
            case .idle: nil
            case .locating: "Finding where you are…"
            case .applied(let region): "Languages set for \(LocationLanguages.name(ofRegion: region))."
            case .unchanged(let region):
                "No different language to suggest for \(LocationLanguages.name(ofRegion: region)), so your languages stay as they are."
            case .denied: "Lively doesn't have location access. Allow it in the system settings, then turn this on again."
            case .failed: "Couldn't find where you are. Lively will try again the next time it opens."
            }
        }
    }

    static let summary = "Sets your language and the local language when you arrive in another country. "
        + "Lively uses your approximate location only to look up the country."

    private(set) var status: Status = .idle
    /// Waiting on the permission prompt, so the switch can stay on meanwhile.
    private(set) var isEnabling = false

    private let settings = AppSettings.shared
    @ObservationIgnored private lazy var locator = RegionLocator()
    @ObservationIgnored private var isUpdating = false

    /// Turns the feature on: asks for location access, then sets the pair.
    func enable() async {
        guard !isEnabling else { return }
        isEnabling = true
        defer { isEnabling = false }
        guard await locator.requestAuthorization() else {
            status = .denied
            return
        }
        settings.usesLocationLanguages = true
        await update(force: true)
    }

    func disable() {
        settings.usesLocationLanguages = false
        status = .idle
    }

    /// Looks up the country and sets the pair if it's a new one (or `force`).
    /// `canChange` is false while a conversation is under way; the lookup
    /// then waits for a later call. It's asked again once the country is
    /// known, since finding it takes long enough to start talking.
    /// Returns true when the pair changed.
    @discardableResult
    func update(force: Bool = false, canChange: () -> Bool = { true }) async -> Bool {
        guard settings.usesLocationLanguages, canChange(), !isUpdating else { return false }
        guard locator.isAuthorized else {
            // Access was taken away in the system settings.
            settings.usesLocationLanguages = false
            status = .denied
            return false
        }
        isUpdating = true
        defer { isUpdating = false }
        if force { status = .locating }
        guard let region = await locator.region() else {
            if force { status = .failed }
            return false
        }
        guard settings.usesLocationLanguages, canChange(), force || region != settings.locationLanguageRegion else { return false }
        settings.locationLanguageRegion = region
        let system = Self.systemLanguage
        guard let suggestion = Self.suggestion(
            region: region, own: system.language, ownScript: system.script, supported: settings.provider.languages
        ) else {
            status = .unchanged(region: region)
            return false
        }
        let changed = settings.languages != suggestion.languages
        settings.languages = suggestion.languages
        if let script = suggestion.script { settings.chineseScript = script }
        status = .applied(region: region)
        return changed
    }

    // MARK: - Choosing the pair

    struct Suggestion: Equatable {
        var languages: LanguagePair
        /// Set when one side is Chinese: Traditional in Taiwan, Hong Kong and Macau.
        var script: ChineseScript?
    }

    /// The pair for someone whose system language is `own`, in `region` (an
    /// ISO 3166 code). Nil when the country's language is their own, isn't
    /// known, or isn't one the engine supports.
    static func suggestion(
        region: String, own: Language, ownScript: ChineseScript, supported: [Language]
    ) -> Suggestion? {
        let region = region.uppercased()
        let first = supported.contains(own) ? own : .english
        guard let local = language(forRegion: region), local != first,
              supported.contains(local), supported.contains(first) else { return nil }
        var script: ChineseScript?
        if local == .chinese {
            script = traditionalRegions.contains(region) ? .traditional : .simplified
        } else if first == .chinese {
            script = ownScript
        }
        return Suggestion(languages: LanguagePair(first: first, second: local), script: script)
    }

    /// The most widely spoken language of a country, among those Lively has.
    static func language(forRegion region: String) -> Language? {
        regionLanguages[region.uppercased()].map { Language($0) }
    }

    /// A system language code as one of Lively's, which uses "no" for
    /// Norwegian and "tl" for Filipino.
    static func language(forSystemCode code: String) -> Language {
        switch code.lowercased() {
        case "nb", "nn": Language("no")
        case "fil": Language("tl")
        case "iw": Language("he")
        case "in": Language("id")
        case "yue": .chinese
        default: Language(code.lowercased())
        }
    }

    /// The first language in the system's list, and its Chinese script.
    static var systemLanguage: (language: Language, script: ChineseScript) {
        let preferred = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
        // "zh-HK" has no script of its own; the maximal form adds "Hant".
        let script = Locale.Language(identifier: preferred.maximalIdentifier).script
        let code = preferred.languageCode?.identifier ?? "en"
        return (language(forSystemCode: code), script == .hanTraditional || code == "yue" ? .traditional : .simplified)
    }

    static func name(ofRegion region: String) -> String {
        Locale(identifier: "en").localizedString(forRegionCode: region) ?? region
    }

    private static let traditionalRegions: Set<String> = ["TW", "HK", "MO"]

    /// Country codes by language. Countries whose main language Lively
    /// doesn't have (Iceland, Nepal, Ethiopia…) are left out, and the pair
    /// stays as it is there.
    private static let regionLanguages: [String: String] = {
        let byLanguage: [String: String] = [
            "en": "US GB AU NZ IE CA SG ZA NG GH UG ZW ZM LR SL GM BW NA MW FJ PG MT JM TT BS BB GY BZ "
                + "AG DM GD KN LC VC GI GG JE IM BM KY VG VI GU AS MP",
            "zh": "CN TW HK MO",
            "es": "ES MX AR CO CL PE VE EC GT CU BO DO HN PY SV NI CR PA UY PR GQ",
            "fr": "FR MC LU SN CI ML BF NE TD GN BJ TG CM GA CG CD MG HT DJ CF KM BI GP MQ GF RE PF NC YT BL MF PM WF",
            "pt": "PT BR AO MZ CV GW ST TL",
            "de": "DE AT CH LI",
            "it": "IT SM VA",
            "nl": "NL BE SR AW CW SX BQ",
            "ru": "RU BY KG TJ TM UZ",
            "ar": "SA AE EG IQ JO KW LB LY MA DZ TN OM QA BH YE SY SD PS MR",
            "he": "IL", "fa": "IR AF", "tr": "TR", "el": "GR CY",
            "hi": "IN", "bn": "BD", "ur": "PK",
            "ja": "JP", "ko": "KR KP", "vi": "VN", "th": "TH", "id": "ID", "ms": "MY BN", "tl": "PH",
            "sv": "SE AX", "da": "DK GL FO", "no": "NO SJ", "fi": "FI",
            "pl": "PL", "cs": "CZ", "sk": "SK", "hu": "HU", "ro": "RO MD", "bg": "BG", "hr": "HR",
            "sr": "RS ME", "bs": "BA", "sl": "SI", "mk": "MK", "sq": "AL XK", "uk": "UA",
            "et": "EE", "lv": "LV", "lt": "LT", "az": "AZ", "kk": "KZ", "sw": "TZ KE", "ca": "AD",
        ]
        var table: [String: String] = [:]
        for (language, regions) in byLanguage {
            for region in regions.split(separator: " ") { table[String(region)] = language }
        }
        return table
    }()
}

/// Finds the country the device is in: an approximate fix from Core
/// Location, then MapKit's reverse geocoder.
private final class RegionLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorization: CheckedContinuation<Bool, Never>?
    private var fix: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // The country is all that's needed.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: true
        default: false
        }
    }

    /// Shows the system prompt the first time; afterwards answers at once.
    func requestAuthorization() async -> Bool {
        guard manager.authorizationStatus == .notDetermined else { return isAuthorized }
        return await withCheckedContinuation { continuation in
            authorization?.resume(returning: false)
            authorization = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    /// The ISO 3166 code of the country the device is in, or nil when it
    /// can't be found (no fix, or no network for the geocoder).
    func region() async -> String? {
        #if DEBUG
        // Launch with `-LivelyRegion JP` to stand in for being there.
        if let region = UserDefaults.standard.string(forKey: "LivelyRegion") { return region.uppercased() }
        #endif
        let location = await withCheckedContinuation { continuation in
            fix?.resume(returning: nil)
            fix = continuation
            manager.requestLocation()
        }
        guard let location, let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items = try? await request.mapItems
        return items?.first?.addressRepresentations?.region?.identifier.uppercased()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        authorization?.resume(returning: isAuthorized)
        authorization = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        fix?.resume(returning: locations.last)
        fix = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        fix?.resume(returning: nil)
        fix = nil
    }
}
