import CryptoKit
import Foundation

actor VoiceDownloadStub: NeuralVoiceDownloading {
    let files: [String: Data]
    let temporary: URL
    private(set) var requests = 0
    var corruptPath: String?
    var failAfter: Int?
    var holdNext = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var callbacks: [@Sendable (Int64) -> Void] = []
    init(files: [String: Data], temporary: URL) { self.files = files; self.temporary = temporary }
    func configure(corrupt: String? = nil, fail: Int? = nil, hold: Bool = false) {
        corruptPath = corrupt; failAfter = fail; holdNext = hold
    }
    func release() { waiting?.resume(); waiting = nil }
    func isWaiting() -> Bool { waiting != nil }
    func lateProgress() { callbacks.first?(0) }
    func fetch(_ url: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        requests += 1
        if let failAfter, requests >= failAfter { throw URLError(.networkConnectionLost) }
        // Everything after the revision, whichever host and pin it came from.
        let pieces = url.path.split(separator: "/")
        let revision = pieces.firstIndex { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }!
        let path = pieces[(revision + 1)...].joined(separator: "/")
        guard var data = files[path] else { throw URLError(.fileDoesNotExist) }
        callbacks.append(progress); progress(0)
        if holdNext {
            holdNext = false
            // Deliberately return late despite cancellation.
            await withCheckedContinuation { waiting = $0 }
        }
        if corruptPath == path, !data.isEmpty { data[0] ^= 1 }
        let destination = temporary.appendingPathComponent(UUID().uuidString)
        try data.write(to: destination)
        progress(expectedBytes)
        return destination
    }
}

actor VoiceVerificationGate {
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<URL?, Never>] = [:]
    private var released: [Int: Result<URL?, Never>] = [:]
    func verify() async -> URL? {
        calls += 1
        let call = calls
        if case .success(let url)? = released.removeValue(forKey: call) { return url }
        return await withCheckedContinuation { pending[call] = $0 }
    }
    func release(_ url: URL?, call: Int = 1) {
        if let continuation = pending.removeValue(forKey: call) { continuation.resume(returning: url) }
        else { released[call] = .success(url) }
    }
}

@MainActor final class VoiceUnloadGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func unload() async {
        await withCheckedContinuation {
            isWaiting = true
            continuation = $0
        }
    }
    func finish() {
        isWaiting = false
        continuation?.resume()
        continuation = nil
    }
}

extension NeuralVoicePacks {
    // Controlled suspension coordination, without production test hooks.
    var testVerificationWaiters: Int { verificationJob?.waiters.count ?? 0 }
}

@main struct NeuralVoicePacksRegression {
    @MainActor static var assertions = 0
    @MainActor static var failures = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() {
            failures += 1; print("FAIL: \(message)")
            if CommandLine.arguments.contains("--fail-fast") { exit(1) }
        }
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        check(condition(), "timed out waiting for pack state")
    }
    @MainActor static func settle() async { for _ in 0..<100 { await Task.yield() } }
    @MainActor static func noNetwork(_ client: VoiceDownloadStub, _ expected: Int, _ message: String) async {
        let count = await client.requests
        check(count == expected, message)
    }
    @MainActor static func expectManifestError(_ manifest: NeuralVoiceManifest, _ message: String) {
        do { try manifest.validate(); check(false, message) } catch { check(true, message) }
    }

    @MainActor static func main() async throws {
        let actual = try JSONDecoder().decode(NeuralVoiceManifest.self, from: Data(contentsOf: URL(filePath: CommandLine.arguments[1])))
        try actual.validate()
        check(NeuralVoiceCatalog.voices.count == 54, "all 54 presets are listed")
        check(Set(NeuralVoiceCatalog.voices.map(\.id)).count == 54, "voice identifiers are unique")
        check(NeuralVoiceCatalog.languages.count == 8, "only the eight trained languages are advertised")
        check(Set(NeuralVoiceCatalog.language(with: "ja")!.voices.map(\.id)) == ["jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo"], "all five Japanese presets are present")
        check(NeuralVoiceCatalog.language(with: "en")!.voices.count == 28, "both English accents share one language selection")
        check(NeuralVoiceCatalog.voice(with: "bf_emma")?.accent == "British", "British accent is identified")
        check(NeuralVoiceCatalog.language(with: "ko") == nil, "unsupported language isn't advertised")
        check(actual.totalBytes == 92_022_138, "bundled size matches pinned manifest")
        check(actual.url(for: actual.files[0]).absoluteString.contains(NeuralVoiceCatalog.revision), "download URL pins a commit")
        let weights = actual.files.first { $0.path == "kokoro_5s.mlmodelc/weights/weight.bin" }!
        check(actual.url(for: weights, broker: URL(string: "https://broker.test")!).absoluteString
            == "https://broker.test/v1/voices/files/\(actual.revision)/kokoro_5s.mlmodelc/weights/weight.bin", "files come from the key service")
        check(actual.url(for: weights, broker: nil).absoluteString
            == "https://huggingface.co/\(actual.repository)/resolve/\(actual.revision)/kokoro_5s.mlmodelc/weights/weight.bin", "a build without a key service uses the pinned source")
        let brokerless = try await NeuralVoiceManifest.current(broker: nil)
        check(brokerless == nil, "a build without a key service keeps the bundled pin")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lively-neural-pack-tests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suite = "lively-neural-voice-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let payloads = Dictionary(uniqueKeysWithValues: actual.files.map { ($0.path, Data("fixture:\($0.path)".utf8)) })
        let files = actual.files.map { file in
            let data = payloads[file.path]!
            return NeuralVoiceManifest.File(path: file.path, size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let manifest = NeuralVoiceManifest(schemaVersion: 1, repository: actual.repository, revision: actual.revision, files: files)
        let client = VoiceDownloadStub(files: payloads, temporary: temporary)
        let root = temporary.appendingPathComponent("pack", isDirectory: true)
        let packs = NeuralVoicePacks(manifest: manifest, directory: root, defaults: defaults, downloader: client)
        await packs.refresh()
        check(!packs.isReady && packs.status == .notInstalled, "empty storage isn't ready")
        do { _ = try await packs.requireInstalledDirectory(); check(false, "playback must not download") } catch {}
        await noNetwork(client, 0, "refresh and playback preparation make no network calls")
        let cancelledRefresh = Task { await packs.refresh() }
        cancelledRefresh.cancel(); await cancelledRefresh.value
        check(packs.status != .checking, "cancelled verification doesn't leave controls stuck")
        check(packs.selectedVoice(for: "ja")?.id == "jf_alpha", "Japanese appears before downloading")
        packs.select(NeuralVoiceCatalog.voice(with: "jm_kumo")!)
        packs.select(NeuralVoiceCatalog.voice(with: "bf_emma")!)
        let reloaded = NeuralVoicePacks(manifest: manifest, directory: root, defaults: defaults, downloader: client)
        check(reloaded.selectedVoice(for: "ja")?.id == "jm_kumo", "Japanese selection persists independently")
        check(reloaded.selectedVoice(for: "en")?.id == "bf_emma", "English selection persists independently")
        check(reloaded.selectedVoice(for: "xx") == nil, "unknown language has no pretend voice")
        let revision = packs.selectionRevision
        packs.select(NeuralVoice(id: "af_heart", name: "Forged", languageCode: "ja", localeIdentifier: "ja-JP"))
        check(packs.selectionRevision == revision && packs.selectedVoice(for: "ja")?.id == "jm_kumo", "forged preference is rejected")
        defaults.set("af_heart", forKey: "neuralVoice.ja")
        let invalidPreference = NeuralVoicePacks(manifest: manifest, directory: root, defaults: defaults, downloader: client)
        check(invalidPreference.selectedVoice(for: "ja")?.id == "jf_alpha", "invalid saved voice falls back within its language")
        packs.select(NeuralVoiceCatalog.voice(with: "jf_alpha")!); packs.select(NeuralVoiceCatalog.voice(with: "jm_kumo")!)

        packs.download()
        var previousProgress = 0.0
        var monotonic = true
        let downloadDeadline = ContinuousClock.now + .seconds(15)
        while packs.isDownloading, ContinuousClock.now < downloadDeadline {
            monotonic = monotonic && packs.progress >= previousProgress
            previousProgress = packs.progress
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(monotonic, "download progress cannot move backwards")
        check(packs.isReady && packs.progress == 1, "verified complete download is ready")
        check(packs.downloadedBytes == manifest.totalBytes, "download byte count is exact")
        await noNetwork(client, files.count, "shared installation downloads every file once")
        let installed = try await packs.requireInstalledDirectory()
        check(FileManager.default.fileExists(atPath: installed.appendingPathComponent("voices/jm_kumo.json").path), "shared pack includes Japanese voice")
        let loaded = NeuralVoicePacks(manifest: manifest, directory: root, defaults: defaults, downloader: client)
        await loaded.refresh()
        check(loaded.isReady && loaded.installedDirectory == installed, "fresh instance verifies existing files")
        await noNetwork(client, files.count, "loading installed pack never redownloads")
        await client.lateProgress(); await settle()
        check(packs.progress == 1, "late progress cannot reset completion")

        await client.configure(corrupt: files[0].path)
        packs.download(); await until { !packs.isDownloading }
        check(packs.status == .failed && packs.installedDirectory == installed, "corrupt update preserves last good pack")
        check(FileManager.default.fileExists(atPath: installed.path), "failed update retains good files")
        check(packs.error != nil, "corrupt download reports an error")
        await client.configure()
        let altered = installed.appendingPathComponent(files[0].path)
        var data = try Data(contentsOf: altered); data[0] ^= 1; try data.write(to: altered)
        let beforeRefresh = await client.requests
        await packs.refresh()
        check(!packs.isReady && packs.status == .failed, "same-size modified file fails SHA verification")
        await noNetwork(client, beforeRefresh, "integrity checks never fetch replacements")
        packs.download(); await until { !packs.isDownloading }
        check(packs.isReady, "explicit retry repairs corrupt files")

        let gate = VoiceVerificationGate()
        let cold = NeuralVoicePacks(manifest: manifest, directory: root, defaults: defaults, downloader: client,
                                    installedVerifier: { _, _ in await gate.verify() })
        let uiRefresh = Task { await cold.refresh() }
        await until { cold.testVerificationWaiters == 1 }
        let firstPlayback = Task { try await cold.requireInstalledDirectory() }
        await until { cold.testVerificationWaiters == 2 }
        uiRefresh.cancel(); await uiRefresh.value
        check(cold.status == .checking, "UI cancellation doesn't stop a playback verification waiter")
        let verificationCalls = await gate.calls
        check(verificationCalls == 1, "UI refresh and first playback coalesce one verification")
        await gate.release(packs.installedDirectory)
        switch await firstPlayback.result {
        case .success(let url): check(url == packs.installedDirectory, "first playback receives verified shared result")
        case .failure: check(false, "first playback lost shared verification result")
        }
        check(cold.isReady && cold.status == .ready, "shared verification publishes readiness once")

        let cancelledGate = VoiceVerificationGate()
        let abandoned = NeuralVoicePacks(manifest: manifest, directory: root, defaults: defaults, downloader: client,
                                         installedVerifier: { _, _ in await cancelledGate.verify() })
        let abandonedRefresh = Task { await abandoned.refresh() }
        await until { abandoned.testVerificationWaiters == 1 }
        abandonedRefresh.cancel(); await abandonedRefresh.value
        check(abandoned.status == .notInstalled && !abandoned.isReady, "last verification cancellation releases checking state")
        let newerRefresh = Task { await abandoned.refresh() }
        await until { abandoned.testVerificationWaiters == 1 }
        await cancelledGate.release(nil); await settle()
        check(abandoned.status == .checking, "late abandoned verification can't finish a newer verification")
        await cancelledGate.release(packs.installedDirectory, call: 2); await newerRefresh.value
        check(abandoned.isReady, "new verification can publish after cancellation")
        check(abandoned.isReady && abandoned.status == .ready, "late abandoned verification cannot overwrite a newer result")
        let cancelledReadyRefresh = Task { await abandoned.refresh() }
        await until { abandoned.testVerificationWaiters == 1 }
        cancelledReadyRefresh.cancel(); await cancelledReadyRefresh.value
        check(abandoned.isReady && abandoned.status == .ready, "cancelled recheck preserves the last verified ready state")
        await cancelledGate.release(nil, call: 3); await settle()

        let playbackGate = VoiceVerificationGate()
        let cancelledPlaybackPacks = NeuralVoicePacks(manifest: manifest, directory: root, defaults: defaults, downloader: client,
                                                     installedVerifier: { _, _ in await playbackGate.verify() })
        let cancelledPlayback = Task { try await cancelledPlaybackPacks.requireInstalledDirectory() }
        await until { cancelledPlaybackPacks.testVerificationWaiters == 1 }
        cancelledPlayback.cancel()
        switch await cancelledPlayback.result {
        case .success: check(false, "cancelled playback preparation must not succeed")
        case .failure(let error): check(error is CancellationError, "playback preparation respects cancellation")
        }
        check(cancelledPlaybackPacks.status == .notInstalled, "cancelled playback preparation releases checking state")
        await playbackGate.release(packs.installedDirectory); await settle()

        let cancellingRoot = temporary.appendingPathComponent("cancelling")
        let cancellingClient = VoiceDownloadStub(files: payloads, temporary: temporary)
        await cancellingClient.configure(hold: true)
        let cancelling = NeuralVoicePacks(manifest: manifest, directory: cancellingRoot, defaults: defaults, downloader: cancellingClient)
        cancelling.download()
        while !(await cancellingClient.isWaiting()) { await Task.yield() }
        cancelling.cancel()
        check(!cancelling.isReady && !cancelling.isDownloading, "cancelled partial pack isn't ready")
        check(!FileManager.default.fileExists(atPath: cancellingRoot.appendingPathComponent("installed.json").path), "cancelled staging has no pointer")
        cancelling.download(); await until { !cancelling.isDownloading }
        let replacement = cancelling.installedDirectory
        await cancellingClient.release(); await settle()
        check(cancelling.isReady && cancelling.installedDirectory == replacement, "late cancelled completion can't replace newer pack")
        check(cancelling.progress == 1, "late cancelled progress can't change replacement")

        let deletingClient = VoiceDownloadStub(files: payloads, temporary: temporary)
        await deletingClient.configure(hold: true)
        let deletingRoot = temporary.appendingPathComponent("delete-in-flight")
        let deleting = NeuralVoicePacks(manifest: manifest, directory: deletingRoot, defaults: defaults, downloader: deletingClient)
        deleting.download()
        while !(await deletingClient.isWaiting()) { await Task.yield() }
        await deleting.delete()
        await deletingClient.release(); await settle()
        check(!deleting.isReady && deleting.status == .notInstalled, "late download can't restore a deleted pack")
        check(!FileManager.default.fileExists(atPath: deletingRoot.appendingPathComponent("installed.json").path), "deletion publishes no partial pointer")

        let failingClient = VoiceDownloadStub(files: payloads, temporary: temporary)
        await failingClient.configure(fail: 3)
        let failing = NeuralVoicePacks(manifest: manifest, directory: temporary.appendingPathComponent("failing"), defaults: defaults, downloader: failingClient)
        failing.download(); await until { !failing.isDownloading }
        check(!failing.isReady && failing.status == .failed, "interrupted initial download isn't ready")
        await failingClient.configure()
        failing.download(); await until { !failing.isDownloading }
        check(failing.isReady, "interrupted download can be retried")

        let cancelDeleteGate = VoiceUnloadGate()
        let cancelDeleteDirectory = failing.installedDirectory
        let beforeCancelDeleteRevision = failing.installationRevision
        let beforeCancelDeleteRequests = await failingClient.requests
        let cancelledDeletion = Task { await failing.delete(beforeRemoving: { await cancelDeleteGate.unload() }) }
        await until { cancelDeleteGate.isWaiting }
        cancelledDeletion.cancel()
        check(!failing.isReady && failing.status == .deleting, "cancelled deletion remains unavailable while unload is pending")
        check(FileManager.default.fileExists(atPath: cancelDeleteDirectory!.path), "cancellation never removes files before unload returns")
        cancelDeleteGate.finish(); await cancelledDeletion.value
        check(failing.isReady && failing.status == .ready && failing.installedDirectory == cancelDeleteDirectory, "cancellation before removal restores the verified pack")
        check(failing.error == nil, "cancelled deletion doesn't report an error")
        check(failing.installationRevision > beforeCancelDeleteRevision, "cancelled deletion still invalidates prior queued speech")
        check(FileManager.default.fileExists(atPath: cancelDeleteDirectory!.path), "cancelled deletion preserves installed files")
        await noNetwork(failingClient, beforeCancelDeleteRequests, "cancelled deletion doesn't download a replacement")

        expectManifestError(.init(schemaVersion: 1, repository: actual.repository, revision: actual.revision, files: files.filter { $0.path != "voices/jf_alpha.json" }), "manifest can't omit displayed Japanese voice")
        let traversing = NeuralVoiceManifest.File(path: "../outside", size: 1, sha256: String(repeating: "a", count: 64))
        expectManifestError(.init(schemaVersion: 1, repository: actual.repository, revision: actual.revision, files: files + [traversing]), "manifest can't escape storage")
        expectManifestError(.init(schemaVersion: 1, repository: actual.repository, revision: actual.revision, files: files + [files[0]]), "manifest can't duplicate destinations")
        check((try? NeuralVoiceManifest(schemaVersion: 1, repository: actual.repository, revision: String(repeating: "0", count: 40), files: files).validate()) != nil, "the key service can pin another commit")
        expectManifestError(.init(schemaVersion: 1, repository: actual.repository, revision: "main", files: files), "manifest can't pin a moving branch")
        expectManifestError(.init(schemaVersion: 1, repository: actual.repository, revision: String(repeating: "A", count: 40), files: files), "manifest revision is a lowercase commit hash")
        expectManifestError(.init(schemaVersion: 1, repository: "../" + actual.repository, revision: actual.revision, files: files), "manifest repository can't traverse")
        expectManifestError(.init(schemaVersion: 1, repository: "owner/name?x=1", revision: actual.revision, files: files), "manifest repository can't carry a query")
        expectManifestError(.init(schemaVersion: 2, repository: actual.repository, revision: actual.revision, files: files), "an unknown manifest layout is refused")

        // The key service moves the pin: one file changes under a new commit.
        let movedRevision = String(repeating: "5", count: 40)
        var movedPayloads = payloads
        movedPayloads[files[0].path] = Data("moved:\(files[0].path)".utf8)
        let movedFiles = files.map { file in
            let data = movedPayloads[file.path]!
            return NeuralVoiceManifest.File(path: file.path, size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let moved = NeuralVoiceManifest(schemaVersion: 1, repository: actual.repository, revision: movedRevision, files: movedFiles)
        let movedClient = VoiceDownloadStub(files: movedPayloads, temporary: temporary)
        let movedRoot = temporary.appendingPathComponent("moved", isDirectory: true)
        let pinned = NeuralVoicePacks(manifest: manifest, directory: movedRoot, defaults: defaults, downloader: movedClient, pin: { moved })
        await pinned.refresh()
        await noNetwork(movedClient, 0, "checking installed files never asks for the pin")
        pinned.download(); await until { !pinned.isDownloading }
        check(pinned.isReady && pinned.status == .ready, "a download follows the key service's pin")
        check(pinned.installedDirectory?.lastPathComponent.hasPrefix("installed-\(movedRevision)-") == true, "the installed pack records the pinned commit")
        check(pinned.totalBytes == moved.totalBytes, "the size shown matches the installed pin")
        let movedInstalled = pinned.installedDirectory
        // A later launch, offline, with only the app's older bundled manifest.
        let offline = NeuralVoicePacks(manifest: manifest, directory: movedRoot, defaults: defaults, downloader: movedClient,
                                       pin: { throw URLError(.notConnectedToInternet) })
        await offline.refresh()
        check(offline.isReady && offline.installedDirectory == movedInstalled, "an updated pack verifies offline against its saved pin")
        try Data("tampered".utf8).write(to: movedInstalled!.appendingPathComponent(files[0].path))
        let tampered = NeuralVoicePacks(manifest: manifest, directory: movedRoot, defaults: defaults, downloader: movedClient, pin: { moved })
        await tampered.refresh()
        check(!tampered.isReady && tampered.status == .failed, "a saved pin still checks every file")
        await tampered.delete()
        check(tampered.status == .notInstalled && tampered.totalBytes == manifest.totalBytes, "removing the pack returns to the bundled pin")

        // Updates: the installed checksums are compared with the key service's.
        let updateRoot = temporary.appendingPathComponent("update", isDirectory: true)
        let original = NeuralVoicePacks(manifest: manifest, directory: updateRoot, defaults: defaults,
                                        downloader: VoiceDownloadStub(files: payloads, temporary: temporary), pin: { manifest })
        await original.checkForUpdate()
        check(!original.isUpdateAvailable && original.status == .notInstalled, "nothing installed means nothing to update")
        original.download(); await until { !original.isDownloading }
        let originalDirectory = original.installedDirectory!
        await original.checkForUpdate()
        check(!original.isUpdateAvailable, "matching checksums offer no update")
        let recommitted = NeuralVoicePacks(manifest: manifest, directory: updateRoot, defaults: defaults, downloader: movedClient,
                                           pin: { .init(schemaVersion: 1, repository: actual.repository, revision: movedRevision, files: files) })
        await recommitted.checkForUpdate()
        check(!recommitted.isUpdateAvailable, "a new commit with the same files offers no update")
        let offline2 = NeuralVoicePacks(manifest: manifest, directory: updateRoot, defaults: defaults, downloader: movedClient,
                                        pin: { throw URLError(.notConnectedToInternet) })
        await offline2.checkForUpdate()
        check(!offline2.isUpdateAvailable && offline2.isReady && offline2.error == nil, "an unreachable key service changes nothing")
        let invalidOffer = NeuralVoicePacks(manifest: manifest, directory: updateRoot, defaults: defaults, downloader: movedClient,
                                            pin: { .init(schemaVersion: 1, repository: actual.repository, revision: movedRevision, files: movedFiles + [traversing]) })
        await invalidOffer.checkForUpdate()
        check(!invalidOffer.isUpdateAvailable, "an invalid pin is never offered as an update")

        let updateClient = VoiceDownloadStub(files: movedPayloads, temporary: temporary)
        let updating = NeuralVoicePacks(manifest: manifest, directory: updateRoot, defaults: defaults, downloader: updateClient, pin: { moved })
        await updating.checkForUpdate()
        check(updating.isUpdateAvailable && updating.updateBytes == moved.totalBytes, "different checksums offer an update")
        check(updating.statusText == "Update available" && updating.installedDirectory == originalDirectory, "the offer leaves the installed pack in use")
        await noNetwork(updateClient, 0, "checking for an update downloads no voice file")
        await updateClient.configure(fail: 3)
        updating.download(); await until { !updating.isDownloading }
        check(updating.isReady && updating.installedDirectory == originalDirectory, "a failed update keeps the installed pack")
        await updating.refresh()
        check(updating.status == .ready && updating.isUpdateAvailable, "a failed update is still offered")
        await updateClient.configure(hold: true)
        var unloads = 0
        var filesAtUnload = false
        updating.download(beforeRemovingPrevious: {
            unloads += 1
            filesAtUnload = FileManager.default.fileExists(atPath: originalDirectory.appendingPathComponent(files[0].path).path)
        })
        while !(await updateClient.isWaiting()) { await Task.yield() }
        check(updating.isReady && updating.installedDirectory == originalDirectory, "the installed pack stays usable while an update downloads")
        await updateClient.release(); await until { !updating.isDownloading }
        await until { !FileManager.default.fileExists(atPath: originalDirectory.path) }
        check(updating.isReady && !updating.isUpdateAvailable, "an installed update clears the offer")
        check(updating.installedDirectory?.lastPathComponent.hasPrefix("installed-\(movedRevision)-") == true, "the update installs the offered commit")
        check(unloads == 1 && filesAtUnload, "the model is unloaded before the replaced files are removed")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: updateRoot.path).filter { $0.hasPrefix("installed-") }.sorted()
        let kept = updating.installedDirectory!.lastPathComponent
        check(leftovers == [kept, kept + ".manifest.json"].sorted(), "the replaced pack and its manifest are removed")
        let afterUpdate = NeuralVoicePacks(manifest: manifest, directory: updateRoot, defaults: defaults, downloader: updateClient, pin: { moved })
        await afterUpdate.checkForUpdate()
        check(afterUpdate.isReady && !afterUpdate.isUpdateAvailable, "an updated pack matches the key service on the next launch")

        let unreachable = NeuralVoicePacks(manifest: manifest, directory: temporary.appendingPathComponent("unreachable"), defaults: defaults,
                                           downloader: movedClient, pin: { throw URLError(.notConnectedToInternet) })
        let beforeUnreachable = await movedClient.requests
        unreachable.download(); await until { !unreachable.isDownloading }
        check(!unreachable.isReady && unreachable.status == .failed, "a download doesn't start without the current pin")
        await noNetwork(movedClient, beforeUnreachable, "no file is fetched before the pin is known")
        let unsafe = NeuralVoicePacks(manifest: manifest, directory: temporary.appendingPathComponent("unsafe"), defaults: defaults, downloader: movedClient,
                                      pin: { .init(schemaVersion: 1, repository: actual.repository, revision: movedRevision, files: movedFiles + [traversing]) })
        unsafe.download(); await until { !unsafe.isDownloading }
        check(!unsafe.isReady && unsafe.status == .failed, "an invalid pin from the key service is refused")
        await noNetwork(movedClient, beforeUnreachable, "an invalid pin fetches nothing")
        let unpinned = NeuralVoicePacks(manifest: manifest, directory: temporary.appendingPathComponent("unpinned"), defaults: defaults,
                                        downloader: VoiceDownloadStub(files: payloads, temporary: temporary), pin: { nil })
        unpinned.download(); await until { !unpinned.isDownloading }
        check(unpinned.isReady && unpinned.installedDirectory?.lastPathComponent.hasPrefix("installed-\(actual.revision)-") == true, "without a key service the bundled pin installs")
        let excessive = NeuralVoiceManifest.File(path: "oversize", size: Int64.max, sha256: String(repeating: "a", count: 64))
        expectManifestError(.init(schemaVersion: 1, repository: actual.repository, revision: actual.revision, files: files + [excessive]), "oversized manifest can't overflow progress")

        let beforeDelete = await client.requests
        let deleteDirectory = packs.installedDirectory!
        let beforeDeleteRevision = packs.installationRevision
        let deleteGate = VoiceUnloadGate()
        let deletion = Task {
            await packs.delete(beforeRemoving: {
                check(!packs.isReady && packs.status == .deleting, "deletion invalidates readiness before awaiting model unload")
                check(packs.installationRevision > beforeDeleteRevision, "deletion invalidates queued generations before unload")
                check(FileManager.default.fileExists(atPath: deleteDirectory.path), "model files exist when unload begins")
                await deleteGate.unload()
                check(FileManager.default.fileExists(atPath: deleteDirectory.path), "model files remain until unload completes")
            })
        }
        await until { deleteGate.isWaiting }
        do { _ = try await packs.requireInstalledDirectory(); check(false, "playback must wait for a new installation during deletion") } catch {}
        await packs.refresh()
        packs.download()
        await noNetwork(client, beforeDelete, "deleting pack cannot start a replacement download")
        check(!packs.isReady && packs.status == .deleting, "refresh cannot restore readiness while unload is pending")
        await packs.delete(beforeRemoving: { check(false, "duplicate deletion must not unload twice") })
        packs.cancel()
        check(packs.status == .deleting, "download cancellation cannot abandon an active deletion")
        deleteGate.finish(); await deletion.value
        check(!packs.isReady && packs.status == .notInstalled, "deleting shared pack clears readiness")
        check(!FileManager.default.fileExists(atPath: root.path), "deleting shared pack removes all installed generations")
        check(packs.selectedVoice(for: "ja")?.id == "jm_kumo", "deletion keeps voice preferences")
        do { _ = try await packs.requireInstalledDirectory(); check(false, "deleted pack must not play") } catch {}
        await noNetwork(client, beforeDelete, "deleted voice can't trigger implicit download")
        print("Neural voice catalog/download regression: \(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
