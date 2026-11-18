import Foundation

// Compiled beside the unchanged production sources in a temporary test binary.
// Capturing the actual task lets late-response checks wait for its completion,
// without timing assumptions or production test hooks.
extension AddressLookupStore {
    fileprivate var regressionTask: Task<Void, Never>? { work }
}

@MainActor
final class AddressServiceStub: AddressLookupProviding {
    struct AddressRequest {
        let place: AddressPlace
        let language: AddressLanguage
    }

    private(set) var searches: [String] = []
    private(set) var addresses: [AddressRequest] = []
    private(set) var cancelCount = 0
    private var pendingSearches: [Int: CheckedContinuation<[AddressPlace], Error>] = [:]
    private var pendingAddresses: [Int: CheckedContinuation<String, Error>] = [:]
    private var searchWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var addressWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func findPlaces(matching query: String) async throws -> [AddressPlace] {
        let index = searches.count
        searches.append(query)
        return try await withCheckedThrowingContinuation { continuation in
            pendingSearches[index] = continuation
            searchWaiters.removeValue(forKey: index)?.resume()
        }
    }

    func address(for place: AddressPlace, language: AddressLanguage) async throws -> String {
        let index = addresses.count
        addresses.append(AddressRequest(place: place, language: language))
        return try await withCheckedThrowingContinuation { continuation in
            pendingAddresses[index] = continuation
            addressWaiters.removeValue(forKey: index)?.resume()
        }
    }

    // Deliberately ignores cancellation. The store must independently reject
    // responses from operations that have been replaced or dismissed.
    func cancel() { cancelCount += 1 }

    func waitForSearch(_ index: Int) async {
        guard pendingSearches[index] == nil else { return }
        await withCheckedContinuation { searchWaiters[index] = $0 }
    }

    func waitForAddress(_ index: Int) async {
        guard pendingAddresses[index] == nil else { return }
        await withCheckedContinuation { addressWaiters[index] = $0 }
    }

    func finishSearch(_ index: Int, _ result: Result<[AddressPlace], Error>) {
        guard let continuation = pendingSearches.removeValue(forKey: index) else {
            fatalError("No pending search at index \(index)")
        }
        continuation.resume(with: result)
    }

    func finishAddress(_ index: Int, _ result: Result<String, Error>) {
        guard let continuation = pendingAddresses.removeValue(forKey: index) else {
            fatalError("No pending localization at index \(index)")
        }
        continuation.resume(with: result)
    }

    var pendingCount: Int { pendingSearches.count + pendingAddresses.count }
}

@main
@MainActor
struct AddressLookupRegression {
    static var assertions = 0
    static var failures = 0

    static let japanese = AddressLanguage(code: "ja")
    static let english = AddressLanguage(code: "en")
    static let station = AddressPlace(id: "tokyo-station", name: "Tokyo Station",
        subtitle: "Chiyoda, Tokyo, Japan", latitude: 35.681236, longitude: 139.767125, countryCode: "JP")
    static let museum = AddressPlace(id: "tokyo-museum", name: "Tokyo National Museum",
        subtitle: "Taito, Tokyo, Japan", latitude: 35.718835, longitude: 139.776527, countryCode: "JP")
    static let japaneseAddress = "〒100-0005\n東京都千代田区丸の内1丁目9−1"

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
            if CommandLine.arguments.contains("--fail-fast") { exit(1) }
        }
    }

    static func task(_ store: AddressLookupStore) -> Task<Void, Never> {
        guard let task = store.regressionTask else { fatalError("Expected an active lookup task") }
        return task
    }

    static func search(_ store: AddressLookupStore, _ service: AddressServiceStub,
                       query: String = "Tokyo", places: [AddressPlace] = [station, museum]) async {
        let index = service.searches.count
        store.query = query
        store.find()
        let work = task(store)
        await service.waitForSearch(index)
        service.finishSearch(index, .success(places))
        await work.value
    }

    static func resolve(_ store: AddressLookupStore, _ service: AddressServiceStub,
                        place: AddressPlace = station, address: String = japaneseAddress) async {
        let index = service.addresses.count
        store.select(place)
        let work = task(store)
        await service.waitForAddress(index)
        service.finishAddress(index, .success(address))
        await work.value
    }

    static func languagePreferences() {
        let codes = AddressLanguage.all.map(\.code)
        check(Set(codes).count == codes.count, "address language identifiers are unique")
        check(codes.contains("ja") && codes.contains("en"), "Japanese and English are available independently of speech settings")
        check(codes.contains("zh-Hans") && codes.contains("zh-Hant") && !codes.contains("zh"), "both Chinese scripts have explicit selections")
        check(AddressLanguage.matching("ja_JP") == japanese, "regional Japanese preference resolves to Japanese")
        check(AddressLanguage.matching("EN-us") == english, "case and locale separators are normalized")
        for code in ["zh", "zh-CN", "zh_SG", "zh-Hans", "zh-Hans-HK", "zh-Hans-TW"] {
            check(AddressLanguage.matching(code).code == "zh-Hans", "simplified script is retained for \(code)")
        }
        for code in ["zh-TW", "zh_HK", "zh-MO", "zh-Hant", "zh-Hant-CN"] {
            check(AddressLanguage.matching(code).code == "zh-Hant", "traditional script is retained for \(code)")
        }
        for code in ["", "zz-ZZ", "not-a-language", "../invalid"] {
            check(AddressLanguage.matching(code) == english, "invalid saved language falls back safely: \(code)")
        }
        check(AddressLanguage(code: "zh-Hans").locale.identifier != AddressLanguage(code: "zh-Hant").locale.identifier,
              "script selections produce distinct locale requests")
        let first = AddressLookupStore(service: AddressServiceStub(), language: japanese)
        let second = AddressLookupStore(service: AddressServiceStub(), language: english)
        first.language = AddressLanguage(code: "zh-Hant")
        check(first.language.code == "zh-Hant" && second.language == english,
              "changing one lookup's language does not mutate another lookup")
    }

    static func inputValidation() async {
        let service = AddressServiceStub()
        let store = AddressLookupStore(service: service, language: japanese)
        check(store.phase == .idle && !store.isBusy && !store.canSearch && store.copyValue == nil, "initial lookup has no actionable result")
        for input in ["", " \t\r\n\u{00a0}\u{3000}"] {
            store.query = input
            store.find()
            check(service.searches.isEmpty && store.phase == .idle && store.errorMessage == nil, "empty input does not contact the service")
        }
        for input in [String(repeating: "東", count: 1_001), "https://maps.apple.com/?q=Tokyo", "  HTTPS://maps.example/location  ", "http://example.com/map"] {
            store.query = input
            store.find()
            check(service.searches.isEmpty && !store.isBusy && store.copyValue == nil && store.errorMessage != nil,
                  "oversized input and links are rejected before a request")
        }
        await search(store, service, query: " \t〒100-0005\n東京都千代田区\r\n丸の内1丁目9−1\u{3000} ", places: [station])
        check(service.searches == ["〒100-0005 東京都千代田区 丸の内1丁目9−1"], "normalization preserves Unicode address content and joins multiline whitespace")
        check(store.phase == .choosing && store.selectedPlace == nil && service.addresses.isEmpty,
              "finding a place does not silently localize or select a candidate")
        store.query = String(repeating: "a", count: 1_000)
        store.find()
        let work = task(store)
        await service.waitForSearch(1)
        check(service.searches[1].count == 1_000, "the documented input boundary is accepted")
        service.finishSearch(1, .success([]))
        await work.value
        check(service.pendingCount == 0, "input validation leaves no pending operations")
    }

    static func selectionAndCopy() async {
        let service = AddressServiceStub()
        let store = AddressLookupStore(service: service, language: japanese)
        await search(store, service)
        check(store.matches == [station, museum] && store.selectedPlace == nil && store.copyValue == nil,
              "ambiguous results are retained for explicit choice")
        let forged = AddressPlace(id: station.id, name: station.name, subtitle: station.subtitle,
            latitude: station.latitude + 1, longitude: station.longitude, countryCode: station.countryCode)
        store.select(forged)
        check(store.selectedPlace == nil && store.phase == .choosing && service.addresses.isEmpty,
              "a forged candidate with a reused identifier cannot be selected")
        await resolve(store, service, address: " \n\(japaneseAddress)\n ")
        check(service.addresses[0].place == station && service.addresses[0].language == japanese,
              "localization receives the exact selected place and independent language")
        check(store.phase == .resolved && store.address == japaneseAddress && store.copyValue == japaneseAddress,
              "copy preserves the entire displayed multiline native address")
        check(store.selectedPlace?.latitude == station.latitude && store.selectedPlace?.longitude == station.longitude,
              "localization does not replace the selected map coordinates")
        let cancels = service.cancelCount
        store.query = "Kyoto"
        check(service.cancelCount > cancels && store.phase == .idle && store.matches.isEmpty && store.selectedPlace == nil && store.copyValue == nil,
              "editing the query invalidates the previous selection and copy value")
        store.select(station)
        check(service.addresses.count == 1 && store.selectedPlace == nil,
              "a previously valid candidate is rejected after the query changes")
        check(service.pendingCount == 0, "selection checks complete every service operation")
    }

    static func coordinateValidationAndResultLimit() async {
        func place(_ id: String, _ latitude: Double, _ longitude: Double) -> AddressPlace {
            AddressPlace(id: id, name: id, subtitle: "Coordinate validation fixture",
                         latitude: latitude, longitude: longitude, countryCode: nil)
        }
        let invalidCoordinates: [(Double, Double)] = [
            (.nan, 0), (0, .nan), (.infinity, 0), (-.infinity, 0),
            (0, .infinity), (0, -.infinity), (90.0001, 0), (-90.0001, 0),
            (0, 180.0001), (0, -180.0001),
        ]
        let invalid = invalidCoordinates.enumerated().map { index, coordinate in
            place("invalid-\(index)", coordinate.0, coordinate.1)
        }
        for candidate in invalid {
            check(!candidate.hasValidCoordinate, "non-finite or out-of-range coordinates are invalid: \(candidate.id)")
        }
        let valid = [place("zero", 0, 0), place("minimum", -90, -180), place("maximum", 90, 180)]
            + (0..<9).map { place("valid-\($0)", Double($0), Double($0)) }
        for candidate in valid {
            check(candidate.hasValidCoordinate, "finite in-range coordinates remain valid: \(candidate.id)")
        }
        let service = AddressServiceStub()
        let store = AddressLookupStore(service: service, language: english)
        // More than eight invalid entries come first, so the cap must be applied
        // after filtering; otherwise valid results would disappear entirely.
        await search(store, service, query: "Coordinate fixtures", places: invalid + valid)
        check(store.matches == Array(valid.prefix(8)) && store.phase == .choosing && store.errorMessage == nil,
              "the first eight valid places survive in provider order after invalid coordinates are filtered")
        check(store.matches.count == 8 && store.matches.allSatisfy(\.hasValidCoordinate),
              "the result list is bounded and safe to present on a map")
        store.select(valid[8])
        check(store.selectedPlace == nil && service.addresses.isEmpty,
              "a provider result outside the displayed limit cannot be selected")
        await resolve(store, service, place: valid[0], address: "Equator, Atlantic Ocean")
        check(store.selectedPlace?.latitude == 0 && store.selectedPlace?.longitude == 0
              && store.copyValue == "Equator, Atlantic Ocean",
              "zero coordinates are a valid selected location, not a missing-data sentinel")
        await search(store, service, query: "Invalid coordinates only", places: invalid)
        check(store.phase == .idle && store.matches.isEmpty && store.selectedPlace == nil
              && store.errorMessage != nil && store.copyValue == nil,
              "a response containing only invalid coordinates becomes a recoverable no-results state")
        check(service.pendingCount == 0, "coordinate validation leaves no unfinished operations")
    }

    static func outOfOrderSearches() async {
        let service = AddressServiceStub()
        let store = AddressLookupStore(service: service, language: japanese)
        store.query = "Old query"
        store.find()
        let old = task(store)
        await service.waitForSearch(0)
        store.query = "New query"
        store.find()
        let current = task(store)
        await service.waitForSearch(1)
        service.finishSearch(1, .success([museum]))
        await current.value
        service.finishSearch(0, .success([station]))
        await old.value
        check(store.matches == [museum] && store.phase == .choosing && store.errorMessage == nil,
              "a late ignored-cancellation search cannot replace newer matches")
        store.query = "Old failing query"
        store.find()
        let failing = task(store)
        await service.waitForSearch(2)
        store.query = "Newest query"
        store.find()
        let newest = task(store)
        await service.waitForSearch(3)
        service.finishSearch(3, .success([station]))
        await newest.value
        service.finishSearch(2, .failure(AddressLookupError.network))
        await failing.value
        check(store.matches == [station] && store.phase == .choosing && store.errorMessage == nil,
              "an obsolete search failure cannot replace newer success")
        check(service.pendingCount == 0, "out-of-order searches leave no unresolved requests")
    }

    static func outOfOrderLocalizations() async {
        let service = AddressServiceStub()
        let store = AddressLookupStore(service: service, language: japanese)
        await search(store, service)
        store.select(station)
        let firstPlace = task(store)
        await service.waitForAddress(0)
        store.select(museum)
        let secondPlace = task(store)
        await service.waitForAddress(1)
        service.finishAddress(1, .success("東京都台東区上野公園13−9"))
        await secondPlace.value
        service.finishAddress(0, .success(japaneseAddress))
        await firstPlace.value
        check(store.selectedPlace == museum && store.address == "東京都台東区上野公園13−9",
              "late localization cannot attach another place's address to the selection")
        let cancels = service.cancelCount
        store.language = english
        let englishRequest = task(store)
        check(service.cancelCount > cancels && store.copyValue == nil && store.phase == .localizing,
              "changing language cancels work and clears the previous-language copy value immediately")
        await service.waitForAddress(2)
        check(service.addresses[2].language == english && service.addresses[2].place == museum,
              "language changes retain the selected place")
        store.language = AddressLanguage(code: "zh-Hant")
        let traditionalRequest = task(store)
        await service.waitForAddress(3)
        check(service.addresses[3].language.code == "zh-Hant", "traditional Chinese reaches the service without speech-provider substitution")
        service.finishAddress(3, .success("日本東京都台東區上野公園13−9"))
        await traditionalRequest.value
        service.finishAddress(2, .failure(AddressLookupError.network))
        await englishRequest.value
        check(store.copyValue == "日本東京都台東區上野公園13−9" && store.errorMessage == nil && store.selectedPlace == museum,
              "an obsolete language failure cannot erase the current address")
        store.language = japanese
        let abandoned = task(store)
        await service.waitForAddress(4)
        store.language = english
        let replacement = task(store)
        await service.waitForAddress(5)
        service.finishAddress(5, .success("13-9 Uenokoen, Taito City, Tokyo, Japan"))
        await replacement.value
        service.finishAddress(4, .success("OLD JAPANESE ADDRESS"))
        await abandoned.value
        check(store.copyValue == "13-9 Uenokoen, Taito City, Tokyo, Japan" && store.language == english,
              "an obsolete language success cannot overwrite the current language result")
        check(service.pendingCount == 0, "all localization race requests complete")
    }

    static func languageChangeDuringSearch() async {
        let service = AddressServiceStub()
        let store = AddressLookupStore(service: service, language: japanese)
        store.query = "Tokyo"
        store.find()
        let old = task(store)
        await service.waitForSearch(0)
        let cancels = service.cancelCount
        store.language = english
        check(service.cancelCount > cancels && store.phase == .idle && store.copyValue == nil,
              "language change while searching releases the old busy state")
        service.finishSearch(0, .success([station]))
        await old.value
        check(store.matches.isEmpty && store.selectedPlace == nil && store.language == english,
              "a search started before a language change cannot restore stale selection state")
        await search(store, service, query: "Tokyo", places: [station])
        let calls = service.addresses.count
        store.language = japanese
        check(store.matches == [station] && store.phase == .choosing && service.addresses.count == calls,
              "changing language before selection keeps the choices without starting speech or localization")
        await resolve(store, service)
        check(store.copyValue == japaneseAddress, "lookup still works after an interrupted search")
    }

    static func queryChangeDuringLocalization() async {
        let service = AddressServiceStub()
        let store = AddressLookupStore(service: service, language: japanese)
        await search(store, service, places: [station])
        store.select(station)
        let old = task(store)
        await service.waitForAddress(0)
        let cancels = service.cancelCount
        store.query = "Tokyo National Museum"
        check(service.cancelCount > cancels && store.phase == .idle && store.matches.isEmpty
              && store.selectedPlace == nil && store.copyValue == nil,
              "editing during localization cancels work and removes the old result's actions")
        store.select(station)
        check(service.addresses.count == 1 && store.selectedPlace == nil,
              "the old place cannot be selected while a replacement query is pending")
        await search(store, service, query: "Tokyo National Museum", places: [museum])
        await resolve(store, service, place: museum, address: "東京都台東区上野公園13−9")
        service.finishAddress(0, .success(japaneseAddress))
        await old.value
        check(store.selectedPlace == museum && store.matches == [museum]
              && store.copyValue == "東京都台東区上野公園13−9",
              "a previous query's localization cannot overwrite its replacement's address")
        check(service.pendingCount == 0, "replacement queries complete all suspended operations")
    }

    static func failuresAndRetry() async {
        let service = AddressServiceStub()
        let store = AddressLookupStore(service: service, language: japanese)
        await search(store, service, places: [])
        check(store.phase == .idle && !store.isBusy && store.errorMessage != nil && store.copyValue == nil,
              "no results produces a recoverable empty state")
        store.retry()
        let retry = task(store)
        await service.waitForSearch(1)
        check(store.phase == .searching && store.errorMessage == nil && service.searches[1] == "Tokyo",
              "retry repeats the query and clears its previous error")
        service.finishSearch(1, .failure(AddressLookupError.network))
        await retry.value
        check(store.phase == .idle && store.errorMessage == AddressLookupError.network.errorDescription,
              "network search failure is visible without a stuck spinner")
        store.retry()
        let searchRetry = task(store)
        await service.waitForSearch(2)
        service.finishSearch(2, .success([station]))
        await searchRetry.value
        store.select(station)
        let missing = task(store)
        await service.waitForAddress(0)
        service.finishAddress(0, .success(" \n\t "))
        await missing.value
        check(store.phase == .choosing && store.copyValue == nil && store.errorMessage == AddressLookupError.missingAddress.errorDescription,
              "an empty provider address is not exposed as a successful result")
        store.retry()
        let localizationRetry = task(store)
        await service.waitForAddress(1)
        check(store.errorMessage == nil && service.addresses[1].place == station && service.addresses[1].language == japanese,
              "localization retry keeps the exact selection and language")
        service.finishAddress(1, .success(japaneseAddress))
        await localizationRetry.value
        check(store.phase == .resolved && store.copyValue == japaneseAddress && store.errorMessage == nil,
              "a successful retry restores a usable address")
        store.query = "Failure"
        store.find()
        let unknown = task(store)
        await service.waitForSearch(3)
        service.finishSearch(3, .failure(NSError(domain: "private-provider-detail", code: 99,
            userInfo: [NSLocalizedDescriptionKey: "DO NOT DISPLAY provider internals"])))
        await unknown.value
        check(store.errorMessage != nil && !store.errorMessage!.contains("provider internals") && !store.isBusy,
              "unknown failures do not expose provider internals")
        check(service.pendingCount == 0, "error and retry paths complete every request")
    }

    static func cancellationAndDismissal() async {
        let service = AddressServiceStub()
        let store = AddressLookupStore(service: service, language: japanese)
        store.query = "Tokyo"
        store.find()
        let searchWork = task(store)
        await service.waitForSearch(0)
        let searchCancels = service.cancelCount
        store.close()
        check(service.cancelCount > searchCancels && store.phase == .idle && store.copyValue == nil && store.errorMessage == nil,
              "dismissal cancels the underlying search and clears display state")
        service.finishSearch(0, .success([station]))
        await searchWork.value
        check(store.matches.isEmpty && store.selectedPlace == nil && store.phase == .idle,
              "a dismissed search cannot repopulate the sheet")
        await search(store, service, places: [station])
        store.select(station)
        let addressWork = task(store)
        await service.waitForAddress(0)
        let addressCancels = service.cancelCount
        store.close()
        check(service.cancelCount > addressCancels && store.selectedPlace == nil && store.address == nil && store.copyValue == nil,
              "dismissal cancels localization and clears the selected place and address")
        service.finishAddress(0, .failure(AddressLookupError.network))
        await addressWork.value
        check(store.phase == .idle && store.errorMessage == nil && store.copyValue == nil,
              "a dismissed localization error cannot leak into a later visit")
        store.find()
        let cancelledSearch = task(store)
        await service.waitForSearch(2)
        service.finishSearch(2, .failure(CancellationError()))
        await cancelledSearch.value
        check(store.phase == .idle && !store.isBusy && store.errorMessage == nil, "current search cancellation is silent and recoverable")
        await search(store, service, places: [station])
        store.select(station)
        let cancelledAddress = task(store)
        await service.waitForAddress(1)
        service.finishAddress(1, .failure(CancellationError()))
        await cancelledAddress.value
        check(store.phase == .choosing && !store.isBusy && store.errorMessage == nil && store.copyValue == nil,
              "current localization cancellation returns to selection without a false address")
        await resolve(store, service)
        check(store.copyValue == japaneseAddress, "the sheet can resolve a new address after cancellations")
        store.close()
        check(store.copyValue == nil && service.pendingCount == 0, "closing a completed lookup clears its copy value")
    }

    static func main() async {
        languagePreferences()
        await inputValidation()
        await selectionAndCopy()
        await coordinateValidationAndResultLimit()
        await outOfOrderSearches()
        await outOfOrderLocalizations()
        await languageChangeDuringSearch()
        await queryChangeDuringLocalization()
        await failuresAndRetry()
        await cancellationAndDismissal()
        print("Address lookup regressions: \(assertions) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
