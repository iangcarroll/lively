import CryptoKit
import Foundation
import Observation
import os

nonisolated struct NeuralVoiceManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }
    let schemaVersion: Int
    let repository: String
    let revision: String
    let files: [File]
    var totalBytes: Int64 {
        files.reduce(0) { sum, file in
            let (value, overflow) = sum.addingReportingOverflow(file.size)
            return overflow ? Int64.max : value
        }
    }

    func validate() throws {
        guard schemaVersion == 1, repository == NeuralVoiceCatalog.repository,
              revision == NeuralVoiceCatalog.revision, !files.isEmpty, files.count <= 256,
              Set(files.map(\.path)).count == files.count else { throw NeuralVoicePackError.manifest }
        for file in files {
            let pieces = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.contains("\\"), !file.path.contains("\0"),
                  pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  file.size >= 0, file.size <= 1_000_000_000, file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw NeuralVoicePackError.manifest
            }
        }
        guard totalBytes > 0, totalBytes <= 1_000_000_000 else { throw NeuralVoicePackError.manifest }
        let required = Set(NeuralVoiceCatalog.voices.map(\.embeddingPath) + [
            "kokoro_5s.mlmodelc/coremldata.bin", "kokoro_5s.mlmodelc/model.mil", "kokoro_5s.mlmodelc/weights/weight.bin",
            "G2PEncoder.mlmodelc/coremldata.bin", "G2PEncoder.mlmodelc/weights/weight.bin",
            "G2PDecoder.mlmodelc/coremldata.bin", "G2PDecoder.mlmodelc/weights/weight.bin",
            "pipeline_config.json", "vocab_index.json", "g2p_vocab.json", "us_gold.json", "us_silver.json",
        ])
        guard required.isSubset(of: Set(files.map(\.path))) else { throw NeuralVoicePackError.manifest }
    }

    func url(for file: File) -> URL {
        let root = URL(string: "https://huggingface.co")!
            .appendingPathComponent(repository).appendingPathComponent("resolve").appendingPathComponent(revision)
        return file.path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }
}

nonisolated protocol NeuralVoiceDownloading: Sendable {
    /// Returns an owned temporary file. The caller removes or moves it.
    func fetch(_ url: URL, expectedBytes: Int64,
               progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

typealias NeuralVoiceInstalledVerifier = @Sendable (URL, NeuralVoiceManifest) async throws -> URL?

nonisolated struct URLSessionNeuralVoiceDownloader: NeuralVoiceDownloading {
    func fetch(_ url: URL, expectedBytes: Int64,
               progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = NeuralVoiceDownloadProgress(expectedBytes: expectedBytes, progress: progress)
        let (file, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw NeuralVoicePackError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return file
    }
}

nonisolated private final class NeuralVoiceDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expectedBytes: Int64
    let progress: @Sendable (Int64) -> Void
    private let lastReported = OSAllocatedUnfairLock(initialState: Int64(0))
    init(expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes { downloadTask.cancel() }
        let report = lastReported.withLock { previous in
            guard totalBytesWritten == expectedBytes || totalBytesWritten - previous >= 262_144 else { return false }
            previous = totalBytesWritten
            return true
        }
        if report { progress(min(totalBytesWritten, expectedBytes)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

@Observable
final class NeuralVoicePacks {
    enum Status { case notInstalled, checking, downloading, ready, deleting, failed }
    static let shared = NeuralVoicePacks()
    private(set) var status: Status = .notInstalled
    private(set) var installedDirectory: URL?
    private(set) var progress: Double = 0
    private(set) var downloadedBytes: Int64 = 0
    private(set) var error: String?
    private(set) var selectionRevision = 0
    private(set) var installationRevision = 0
    private var selections: [String: String] = [:]
    private let manifest: NeuralVoiceManifest?
    private let directory: URL
    private let defaults: UserDefaults
    private let downloader: any NeuralVoiceDownloading
    private let installedVerifier: NeuralVoiceInstalledVerifier
    private var operation = UUID()
    private struct VerificationJob {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<URL?, Error>]
    }
    private var verificationJob: VerificationJob?
    private var worker: Task<Void, Never>?

    init(manifest: NeuralVoiceManifest? = NeuralVoicePacks.bundledManifest(),
         directory: URL = NeuralVoicePacks.defaultDirectory(), defaults: UserDefaults = .standard,
         downloader: any NeuralVoiceDownloading = URLSessionNeuralVoiceDownloader(),
         installedVerifier: @escaping NeuralVoiceInstalledVerifier = { try await NeuralVoicePackIO.installed(in: $0, manifest: $1) }) {
        self.manifest = manifest
        self.directory = directory
        self.defaults = defaults
        self.downloader = downloader
        self.installedVerifier = installedVerifier
        for language in NeuralVoiceCatalog.languages {
            if let id = defaults.string(forKey: Self.preferenceKey(language.id)),
               let voice = NeuralVoiceCatalog.voice(with: id), voice.languageCode == language.id {
                selections[language.id] = id
            }
        }
    }

    var isReady: Bool { installedDirectory != nil }
    var isDownloading: Bool { status == .downloading }
    var isBusy: Bool { status == .checking || status == .downloading || status == .deleting }
    var totalBytes: Int64 { manifest?.totalBytes ?? 0 }
    var canDownload: Bool { manifest != nil && !isBusy }
    var statusText: String {
        switch status {
        case .notInstalled: "Download needed"
        case .checking: "Checking downloaded files…"
        case .downloading: "Downloading…"
        case .ready: "All 54 voices available offline"
        case .deleting: "Deleting voice files…"
        case .failed: "Download needs attention"
        }
    }

    func selectedVoice(for languageCode: String) -> NeuralVoice? {
        if let id = selections[languageCode], let voice = NeuralVoiceCatalog.voice(with: id) { return voice }
        guard let language = NeuralVoiceCatalog.language(with: languageCode) else { return nil }
        return NeuralVoiceCatalog.voice(with: language.defaultVoiceID)
    }

    func select(_ voice: NeuralVoice) {
        guard NeuralVoiceCatalog.voice(with: voice.id) == voice else { return }
        guard selections[voice.languageCode] != voice.id else { return }
        selections[voice.languageCode] = voice.id
        defaults.set(voice.id, forKey: Self.preferenceKey(voice.languageCode))
        selectionRevision &+= 1
    }

    /// Reads and hashes local files only. A stored installation pointer never
    /// makes a partial or modified download ready by itself.
    func refresh() async {
        guard !isDownloading, status != .deleting else { return }
        do {
            guard let manifest else { throw NeuralVoicePackError.notConfigured }
            try manifest.validate()
        } catch {
            guard !Task.isCancelled else { return }
            updateInstalledDirectory(nil)
            status = .failed
            self.error = error.localizedDescription
            return
        }
        // The shared job publishes its own result once. A late cancelled
        // caller must never overwrite the state of a newer verification.
        _ = try? await verifiedInstallation()
    }

    /// Playback can ask for verified local files, but cannot trigger a download.
    func requireInstalledDirectory() async throws -> URL {
        try Task.checkCancellation()
        if let installedDirectory, verificationJob == nil { return installedDirectory }
        let installed = try await verifiedInstallation()
        try Task.checkCancellation()
        guard let installed else { throw NeuralVoicePackError.notInstalled }
        return installed
    }

    /// UI checks and first playback share the same local verification. Each
    /// caller can cancel independently; the last cancellation stops the IO.
    private func verifiedInstallation() async throws -> URL? {
        try Task.checkCancellation()
        guard status != .downloading && status != .deleting else { throw NeuralVoicePackError.notInstalled }
        guard let manifest else { throw NeuralVoicePackError.notConfigured }
        try manifest.validate()
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if verificationJob != nil {
                    verificationJob?.waiters[waiter] = continuation
                    return
                }
                let id = UUID()
                status = .checking
                let task = Task<Void, Never> { [weak self, installedVerifier, directory] in
                    do {
                        let installed = try await installedVerifier(directory, manifest)
                        self?.finishVerification(id, result: .success(installed))
                    } catch {
                        self?.finishVerification(id, result: .failure(error))
                    }
                }
                verificationJob = VerificationJob(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelVerificationWaiter(waiter) }
        }
    }

    private func finishVerification(_ id: UUID, result: Result<URL?, Error>) {
        guard let job = verificationJob, job.id == id else { return }
        verificationJob = nil
        switch result {
        case .success(let installed):
            updateInstalledDirectory(installed)
            status = installed == nil ? .notInstalled : .ready
            error = nil
        case .failure(let failure):
            updateInstalledDirectory(nil)
            status = failure is CancellationError ? .notInstalled : .failed
            if !(failure is CancellationError) { error = failure.localizedDescription }
        }
        for continuation in job.waiters.values { continuation.resume(with: result) }
    }

    private func cancelVerificationWaiter(_ waiter: UUID) {
        guard let continuation = verificationJob?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if verificationJob?.waiters.isEmpty == true { cancelVerification() }
    }

    private func cancelVerification() {
        let job = verificationJob
        verificationJob = nil
        job?.task.cancel()
        job?.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        if status == .checking { status = installedDirectory == nil ? .notInstalled : .ready }
    }

    private func updateInstalledDirectory(_ installed: URL?) {
        if installedDirectory != installed { installationRevision &+= 1 }
        installedDirectory = installed
    }

    func download() {
        guard canDownload else { return }
        let token = UUID()
        operation = token
        cancelVerification()
        status = .downloading
        error = nil
        progress = 0
        downloadedBytes = 0
        worker = Task { [weak self] in await self?.runDownload(token) }
    }

    func cancel() {
        guard isDownloading else { return }
        operation = UUID()
        worker?.cancel()
        worker = nil
        if isDownloading { status = installedDirectory == nil ? .notInstalled : .ready }
        progress = 0
        downloadedBytes = 0
    }

    func delete(beforeRemoving: @MainActor () async -> Void = {}) async {
        guard status != .deleting else { return }
        cancel()
        cancelVerification()
        operation = UUID()
        let token = operation
        let previousInstallation = installedDirectory
        installedDirectory = nil
        installationRevision &+= 1
        status = .deleting
        do {
            await beforeRemoving()
            try check(token)
            try await NeuralVoicePackIO.remove(directory)
            guard operation == token else { return }
            status = .notInstalled
            error = nil
        } catch is CancellationError {
            guard operation == token else { return }
            // Cancellation before removal preserves the verified files. The
            // unload hook has completed, so restoring availability is safe.
            updateInstalledDirectory(previousInstallation)
            status = previousInstallation == nil ? .notInstalled : .ready
            error = nil
        } catch {
            guard operation == token else { return }
            status = .failed
            self.error = error.localizedDescription
        }
    }

    private func runDownload(_ token: UUID) async {
        let stage = directory.appendingPathComponent(".download-\(token.uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stage)
            if operation == token { worker = nil }
        }
        do {
            guard let manifest else { throw NeuralVoicePackError.notConfigured }
            try manifest.validate()
            try check(token)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            var storage = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? storage.setResourceValues(values)
            var completed: Int64 = 0
            for file in manifest.files {
                try check(token)
                let before = completed
                let temporary = try await downloader.fetch(manifest.url(for: file), expectedBytes: file.size) { [weak self] bytes in
                    Task { @MainActor [weak self] in
                        guard let self, self.operation == token, self.isDownloading else { return }
                        self.downloadedBytes = max(self.downloadedBytes, min(before + max(0, bytes), manifest.totalBytes))
                        self.progress = Double(self.downloadedBytes) / Double(max(1, manifest.totalBytes))
                    }
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try check(token)
                try await NeuralVoicePackIO.verify(file: file, at: temporary)
                try check(token)
                let destination = stage.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temporary, to: destination)
                completed += file.size
                downloadedBytes = completed
                progress = Double(completed) / Double(max(1, manifest.totalBytes))
            }
            try await NeuralVoicePackIO.verify(directory: stage, manifest: manifest)
            try check(token)
            // The generation directory and the pointer are each published by
            // an atomic rename. A failed/cancelled update leaves the old pack.
            let name = "installed-\(manifest.revision)-\(token.uuidString)"
            let final = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.moveItem(at: stage, to: final)
            do {
                try JSONEncoder().encode(name).write(to: directory.appendingPathComponent("installed.json"), options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: final)
                throw error
            }
            installedDirectory = final
            installationRevision &+= 1
            status = .ready
            progress = 1
        } catch is CancellationError {
            if operation == token { status = installedDirectory == nil ? .notInstalled : .ready }
        } catch {
            guard operation == token else { return }
            status = .failed
            self.error = error.localizedDescription
        }
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard operation == token else { throw CancellationError() }
    }
    private static func preferenceKey(_ language: String) -> String { "neuralVoice.\(language)" }
    private static func bundledManifest() -> NeuralVoiceManifest? {
        let url = Bundle.main.url(forResource: "kokoro-voice-manifest", withExtension: "json")
            ?? Bundle.main.url(forResource: "kokoro-voice-manifest", withExtension: "json", subdirectory: "Resources")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NeuralVoiceManifest.self, from: data)
    }
    private static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lively/OfflineVoices", isDirectory: true)
    }
}

nonisolated private enum NeuralVoicePackIO {
    static func installed(in root: URL, manifest: NeuralVoiceManifest) async throws -> URL? {
        try await background {
            let pointer = root.appendingPathComponent("installed.json")
            guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
            let name = try JSONDecoder().decode(String.self, from: Data(contentsOf: pointer))
            guard name.hasPrefix("installed-\(manifest.revision)-"), !name.contains("/"), !name.contains("\\"),
                  !name.contains("..") else { throw NeuralVoicePackError.integrity }
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try verifyFiles(directory, manifest: manifest)
            return directory
        }
    }
    static func verify(file: NeuralVoiceManifest.File, at url: URL) async throws {
        try await background { try verifyFile(file, at: url) }
    }
    static func verify(directory: URL, manifest: NeuralVoiceManifest) async throws {
        try await background { try verifyFiles(directory, manifest: manifest) }
    }
    static func remove(_ directory: URL) async throws {
        try await background {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
    }
    private static func verifyFiles(_ directory: URL, manifest: NeuralVoiceManifest) throws {
        for file in manifest.files {
            try Task.checkCancellation()
            try verifyFile(file, at: directory.appendingPathComponent(file.path))
        }
    }
    private static func verifyFile(_ file: NeuralVoiceManifest.File, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == file.size else { throw NeuralVoicePackError.integrity }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            throw NeuralVoicePackError.integrity
        }
    }
    private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

nonisolated enum NeuralVoicePackError: LocalizedError {
    case notConfigured, manifest, integrity, notInstalled, server(Int)
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Offline voice downloads aren't configured in this build."
        case .manifest: "The voice download details aren't valid. Update Lively and try again."
        case .integrity: "The voice files couldn't be verified. Retry the download."
        case .notInstalled: "Download the shared voice pack before using offline voices."
        case .server(let status): "The voice download failed (HTTP \(status)). Try again."
        }
    }
}
