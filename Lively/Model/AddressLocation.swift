import Foundation

/// The lookup language is independent of the conversation and speech provider.
nonisolated struct AddressLanguage: Hashable, Identifiable, Sendable {
    let code: String
    var id: String { code }
    var locale: Locale { Locale(identifier: code) }

    var englishName: String {
        switch code {
        case "zh-Hans": "Chinese (Simplified)"
        case "zh-Hant": "Chinese (Traditional)"
        default: Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        }
    }

    var nativeName: String {
        switch code {
        case "zh-Hans": "简体中文"
        case "zh-Hant": "繁體中文"
        default: locale.localizedString(forLanguageCode: code) ?? englishName
        }
    }

    static let all: [AddressLanguage] = {
        var codes = Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
            .filter { $0.count == 2 && $0 != "zh" }
        codes += ["zh-Hans", "zh-Hant"]
        return Set(codes).map { AddressLanguage(code: $0) }
            .sorted { $0.englishName.localizedStandardCompare($1.englishName) == .orderedAscending }
    }()

    static func matching(_ code: String) -> AddressLanguage {
        let normalized = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized == "zh" || normalized.hasPrefix("zh-") {
            let traditional = !normalized.contains("hans") && (normalized.contains("hant") || ["tw", "hk", "mo"].contains(normalized.split(separator: "-").last.map(String.init) ?? ""))
            return AddressLanguage(code: traditional ? "zh-Hant" : "zh-Hans")
        }
        let base = normalized.split(separator: "-").first.map(String.init) ?? ""
        return all.first { $0.code == normalized || $0.code == base } ?? AddressLanguage(code: "en")
    }
}

/// Only the selected map location is opened; localization cannot replace it.
nonisolated struct AddressPlace: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
    let countryCode: String?

    var hasValidCoordinate: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

nonisolated enum AddressLookupError: Error, LocalizedError {
    case unavailable, network, rateLimited, missingAddress, expiredSelection

    var errorDescription: String? {
        switch self {
        case .unavailable: "Address lookup is unavailable right now. Try again."
        case .network: "Connect to the internet to look up an address."
        case .rateLimited: "Address lookup is busy. Wait a moment, then try again."
        case .missingAddress: "An address in this language wasn’t available for this place. Try another language or a more specific address."
        case .expiredSelection: "Search again to choose this place."
        }
    }
}

@MainActor
protocol AddressLookupProviding: AnyObject {
    func findPlaces(matching query: String) async throws -> [AddressPlace]
    func address(for place: AddressPlace, language: AddressLanguage) async throws -> String
    func cancel()
}
