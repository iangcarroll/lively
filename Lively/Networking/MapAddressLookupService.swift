import Foundation
import MapKit

/// Looks up map data without using the conversation or speech providers.
@MainActor
final class MapAddressLookupService: AddressLookupProviding {
    private struct Candidate {
        let item: MKMapItem
        let place: AddressPlace
        let address: String
        let query: String
        let language = AddressLanguage.matching(Locale.current.language.maximalIdentifier)
    }

    private struct CacheKey: Hashable {
        let placeID: String
        let languageCode: String
    }

    private var operation = UUID()
    private var activeSearch: MKLocalSearch?
    private var activeGeocoder: MKGeocodingRequest?
    private var candidates: [String: Candidate] = [:]
    private var localizedAddresses: [CacheKey: String] = [:]
    private var cacheOrder: [CacheKey] = []
    private let maximumPlaces = 12
    private let maximumCachedAddresses = 24

    func cancel() {
        operation = UUID()
        activeSearch?.cancel()
        activeSearch = nil
        activeGeocoder?.cancel()
        activeGeocoder = nil
    }

    func findPlaces(matching query: String) async throws -> [AddressPlace] {
        cancel()
        candidates.removeAll()
        localizedAddresses.removeAll()
        cacheOrder.removeAll()
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 1_000 else { return [] }
        let token = operation

        return try await withTaskCancellationHandler {
            var items: [MKMapItem] = []
            var failures: [AddressLookupError] = []
            // A combined request can return an area instead of a matching landmark.
            for type: MKLocalSearch.ResultType in [.pointOfInterest, .address] {
                try checkCurrent(token)
                let request = MKLocalSearch.Request(naturalLanguageQuery: input)
                request.resultTypes = type
                let search = MKLocalSearch(request: request)
                activeSearch = search
                let timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(20)) }
                    catch { return }
                    search.cancel()
                }
                do {
                    let response = try await search.start()
                    timeout.cancel()
                    try checkCurrent(token)
                    items.append(contentsOf: response.mapItems.prefix(maximumPlaces))
                } catch {
                    timeout.cancel()
                    try checkCurrent(token)
                    if !isNoResult(error) { failures.append(mapped(error)) }
                }
                if activeSearch === search { activeSearch = nil }
            }
            try checkCurrent(token)

            var seen = Set<String>()
            let ranked = items.enumerated().sorted {
                let left = relevance($0.element, query: input)
                let right = relevance($1.element, query: input)
                return left == right ? $0.offset < $1.offset : left > right
            }
            var places: [AddressPlace] = []
            for (_, item) in ranked {
                let coordinate = item.location.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
                let address = formattedAddress(item)
                let name = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !address.isEmpty || !name.isEmpty else { continue }
                let identity = item.identifier?.rawValue ?? "\(name)|\(coordinate.latitude)|\(coordinate.longitude)"
                guard seen.insert(identity).inserted else { continue }
                let place = AddressPlace(
                    id: UUID().uuidString,
                    name: name.isEmpty ? address : name,
                    subtitle: address,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    countryCode: item.addressRepresentations?.region?.identifier
                )
                candidates[place.id] = Candidate(item: item, place: place, address: address, query: input)
                places.append(place)
                if places.count == maximumPlaces { break }
            }
            if places.isEmpty, let failure = failures.first { throw failure }
            return places
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(ifCurrent: token) }
        }
    }

    func address(for place: AddressPlace, language: AddressLanguage) async throws -> String {
        guard let candidate = candidates[place.id], candidate.place == place else {
            throw AddressLookupError.expiredSelection
        }
        cancel()
        let token = operation
        let key = CacheKey(placeID: place.id, languageCode: language.code)
        try Task.checkCancellation()
        if let cached = localizedAddresses[key] { return cached }
        guard !candidate.address.isEmpty else { throw AddressLookupError.missingAddress }
        // Local search already supplies an address in the device's Maps locale.
        // Re-geocoding it can lose details or return another locale's cached text.
        if language == candidate.language, supportsRequestedScript(candidate.address, language: language) {
            return candidate.address
        }

        return try await withTaskCancellationHandler {
            // Forward lookup preserves an area's address. Reverse lookup of a city
            // centroid can incorrectly turn it into a nearby building's address.
            for query in geocodingQueries(for: candidate, language: language) {
                try checkCurrent(token)
                guard let request = MKGeocodingRequest(addressString: query) else { continue }
                request.region = MKCoordinateRegion(
                    center: candidate.item.location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
                request.preferredLocale = geocodingLocale(for: language, countryCode: candidate.place.countryCode)
                activeGeocoder = request
                let timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(20)) }
                    catch { return }
                    request.cancel()
                }
                defer {
                    timeout.cancel()
                    if activeGeocoder === request { activeGeocoder = nil }
                }
                let items: [MKMapItem]
                do { items = try await request.mapItems }
                catch {
                    try checkCurrent(token)
                    if isNoResult(error) { continue }
                    throw mapped(error)
                }
                try checkCurrent(token)
                for item in items {
                    let result = formattedAddress(item)
                    guard !result.isEmpty,
                          representsSameAddress(item, text: result, as: candidate),
                          supportsRequestedScript(result, language: language) else { continue }
                    localizedAddresses[key] = result
                    cacheOrder.append(key)
                    while cacheOrder.count > maximumCachedAddresses {
                        localizedAddresses.removeValue(forKey: cacheOrder.removeFirst())
                    }
                    return result
                }
            }
            throw AddressLookupError.missingAddress
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(ifCurrent: token) }
        }
    }

    private func cancel(ifCurrent token: UUID) {
        if operation == token { cancel() }
    }

    private func checkCurrent(_ token: UUID) throws {
        guard operation == token, !Task.isCancelled else { throw CancellationError() }
    }

    private func formattedAddress(_ item: MKMapItem) -> String {
        let value = item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: false)
            ?? item.address?.fullAddress ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func geocodingQueries(for source: Candidate, language: AddressLanguage) -> [String] {
        // Maps may fail to parse its own formatted address even when the user's
        // original street-address query resolves fully. Both must pass the same
        // destination and number checks before becoming a result.
        let original = [source.address, source.query]
        var localized: [String] = []
        if let countryCode = source.place.countryCode,
           let country = language.locale.localizedString(forRegionCode: countryCode) {
            let names = [source.item.addressRepresentations?.regionName,
                         Locale(identifier: "en").localizedString(forRegionCode: countryCode)].compactMap { $0 }
            for query in original {
                for name in names where name != country {
                    // Change a country component, never words in a street or venue name.
                    let pattern = "(?:^|[,\\n、])\\s*(" + NSRegularExpression.escapedPattern(for: name)
                        + ")(?=\\s*(?:[,\\n、]|$|〒|\\p{Nd}))"
                    guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                          let match = expression.matches(in: query, range: NSRange(query.startIndex..., in: query)).last,
                          let range = Range(match.range(at: 1), in: query) else { continue }
                    var value = query
                    value.replaceSubrange(range, with: country)
                    localized.append(value)
                    break
                }
            }
        }
        var seen = Set<String>()
        return (localized + original).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func geocodingLocale(for language: AddressLanguage, countryCode: String?) -> Locale {
        guard let countryCode else { return language.locale }
        return Locale(identifier: "\(language.code)-\(countryCode)")
    }

    private func supportsRequestedScript(_ text: String, language: AddressLanguage) -> Bool {
        guard let script = language.locale.language.script?.identifier else { return true }
        let scripts: [String]
        switch script {
        case "Jpan": scripts = ["Han", "Hiragana", "Katakana"]
        case "Hans", "Hant": scripts = ["Han"]
        case "Kore": scripts = ["Hangul", "Han"]
        default: scripts = [script]
        }
        // A locale hint can still yield fallback text. Require a letter from the
        // requested script before presenting a non-Latin-language result.
        let alternatives = scripts.map { "\\p{sc=\($0)}" }.joined(separator: "|")
        return text.range(of: "(?=\\p{L})(?:\(alternatives))", options: .regularExpression) != nil
    }

    private func representsSameAddress(_ item: MKMapItem, text: String, as source: Candidate) -> Bool {
        guard let country = source.place.countryCode,
              item.addressRepresentations?.region?.identifier == country,
              CLLocationCoordinate2DIsValid(item.location.coordinate),
              isWithinLocationTolerance(item.location.distance(from: source.item.location), sourceAddress: source.address) else { return false }
        // Preserve the numbers supplied by Maps, including postal codes and units.
        // Added or dropped numbers may identify a different address or precision.
        return numberParts(text) == numberParts(source.address)
    }

    private func isWithinLocationTolerance(_ distance: Double, sourceAddress: String) -> Bool {
        guard distance.isFinite, distance >= 0 else { return false }
        // Numbered addresses need a tight match. Unnumbered areas can have a
        // representative point away from the selected landmark's own pin.
        let limit = numberParts(sourceAddress).isEmpty ? 500.0 : 50.0
        return distance <= limit
    }

    private func numberParts(_ text: String) -> [String] {
        var parts: [String] = []
        var digits = ""
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .decimalNumber,
               let value = scalar.properties.numericValue {
                digits += String(Int(value))
            } else if !digits.isEmpty {
                parts.append(digits)
                digits = ""
            }
        }
        if !digits.isEmpty { parts.append(digits) }
        return parts.sorted()
    }

    private func relevance(_ item: MKMapItem, query: String) -> Double {
        func words(_ text: String) -> Set<String> {
            Set(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
                .split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let input = words(query)
        let name = words(item.name ?? "")
        guard !input.isEmpty, !name.isEmpty else { return 0 }
        let common = Double(input.intersection(name).count)
        return 10 * common / Double(input.count) + 5 * common / Double(name.count)
    }

    private func isNoResult(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == MKErrorDomain && nsError.code == MKError.placemarkNotFound.rawValue
    }

    private func mapped(_ error: Error) -> AddressLookupError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .network }
        if nsError.domain == MKErrorDomain, nsError.code == MKError.loadingThrottled.rawValue { return .rateLimited }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain { return .network }
        return .unavailable
    }
}
