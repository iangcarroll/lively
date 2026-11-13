import Foundation

struct Language: Hashable, Sendable {
    let rawValue: String
    var englishName: String { rawValue }
    static let english = Self(rawValue: "en")
    static let french = Self(rawValue: "fr")
}
struct LanguagePair: Sendable {
    let first: Language
    let second: Language
    var all: [Language] { [first, second] }
}
enum ChineseScript: Sendable { case simplified }
enum OfflineSpeechEngine {
    static func locale(for language: Language, script: ChineseScript) -> Locale {
        Locale(identifier: language.rawValue)
    }
    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }
}
nonisolated enum AppleTranslator {
    static func language(_ language: Language, script: ChineseScript) -> Locale.Language {
        Locale.Language(identifier: language.rawValue)
    }
}
enum Injected: Error { case quota, download }

final class SpeechTranscriber {
    enum Preset { case progressiveTranscription }
    static var isAvailable = true
    static var unsupported: Set<String> = []
    let locale: Locale
    init(locale: Locale, preset: Preset) { self.locale = locale }
    static func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        unsupported.contains(locale.identifier) ? nil : locale
    }
}
enum AssetInventory {
    enum Status { case unsupported, supported, downloading, installed }
    static var statuses: [String: Status] = [:]
    static var reserved: [Locale] = []
    static var reserveCalls: [Locale] = []
    static var throwQuota = false
    static var completeDownload = true
    static var downloadCalls = 0
    static var installationRequests = 0
    static var suspendReserve = false
    static var pendingReserve: CheckedContinuation<Void, Never>?
    static var suspendRequest = false
    static var pendingRequest: CheckedContinuation<Void, Never>?
    static var reservedLocales: [Locale] { get async { reserved } }
    static func status(forModules modules: [SpeechTranscriber]) async -> Status {
        statuses[modules[0].locale.identifier] ?? .supported
    }
    @discardableResult static func reserve(locale: Locale) async throws -> Bool {
        reserveCalls.append(locale)
        if suspendReserve { await withCheckedContinuation { pendingReserve = $0 } }
        if throwQuota { throw Injected.quota }
        if reserved.contains(locale) { return false }
        reserved.append(locale)
        return true
    }
    @discardableResult static func release(reservedLocale locale: Locale) async -> Bool {
        reserved.removeAll { $0 == locale }
        return true
    }
    static func assetInstallationRequest(supporting modules: [SpeechTranscriber]) async throws -> AssetInstallationRequest? {
        let locale = modules[0].locale
        installationRequests += 1
        let installed = statuses[locale.identifier] == .installed
        if suspendRequest { await withCheckedContinuation { pendingRequest = $0 } }
        return installed ? nil : AssetInstallationRequest(locale: locale)
    }
    static func reset(installed: Bool = false) {
        statuses = ["en": installed ? .installed : .supported, "fr": installed ? .installed : .supported]
        reserved = []; reserveCalls = []; throwQuota = false; completeDownload = true; downloadCalls = 0
        installationRequests = 0; suspendReserve = false; pendingReserve = nil
        suspendRequest = false; pendingRequest = nil
        SpeechTranscriber.isAvailable = true; SpeechTranscriber.unsupported = []
    }
}
final class AssetInstallationRequest {
    let locale: Locale
    init(locale: Locale) { self.locale = locale }
    func downloadAndInstall() async throws {
        AssetInventory.downloadCalls += 1
        if AssetInventory.completeDownload { AssetInventory.statuses[locale.identifier] = .installed }
    }
}
nonisolated final class LanguageAvailability: @unchecked Sendable {
    enum Status { case installed, supported, unsupported }
    @MainActor static var statuses: [String: Status] = [:]
    @MainActor static var suspendKey: String?
    @MainActor static var pendingStatus: [CheckedContinuation<Status, Never>] = []
    init() {}
    init(preferredStrategy: TranslationSession.Strategy) {}
    static func key(_ source: Locale.Language, _ target: Locale.Language) -> String {
        source.languageCode!.identifier + ">" + target.languageCode!.identifier
    }
    @MainActor func status(from source: Locale.Language, to target: Locale.Language?) async -> Status {
        let key = Self.key(source, target!)
        if Self.suspendKey == key {
            return await withCheckedContinuation { Self.pendingStatus.append($0) }
        }
        return Self.statuses[key] ?? .supported
    }
}
final class TranslationSession: @unchecked Sendable {
    nonisolated struct Strategy: Equatable { static let lowLatency = Self() }
    struct Configuration: Equatable {
        let source: Locale.Language?
        let target: Locale.Language?
        let preferredStrategy: Strategy?
        init(source: Locale.Language?, target: Locale.Language?, preferredStrategy: Strategy? = nil) {
            self.source = source; self.target = target; self.preferredStrategy = preferredStrategy
        }
    }
    let configuration: Configuration
    var makesReady = true
    var suspendPrepare = false
    var pendingPrepare: CheckedContinuation<Void, Never>?
    var prepares = 0
    init(_ configuration: Configuration) { self.configuration = configuration }
    var sourceLanguage: Locale.Language? { configuration.source }
    var targetLanguage: Locale.Language? { configuration.target }
    func prepareTranslation() async throws {
        prepares += 1
        if suspendPrepare { await withCheckedContinuation { pendingPrepare = $0 } }
        if makesReady {
            LanguageAvailability.statuses[LanguageAvailability.key(configuration.source!, configuration.target!)] = .installed
        }
    }
}

// INSERT_ACTUAL_PACKS

@main struct OfflinePacksRegression {
    static var assertions = 0
    static var failures = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { failures += 1; print("FAIL: " + message) }
    }
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 { if condition() { return }; await Task.yield() }
        check(false, "controlled async operation arrived")
    }
    static func drain() async { for _ in 0..<200 { await Task.yield() } }
    static func reset(installed: Bool = false) {
        AssetInventory.reset(installed: installed)
        LanguageAvailability.statuses = [:]
        LanguageAvailability.suspendKey = nil
        LanguageAvailability.pendingStatus = []
    }
    static func model() -> OfflineLanguagePacks {
        OfflineLanguagePacks(languages: .init(first: .english, second: .french), script: .simplified)
    }
    static func finishDirections(_ packs: OfflineLanguagePacks) async {
        for _ in 0..<2 {
            guard let configuration = packs.translationConfiguration else {
                check(false, "translation direction is requested"); return
            }
            await packs.prepareTranslation(TranslationSession(configuration), requestID: packs.translationRequestID)
        }
    }
    static func main() async {
        reset(installed: true)
        AssetInventory.reserved = [Locale(identifier: "en"), Locale(identifier: "fr")]
        LanguageAvailability.statuses = ["en>fr": .installed]
        let alreadyReserved = model()
        await alreadyReserved.refresh()
        check(!alreadyReserved.ready && alreadyReserved.components.count == 4,
              "one installed translation direction is insufficient")
        check(alreadyReserved.canDownload, "supported incomplete pair can download")
        alreadyReserved.download()
        await until { alreadyReserved.translationConfiguration != nil || !alreadyReserved.isDownloading }
        check(AssetInventory.reserveCalls.count == 2 && alreadyReserved.error == nil,
              "already-reserved locales are accepted on retry")
        check(alreadyReserved.translationConfiguration?.preferredStrategy == .lowLatency,
              "download explicitly selects the low-latency model")
        if let first = alreadyReserved.translationConfiguration {
            let firstID = alreadyReserved.translationRequestID
            await alreadyReserved.prepareTranslation(TranslationSession(first), requestID: firstID)
            check(alreadyReserved.translationConfiguration?.source?.languageCode?.identifier == "fr",
                  "download prepares the reverse direction separately")
            let reverseID = alreadyReserved.translationRequestID
            check(reverseID != firstID, "each direction receives a unique request identity")
            let stale = TranslationSession(first)
            await alreadyReserved.prepareTranslation(stale, requestID: firstID)
            check(stale.prepares == 0 && alreadyReserved.translationRequestID == reverseID,
                  "stale first-direction callback cannot advance the reverse download")
            if let reverse = alreadyReserved.translationConfiguration {
                await alreadyReserved.prepareTranslation(TranslationSession(reverse), requestID: reverseID)
            }
        }
        check(alreadyReserved.ready && !alreadyReserved.isDownloading,
              "both speech models and both translation directions establish readiness")
        LanguageAvailability.statuses["fr>en"] = .supported
        await alreadyReserved.refresh()
        check(!alreadyReserved.ready, "removed translation assets revoke readiness on refresh")
        AssetInventory.statuses["en"] = .supported
        LanguageAvailability.statuses["fr>en"] = .installed
        await alreadyReserved.refresh()
        check(!alreadyReserved.ready, "removed speech assets revoke readiness independently")

        reset()
        let fresh = model()
        await fresh.refresh()
        fresh.download()
        await until { fresh.translationConfiguration != nil || !fresh.isDownloading }
        check(AssetInventory.downloadCalls == 2, "fresh pair downloads both speech models")
        await finishDirections(fresh)
        check(fresh.ready, "fresh pair becomes ready only after all components install")

        reset()
        AssetInventory.completeDownload = false
        let incompleteSpeech = model()
        await incompleteSpeech.refresh()
        incompleteSpeech.download()
        await until { !incompleteSpeech.isDownloading }
        check(incompleteSpeech.error != nil && !incompleteSpeech.ready
              && incompleteSpeech.translationConfiguration == nil,
              "incomplete speech installation reports failure before translation setup")

        reset(installed: true)
        let incompleteText = model()
        await incompleteText.refresh()
        incompleteText.download()
        await until { incompleteText.translationConfiguration != nil }
        let notReady = TranslationSession(incompleteText.translationConfiguration!)
        notReady.makesReady = false
        await incompleteText.prepareTranslation(notReady, requestID: incompleteText.translationRequestID)
        check(incompleteText.error != nil && !incompleteText.ready && !incompleteText.isDownloading,
              "translation prepare returning without ready models cannot claim success")

        reset()
        SpeechTranscriber.unsupported = ["fr"]
        let unsupported = model()
        await unsupported.refresh()
        unsupported.download()
        check(!unsupported.canDownload && !unsupported.ready && AssetInventory.reserveCalls.isEmpty,
              "unsupported speech language cannot download or claim readiness")

        reset()
        LanguageAvailability.statuses = ["fr>en": .unsupported]
        let unsupportedReverse = model()
        await unsupportedReverse.refresh()
        check(!unsupportedReverse.canDownload && !unsupportedReverse.ready,
              "unsupported reverse translation prevents full pair readiness")

        reset()
        AssetInventory.throwQuota = true
        let quota = model()
        await quota.refresh()
        quota.download()
        await until { !quota.isDownloading }
        check(quota.error != nil && quota.translationConfiguration == nil,
              "reservation quota errors stop the operation")

        reset(installed: true)
        let retry = model()
        await retry.refresh()
        retry.download()
        await until { retry.translationConfiguration != nil }
        let oldID = retry.translationRequestID
        let slow = TranslationSession(retry.translationConfiguration!)
        slow.suspendPrepare = true
        let oldTask = Task { await retry.prepareTranslation(slow, requestID: oldID) }
        await until { slow.pendingPrepare != nil }
        retry.cancel()
        check(!retry.isDownloading && retry.translationConfiguration == nil, "cancel closes the active download")
        retry.download()
        await until { retry.translationConfiguration != nil }
        let newID = retry.translationRequestID
        slow.pendingPrepare?.resume()
        slow.pendingPrepare = nil
        await oldTask.value
        check(retry.isDownloading && retry.translationRequestID == newID && retry.error == nil,
              "old prepare completion cannot finish or fail a retried operation")
        await finishDirections(retry)
        check(retry.ready, "retry can finish after cancelled work completes late")

        reset()
        AssetInventory.suspendReserve = true
        let reserveCancelled = model()
        await reserveCancelled.refresh()
        reserveCancelled.download()
        await until { AssetInventory.pendingReserve != nil }
        reserveCancelled.cancel()
        AssetInventory.suspendReserve = false
        AssetInventory.pendingReserve?.resume()
        AssetInventory.pendingReserve = nil
        await drain()
        check(AssetInventory.installationRequests == 0 && AssetInventory.downloadCalls == 0,
              "cancel during reservation prevents starting an asset request")

        reset()
        AssetInventory.suspendRequest = true
        let requestCancelled = model()
        await requestCancelled.refresh()
        requestCancelled.download()
        await until { AssetInventory.pendingRequest != nil }
        requestCancelled.cancel()
        AssetInventory.suspendRequest = false
        AssetInventory.pendingRequest?.resume()
        AssetInventory.pendingRequest = nil
        await drain()
        check(AssetInventory.downloadCalls == 0 && requestCancelled.translationConfiguration == nil,
              "cancel during asset request prevents beginning the returned download")

        reset(installed: true)
        let duplicate = model()
        await duplicate.refresh()
        duplicate.download()
        await until { duplicate.translationConfiguration != nil }
        let duplicateID = duplicate.translationRequestID
        let shared = TranslationSession(duplicate.translationConfiguration!)
        LanguageAvailability.suspendKey = "en>fr"
        let firstCallback = Task { await duplicate.prepareTranslation(shared, requestID: duplicateID) }
        let secondCallback = Task { await duplicate.prepareTranslation(shared, requestID: duplicateID) }
        await until { LanguageAvailability.pendingStatus.count == 2 }
        LanguageAvailability.suspendKey = nil
        LanguageAvailability.pendingStatus.removeFirst().resume(returning: .installed)
        await until { duplicate.translationRequestID != duplicateID }
        let reverseID = duplicate.translationRequestID
        LanguageAvailability.pendingStatus.removeFirst().resume(returning: .installed)
        await firstCallback.value
        await secondCallback.value
        check(duplicate.isDownloading && duplicate.translationRequestID == reverseID
              && duplicate.translationConfiguration?.source?.languageCode?.identifier == "fr",
              "duplicate first-direction completion cannot skip the reverse translation")
        LanguageAvailability.suspendKey = nil
        duplicate.cancel()

        print("Offline packs regression: \(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
