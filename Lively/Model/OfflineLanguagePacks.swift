import Foundation
import Observation
import Speech
import Translation

/// Readiness comes from the system, never from a saved "downloaded" flag.
/// Apple shares these models with other apps and can remove unused assets.
@Observable
final class OfflineLanguagePacks {
    enum State: String {
        case checking = "Checking…"
        case missing = "Download needed"
        case downloading = "Downloading…"
        case ready = "Ready"
        case unsupported = "Unavailable on this device"
    }

    struct Component: Identifiable {
        let id: String
        let title: String
        let state: State
    }

    let languages: LanguagePair
    let script: ChineseScript
    private(set) var components: [Component] = []
    private(set) var isDownloading = false
    private(set) var downloadLabel = ""
    private(set) var error: String?
    private(set) var reservedLocales: [Locale] = []
    private(set) var translationRequestID = UUID()
    var translationConfiguration: TranslationSession.Configuration?
    private var operation = UUID()
    private var refreshID = UUID()
    private var worker: Task<Void, Never>?
    private var direction = 0

    init(languages: LanguagePair, script: ChineseScript) {
        self.languages = languages
        self.script = script
    }

    var ready: Bool { components.count == 4 && components.allSatisfy { $0.state == .ready } }
    var canDownload: Bool {
        !isDownloading && !components.isEmpty
            && !components.contains { $0.state == .checking || $0.state == .unsupported }
    }

    func refresh() async {
        let token = UUID()
        refreshID = token
        var rows: [Component] = []
        for language in languages.all {
            let state: State
            if SpeechTranscriber.isAvailable,
               let locale = await SpeechTranscriber.supportedLocale(equivalentTo: OfflineSpeechEngine.locale(for: language, script: script)) {
                let module = OfflineSpeechEngine.makeTranscriber(locale: locale)
                switch await AssetInventory.status(forModules: [module]) {
                case .installed: state = .ready
                case .downloading: state = .downloading
                case .supported: state = .missing
                default: state = .unsupported
                }
            } else {
                state = .unsupported
            }
            rows.append(Component(id: "speech-\(language.rawValue)", title: "\(language.englishName) speech recognition", state: state))
        }
        for (source, target) in directions {
            let state: State
            switch await Self.translationStatus(source: source, target: target, script: script) {
            case .installed: state = .ready
            case .supported: state = .missing
            default: state = .unsupported
            }
            rows.append(Component(id: "text-\(source.rawValue)", title: "\(source.englishName) → \(target.englishName)", state: state))
        }
        let reserved = await AssetInventory.reservedLocales
        guard !Task.isCancelled, refreshID == token else { return }
        components = rows
        reservedLocales = reserved
    }

    func download() {
        guard canDownload else { return }
        error = nil
        isDownloading = true
        let token = UUID()
        operation = token
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                for language in languages.all {
                    try check(token)
                    downloadLabel = "Downloading \(language.englishName) speech…"
                    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: OfflineSpeechEngine.locale(for: language, script: script)) else {
                        throw PackError.unavailable(language.englishName)
                    }
                    try check(token)
                    // false means this app already reserved the locale; quota
                    // failures throw. Retrying an installed pack is valid.
                    try await AssetInventory.reserve(locale: locale)
                    try check(token)
                    let module = OfflineSpeechEngine.makeTranscriber(locale: locale)
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                        try check(token)
                        try await request.downloadAndInstall()
                    }
                    try check(token)
                    guard await AssetInventory.status(forModules: [module]) == .installed else {
                        throw PackError.incomplete
                    }
                }
                try check(token)
                direction = 0
                prepareDirection()
            } catch {
                await finish(token, error: error)
            }
        }
    }

    /// Called only from the view-bound translationTask that owns the session.
    func prepareTranslation(_ session: sending TranslationSession, requestID: UUID) async {
        let token = operation
        let expectedDirection = direction
        guard isDownloading, requestID == translationRequestID else { return }
        do {
            try await session.prepareTranslation()
            try check(token)
            guard direction == expectedDirection, requestID == translationRequestID else { return }
            // prepareTranslation can return while a shared download is still
            // underway. Don't mark the pair ready until the system confirms it.
            let (source, target) = directions[expectedDirection]
            guard await Self.translationStatus(source: source, target: target, script: script) == .installed else {
                throw PackError.incomplete
            }
            try check(token)
            guard direction == expectedDirection, requestID == translationRequestID else { return }
            direction += 1
            if direction < directions.count {
                prepareDirection()
            } else {
                await finish(token, error: nil)
            }
        } catch {
            guard requestID == translationRequestID else { return }
            await finish(token, error: error)
        }
    }

    func cancel() {
        operation = UUID()
        refreshID = UUID()
        worker?.cancel()
        worker = nil
        translationConfiguration = nil
        translationRequestID = UUID()
        isDownloading = false
        downloadLabel = ""
        // System-owned downloads already underway can outlive this operation.
        // Read their real status again rather than restoring stale row labels.
        Task { [weak self] in await self?.refresh() }
    }

    private var directions: [(Language, Language)] {
        [(languages.first, languages.second), (languages.second, languages.first)]
    }

    private func prepareDirection() {
        let (source, target) = directions[direction]
        downloadLabel = "Preparing \(source.englishName) → \(target.englishName)…"
        translationRequestID = UUID()
        translationConfiguration = Self.configuration(source: source, target: target, script: script)
    }

    func release(_ locale: Locale) async {
        guard !isDownloading else { return }
        await AssetInventory.release(reservedLocale: locale)
        await refresh()
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard operation == token else { throw CancellationError() }
    }

    private func finish(_ token: UUID, error: Error?) async {
        guard operation == token else { return }
        if let error, !(error is CancellationError) { self.error = error.localizedDescription }
        // Keep the view-bound task alive until readiness is recorded. Clearing
        // its configuration first can cancel the task performing this refresh.
        await refresh()
        guard operation == token else { return }
        isDownloading = false
        worker = nil
        translationConfiguration = nil
        downloadLabel = ""
    }

    static func configuration(source: Language, target: Language, script: ChineseScript) -> TranslationSession.Configuration {
        let source = AppleTranslator.language(source, script: script)
        let target = AppleTranslator.language(target, script: script)
        if #available(iOS 26.4, macOS 26.4, *) {
            return .init(source: source, target: target, preferredStrategy: .lowLatency)
        }
        return .init(source: source, target: target)
    }

    nonisolated static func translationStatus(source: Language, target: Language, script: ChineseScript) async -> LanguageAvailability.Status {
        let availability: LanguageAvailability
        if #available(iOS 26.4, macOS 26.4, *) {
            availability = .init(preferredStrategy: .lowLatency)
        } else {
            availability = .init()
        }
        return await availability.status(from: AppleTranslator.language(source, script: script), to: AppleTranslator.language(target, script: script))
    }
}

private enum PackError: LocalizedError {
    case unavailable(String), incomplete
    var errorDescription: String? {
        switch self {
        case .unavailable(let language): "Offline speech isn't supported for \(language) on this device."
        case .incomplete: "The languages aren't fully installed yet. Keep an internet connection, then check again or retry the download."
        }
    }
}
