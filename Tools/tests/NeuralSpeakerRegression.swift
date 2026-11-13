import Foundation

enum Failure: Error { case injected, assets }
nonisolated enum AudioSessionUsers {
    enum User { case speech }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let gate = DispatchSemaphore(value: 0)
        var begins = 0
        var ends = 0
        var claims = 0
        var failNext = false
        var blockNext = 0
        var beganOnMain = false
    }
    private static let state = State()
    static func reset(failNext: Bool = false, blockNext: Int = 0) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.begins = 0; state.ends = 0; state.claims = 0
        state.failNext = failNext; state.blockNext = blockNext; state.beganOnMain = false
    }
    static var counts: (begins: Int, ends: Int, claims: Int, beganOnMain: Bool) {
        state.lock.lock(); defer { state.lock.unlock() }
        return (state.begins, state.ends, state.claims, state.beganOnMain)
    }
    static func begin(_ user: User) throws {
        state.lock.lock()
        state.begins += 1
        state.beganOnMain = state.beganOnMain || Thread.isMainThread
        let fail = state.failNext; state.failNext = false
        let block = state.blockNext > 0
        if block { state.blockNext -= 1 }
        if !fail { state.claims += 1 }
        state.lock.unlock()
        if fail { throw Failure.injected }
        if block { state.gate.wait() }
    }
    static func end(_ user: User) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.ends += 1; state.claims -= 1
    }
    static func unblock() { state.gate.signal() }
}
struct Language: Sendable {
    let rawValue: String
    var englishName: String { rawValue }
    static let english = Self(rawValue: "en")
    static let chinese = Self(rawValue: "zh")
}
struct NeuralVoice: Sendable, Equatable {
    let id: String
    let languageCode: String
    var name: String { id }
}
final class NeuralVoicePacks {
    static let shared = NeuralVoicePacks()
    var installedDirectory: URL? = URL(filePath: "/verified-models")
    var installationRevision = 0
    var checks = 0
    var unverifiedDirectory: URL?
    var replaceDuringVerification: URL?
    func selectedVoice(for language: String) -> NeuralVoice? {
        language == "en" ? NeuralVoice(id: "af_heart", languageCode: "en") : nil
    }
    func requireInstalledDirectory() async throws -> URL {
        checks += 1
        if let unverifiedDirectory {
            self.unverifiedDirectory = nil
            installedDirectory = replaceDuringVerification ?? unverifiedDirectory
            replaceDuringVerification = nil
            installationRevision += 1
            return unverifiedDirectory
        }
        guard let installedDirectory else { throw Failure.assets }
        return installedDirectory
    }
}
actor NeuralVoiceEngine {
    nonisolated static let maximumTextCharacters = 4_096
    private(set) var loads: [URL] = []
    private(set) var unloads = 0
    private(set) var inferences = 0
    private var loaded = false
    var suspendLoad = false
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private var unloadWaiter: CheckedContinuation<Void, Never>?
    private var suspendUnload = false
    func load(directory: URL) async throws {
        loads.append(directory)
        if suspendLoad { await withCheckedContinuation { loadWaiter = $0 } }
        loaded = true
    }
    func setSuspendLoad(_ value: Bool) { suspendLoad = value }
    func resumeLoad() { suspendLoad = false; loadWaiter?.resume(); loadWaiter = nil }
    var waitingForLoad: Bool { loadWaiter != nil }
    func setSuspendUnload(_ value: Bool) { suspendUnload = value }
    var waitingForUnload: Bool { unloadWaiter != nil }
    func resumeUnload() { suspendUnload = false; unloadWaiter?.resume(); unloadWaiter = nil }
    func unload() async {
        if suspendUnload { await withCheckedContinuation { unloadWaiter = $0 } }
        loaded = false; unloads += 1
    }
    private func canRender() -> Bool { inferences += 1; return loaded }
    nonisolated func stream(text: String, voiceID: String, language: String) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if await self.canRender() { continuation.yield([0.25, -0.25]); continuation.finish() }
                else { continuation.finish(throwing: Failure.assets) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
final class SpeechPlayer {
    enum Output: Sendable, Equatable { case automatic, headphones, speaker }
    static var supportsDirectionalOutput = true
    var preparations: [Output] = []
    var results: [Bool] = []
    var preparationError: Error?
    var suspendPreparation = false
    var pending: [CheckedContinuation<Bool, Error>] = []
    var played: [Data] = []
    var stops = 0
    var isAudible = false
    var holdPlayback = false
    func prepare(output: Output) async throws -> Bool {
        preparations.append(output)
        if let preparationError { self.preparationError = nil; throw preparationError }
        if suspendPreparation { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return results.isEmpty ? true : results.removeFirst()
    }
    func play(_ pcm: Data) {
        played.append(pcm)
        isAudible = true
        if !holdPlayback { Task { [weak self] in await Task.yield(); self?.isAudible = false } }
    }
    func stop() { stops += 1; isAudible = false }
}
protocol TranslationSpeaker: AnyObject {
    var player: SpeechPlayer { get }
    var onError: (String) -> Void { get set }
    func speak(_ text: String, in language: Language, output: SpeechPlayer.Output)
    func stop()
}

// INSERT_ACTUAL_NEURAL_SPEAKER

extension NeuralVoiceRuntime {
    func testEngine() -> NeuralVoiceEngine { engine }
}

final class Renderer: NeuralSpeechRendering {
    struct Request {
        let text: String
        let voice: NeuralVoice
        let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    }
    var requests: [Request] = []
    var failure: Error?
    var cancellations = 0
    func audio(for text: String, voice: NeuralVoice) async throws -> AsyncThrowingStream<[Float], Error> {
        if let failure { throw failure }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { Task { @MainActor in self?.cancellations += 1 } }
        }
        requests.append(Request(text: text, voice: voice, continuation: continuation))
        return stream
    }
}

final class WeakSpeaker {
    weak var value: NeuralSpeaker?
    init(_ value: NeuralSpeaker?) { self.value = value }
}

@main struct NeuralSpeakerRegression {
    static var assertions = 0
    static var failures = 0
    static let english = NeuralVoice(id: "af_heart", languageCode: "en")
    static let otherEnglish = NeuralVoice(id: "bf_emma", languageCode: "en")
    static let chinese = NeuralVoice(id: "zf_xiaoxiao", languageCode: "zh")
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            failures += 1
            print("FAIL: " + message)
            // Later controlled suspensions assume prior invariants. A broken
            // negative control must fail here rather than wait for impossible work.
            exit(1)
        }
    }
    static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        if !condition() { print("FAIL: timed out waiting for controlled work"); exit(1) }
    }
    static func tick() async { for _ in 0..<100 { await Task.yield() } }
    static func samples(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count, by: 2).map { offset in
            data.withUnsafeBytes { Int16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int16.self)) }
        }
    }
    static func collect(_ stream: AsyncThrowingStream<[Float], Error>) async throws -> [Float] {
        var result: [Float] = []
        for try await chunk in stream { result += chunk }
        try Task.checkCancellation()
        return result
    }
    static func main() async throws {
        var selection = english
        let renderer = Renderer()
        let speaker = NeuralSpeaker(renderer: renderer, voiceProvider: { _ in selection })
        speaker.speak("First.", in: .english, output: .headphones)
        selection = otherEnglish
        speaker.speak("Second.", in: .english, output: .speaker)
        await until { renderer.requests.count == 1 }
        check(renderer.requests[0].voice == english, "first line captures its selected voice")
        check(renderer.requests[0].text == "First.", "text reaches the renderer unchanged")
        renderer.requests[0].continuation.yield([0.5, -0.5])
        renderer.requests[0].continuation.finish()
        await until { renderer.requests.count == 2 }
        check(renderer.requests[1].voice == otherEnglish, "next line captures the later voice selection")
        check(speaker.player.preparations == [.headphones, .speaker], "each queued line prepares its captured output")
        check(samples(speaker.player.played[0]) == [16_384, -16_384], "native float samples become PCM16")
        renderer.requests[1].continuation.yield([0.25]); renderer.requests[1].continuation.finish()
        await until { speaker.player.played.count == 2 }
        speaker.stop()

        let privateRenderer = Renderer()
        let privateSpeaker = NeuralSpeaker(renderer: privateRenderer)
        privateSpeaker.player.results = [false]
        privateSpeaker.speak("Private.", voice: english, output: .headphones)
        await until { privateSpeaker.player.preparations.count == 1 }
        await tick()
        check(privateRenderer.requests.isEmpty, "missing headphones skip synthesis entirely")
        check(privateSpeaker.player.preparations == [.headphones], "private translations never fall back to speaker")
        privateSpeaker.stop()

        let lateRenderer = Renderer()
        let lateSpeaker = NeuralSpeaker(renderer: lateRenderer)
        var lateErrors = 0
        lateSpeaker.onError = { _ in lateErrors += 1 }
        lateSpeaker.speak("Old.", voice: english)
        await until { lateRenderer.requests.count == 1 }
        lateSpeaker.stop()
        lateSpeaker.speak("New.", voice: chinese)
        await until { lateRenderer.requests.count == 2 }
        lateRenderer.requests[0].continuation.yield([1]); lateRenderer.requests[0].continuation.finish(throwing: Failure.injected)
        lateRenderer.requests[1].continuation.yield([0.5]); lateRenderer.requests[1].continuation.finish()
        await until { lateSpeaker.player.played.count == 1 }
        check(samples(lateSpeaker.player.played[0]) == [16_384] && lateErrors == 0,
              "stale audio and failures cannot affect a newer generation")
        lateSpeaker.stop()

        let pendingRenderer = Renderer()
        let pendingSpeaker = NeuralSpeaker(renderer: pendingRenderer)
        pendingSpeaker.player.suspendPreparation = true
        pendingSpeaker.speak("Cancelled prepare.", voice: english)
        await until { pendingSpeaker.player.pending.count == 1 }
        pendingSpeaker.stop(); pendingSpeaker.player.suspendPreparation = false
        pendingSpeaker.speak("Replacement.", voice: chinese)
        await until { pendingRenderer.requests.count == 1 }
        pendingSpeaker.player.pending.removeFirst().resume(throwing: Failure.injected)
        pendingRenderer.requests[0].continuation.yield([0.2]); pendingRenderer.requests[0].continuation.finish()
        await until { pendingSpeaker.player.played.count == 1 }
        check(pendingRenderer.requests[0].voice == chinese, "cancelled preparation never reaches the old renderer")
        pendingSpeaker.stop()

        let previewRenderer = Renderer()
        let preview = NeuralSpeaker(renderer: previewRenderer)
        var statuses: [String] = []
        preview.onPreviewStatus = { statuses.append($0) }
        preview.player.results = [false, true]
        preview.player.holdPlayback = true
        var previewDone = false
        let previewTask = Task { try await preview.preview(voice: chinese); previewDone = true }
        await until { previewRenderer.requests.count == 1 }
        check(preview.player.preparations == [.headphones, .speaker], "public preview uses speaker only when headphones are absent")
        check(previewRenderer.requests[0].text.contains("你好"), "preview uses a constant in the selected language")
        previewRenderer.requests[0].continuation.yield([0.4]); previewRenderer.requests[0].continuation.finish()
        await until { !preview.player.played.isEmpty }
        await tick()
        check(!previewDone, "preview waits after synthesis while playback is audible")
        preview.player.isAudible = false
        try await previewTask.value
        check(previewDone, "preview completes after actual playback drains")
        check(statuses == ["Preparing audio…", "Preparing offline voice…", "Playing zf_xiaoxiao", ""],
              "preview status distinguishes route preparation, model work, playback and completion")

        let cancelledRenderer = Renderer()
        let cancelled = NeuralSpeaker(renderer: cancelledRenderer)
        let cancelledTask = Task { try await cancelled.preview(voice: english) }
        await until { cancelledRenderer.requests.count == 1 }
        cancelledTask.cancel()
        do { try await cancelledTask.value; check(false, "preview cancellation propagates") }
        catch is CancellationError { check(true, "preview cancellation propagates") }
        catch { check(false, "preview cancellation returned an unrelated error") }
        cancelledRenderer.requests[0].continuation.yield([1]); cancelledRenderer.requests[0].continuation.finish()
        await tick()
        check(cancelled.player.played.isEmpty, "cancelled preview drops late generated audio")

        let statusRenderer = Renderer()
        let statusSpeaker = NeuralSpeaker(renderer: statusRenderer)
        var latestStatuses: [String] = []
        statusSpeaker.onPreviewStatus = { latestStatuses.append($0) }
        let oldPreview = Task { try await statusSpeaker.preview(voice: english) }
        await until { statusRenderer.requests.count == 1 }
        statusSpeaker.stop()
        do { try await oldPreview.value } catch {}
        let statusCutoff = latestStatuses.count
        let newPreview = Task { try await statusSpeaker.preview(voice: chinese) }
        await until { statusRenderer.requests.count == 2 }
        statusRenderer.requests[0].continuation.yield([1]); statusRenderer.requests[0].continuation.finish()
        statusRenderer.requests[1].continuation.yield([0.3]); statusRenderer.requests[1].continuation.finish()
        try await newPreview.value
        check(!latestStatuses.dropFirst(statusCutoff).contains("Playing af_heart")
                && latestStatuses.dropFirst(statusCutoff).contains("Playing zf_xiaoxiao"),
              "stale preview audio never emits status for a newer request")

        let reentrantRenderer = Renderer()
        let reentrant = NeuralSpeaker(renderer: reentrantRenderer)
        reentrant.onPreviewStatus = { phase in if phase == "Preparing offline voice…" { reentrant.stop() } }
        do { try await reentrant.preview(voice: english); check(false, "status cancellation propagates") }
        catch is CancellationError { check(true, "status cancellation propagates") }
        catch { check(false, "status cancellation returns cancellation") }
        check(reentrantRenderer.requests.isEmpty, "stopping from a progress callback cannot start stale inference")
        reentrant.onPreviewStatus = { _ in }

        let failedRenderer = Renderer()
        let failed = NeuralSpeaker(renderer: failedRenderer)
        failed.player.preparationError = Failure.injected
        do { try await failed.preview(voice: english); check(false, "preview routing failure propagates") }
        catch { check(true, "preview routing failure propagates") }
        check(failed.player.preparations == [.headphones] && failedRenderer.requests.isEmpty,
              "routing failure does not become a public speaker fallback")

        let badRenderer = Renderer()
        let bad = NeuralSpeaker(renderer: badRenderer)
        var badErrors = 0
        bad.onError = { _ in badErrors += 1 }
        bad.speak("Bad samples.", voice: english)
        await until { badRenderer.requests.count == 1 }
        badRenderer.requests[0].continuation.yield([0.5, .nan]); badRenderer.requests[0].continuation.finish()
        await until { badErrors == 1 }
        check(bad.player.played.isEmpty, "a non-finite chunk is rejected before any samples are played")
        bad.speak(String(repeating: "x", count: 4_097), voice: english)
        check(badErrors == 2 && badRenderer.requests.count == 1, "oversized input fails without generating audio")
        bad.stop()
        let clamped = try NeuralSpeechPCM.encode([-2, -1, -0.5, 0, 0.5, 1, 2])
        check(samples(clamped) == [-32_768, -32_768, -16_384, 0, 16_384, 32_767, 32_767],
              "PCM conversion clamps both extremes and preserves sign")
        do { _ = try NeuralSpeechPCM.encode([.infinity]); check(false, "infinite samples rejected") }
        catch { check(true, "infinite samples rejected") }

        let externallyCancelled = Renderer()
        externallyCancelled.failure = CancellationError()
        let cancelSpeaker = NeuralSpeaker(renderer: externallyCancelled)
        cancelSpeaker.speak("Cancelled renderer.", voice: english)
        await until { cancelSpeaker.player.stops > 0 }
        check(cancelSpeaker.player.stops > 0,
              "renderer cancellation releases the prepared player's session")

        let droppedRenderer = Renderer()
        var dropped: NeuralSpeaker? = NeuralSpeaker(renderer: droppedRenderer)
        let released = WeakSpeaker(dropped)
        dropped?.speak("Release while producing.", voice: english)
        await until { droppedRenderer.requests.count == 1 }
        let droppedPlayer = dropped!.player
        dropped = nil
        await until { released.value == nil && droppedPlayer.stops > 0 }
        droppedRenderer.requests[0].continuation.yield([1]); droppedRenderer.requests[0].continuation.finish()
        await tick()
        check(droppedPlayer.played.isEmpty, "deallocation stops audio without the worker retaining its speaker")

        let engine = NeuralVoiceEngine()
        let runtime = NeuralVoiceRuntime(engine: engine)
        let directory = URL(filePath: "/verified")
        _ = try await collect(runtime.stream(text: "First.", voiceID: "af_heart", language: "en", directory: directory))
        _ = try await collect(runtime.stream(text: "Second.", voiceID: "zf_xiaoxiao", language: "zh", directory: directory))
        let loads = await engine.loads.count
        check(loads == 1, "conversation and preview jobs reuse one loaded model")
        await runtime.unload()
        do { _ = try await collect(runtime.stream(text: "Reload.", voiceID: "af_heart", language: "en", directory: directory)) }
        catch { check(false, "unloaded model reloads before another inference") }
        let reloads = await engine.loads.count
        let unloads = await engine.unloads
        check(reloads == 2 && unloads == 1, "unloading releases and invalidates the cached model")

        let sharedEngine = NeuralVoiceEngine()
        await sharedEngine.setSuspendLoad(true)
        let sharedRuntime = NeuralVoiceRuntime(engine: sharedEngine)
        let firstShared = Task { try await collect(sharedRuntime.stream(text: "One.", voiceID: "af_heart", language: "en", directory: directory)) }
        while !(await sharedEngine.waitingForLoad) { await Task.yield() }
        let secondShared = Task { try await collect(sharedRuntime.stream(text: "Two.", voiceID: "zf_xiaoxiao", language: "zh", directory: directory)) }
        await tick()
        await sharedEngine.resumeLoad()
        _ = try await firstShared.value
        _ = try await secondShared.value
        let sharedLoads = await sharedEngine.loads.count
        check(sharedLoads == 1, "overlapping speakers share the same pending model load")

        let loadingEngine = NeuralVoiceEngine()
        await loadingEngine.setSuspendLoad(true)
        let loadingRuntime = NeuralVoiceRuntime(engine: loadingEngine)
        let oldLoad = Task { try await collect(loadingRuntime.stream(text: "Old load.", voiceID: "af_heart", language: "en", directory: directory)) }
        while !(await loadingEngine.waitingForLoad) { await Task.yield() }
        await loadingRuntime.unload()
        await loadingEngine.resumeLoad()
        do { _ = try await oldLoad.value; check(false, "unload cancels an older model load") }
        catch is CancellationError { check(true, "unload cancels an older model load") }
        catch { check(false, "unload returns cancellation for old work") }
        _ = try await collect(loadingRuntime.stream(text: "Fresh load.", voiceID: "af_heart", language: "en", directory: directory))
        let loadCount = await loadingEngine.loads.count
        check(loadCount == 2, "late old load does not restore the cache after unloading")

        let unloadingEngine = NeuralVoiceEngine()
        let unloadingRuntime = NeuralVoiceRuntime(engine: unloadingEngine)
        _ = try await collect(unloadingRuntime.stream(text: "Warm.", voiceID: "af_heart", language: "en", directory: directory))
        await unloadingEngine.setSuspendUnload(true)
        let teardown = Task { await unloadingRuntime.unload() }
        while !(await unloadingEngine.waitingForUnload) { await Task.yield() }
        var resumedPreview = false
        let afterUnload = Task {
            let audio = try await collect(unloadingRuntime.stream(text: "After unload.", voiceID: "af_heart", language: "en", directory: directory))
            resumedPreview = !audio.isEmpty
        }
        await tick()
        check(!resumedPreview, "a new preview waits while the previous model is unloading")
        await unloadingEngine.resumeUnload()
        await teardown.value
        do { try await afterUnload.value }
        catch { check(false, "a preview opened during unload can recover") }
        check(resumedPreview, "new preview synthesizes after the unload barrier finishes")

        await unloadingEngine.setSuspendUnload(true)
        let secondTeardown = Task { await unloadingRuntime.unload() }
        while !(await unloadingEngine.waitingForUnload) { await Task.yield() }
        let cancelledWaiter = Task { try await collect(unloadingRuntime.stream(text: "Cancelled wait.", voiceID: "af_heart", language: "en", directory: directory)) }
        await tick()
        cancelledWaiter.cancel()
        do { _ = try await cancelledWaiter.value; check(false, "waiting preview can be cancelled") }
        catch is CancellationError { check(true, "waiting preview can be cancelled") }
        catch { check(false, "waiting preview cancellation propagates") }
        await unloadingEngine.resumeUnload()
        await secondTeardown.value
        await tick()
        let loadsAfterCancellation = await unloadingEngine.loads.count
        check(loadsAfterCancellation == 2, "cancelled unload waiter never starts another model load")

        let packs = NeuralVoicePacks.shared
        packs.installedDirectory = nil
        packs.unverifiedDirectory = directory
        packs.installationRevision = 0
        let installedRenderer = InstalledNeuralSpeechRenderer()
        do {
            let firstAudio = try await collect(try await installedRenderer.audio(for: "First verified playback.", voice: english))
            check(!firstAudio.isEmpty && packs.installationRevision == 1,
                  "first verified installation can advance revision without cancelling playback")
        } catch {
            check(false, "initially unchecked installed pack plays on its first request")
        }
        packs.installedDirectory = nil
        packs.unverifiedDirectory = directory
        packs.replaceDuringVerification = URL(filePath: "/replacement")
        do {
            _ = try await installedRenderer.audio(for: "Replaced while verifying.", voice: english)
            check(false, "replacement during verification cancels the old directory")
        } catch is CancellationError { check(true, "replacement during verification cancels the old directory") }
        catch { check(false, "replaced verification returns cancellation") }

        await NeuralVoiceRuntime.shared.unload()
        let installedEngine = await NeuralVoiceRuntime.shared.testEngine()
        let inferenceCount = await installedEngine.inferences
        packs.installedDirectory = directory
        packs.installationRevision += 1
        await installedEngine.setSuspendLoad(true)
        let invalidatedLoad = Task {
            try await collect(try await installedRenderer.audio(for: "Deleted during model load.", voice: english))
        }
        while !(await installedEngine.waitingForLoad) { await Task.yield() }
        packs.installedDirectory = nil
        packs.installationRevision += 1
        await installedEngine.resumeLoad()
        do {
            _ = try await invalidatedLoad.value
            check(false, "deleting a pack during model load cancels inference")
        } catch is CancellationError { check(true, "deleting a pack during model load cancels inference") }
        catch { check(false, "deleting a pack returns cancellation") }
        let invalidatedInferences = await installedEngine.inferences
        check(invalidatedInferences == inferenceCount, "invalidated directory never reaches model inference")
        await NeuralVoiceRuntime.shared.unload()

        AudioSessionUsers.reset()
        let alreadyClosed = NeuralPreviewLease()
        alreadyClosed.close()
        do { try alreadyClosed.acquire(); check(false, "closed lease never activates") }
        catch is CancellationError { check(true, "closed lease never activates") }
        catch { check(false, "closed lease returns cancellation") }
        check(AudioSessionUsers.counts.begins == 0 && AudioSessionUsers.counts.claims == 0,
              "closing before detached activation avoids starting an audio session")
        let holder = NeuralPreviewSession()
        try await holder.prepare(); try await holder.prepare()
        check(AudioSessionUsers.counts.begins == 1 && AudioSessionUsers.counts.claims == 1,
              "successive previews share one stable audio-session claim")
        check(!AudioSessionUsers.counts.beganOnMain, "audio-session activation runs off the main thread")
        holder.close(); holder.close()
        check(AudioSessionUsers.counts.ends == 1 && AudioSessionUsers.counts.claims == 0,
              "closing a preview library releases exactly once")

        AudioSessionUsers.reset(failNext: true)
        let failedHolder = NeuralPreviewSession()
        do { try await failedHolder.prepare(); check(false, "activation failure propagates") }
        catch { check(true, "activation failure propagates") }
        check(AudioSessionUsers.counts.claims == 0 && AudioSessionUsers.counts.ends == 0,
              "failed activation does not release another owner's claim")
        try await failedHolder.prepare()
        check(AudioSessionUsers.counts.begins == 2 && AudioSessionUsers.counts.claims == 1,
              "preview session can retry after activation failure")
        failedHolder.close()

        AudioSessionUsers.reset(blockNext: 1)
        let replacedHolder = NeuralPreviewSession()
        let oldActivation = Task { try await replacedHolder.prepare() }
        await until { AudioSessionUsers.counts.begins == 1 }
        replacedHolder.close()
        try await replacedHolder.prepare()
        AudioSessionUsers.unblock()
        do { try await oldActivation.value; check(false, "closed activation stays cancelled") }
        catch is CancellationError { check(true, "closed activation stays cancelled") }
        catch { check(false, "closed activation returns cancellation") }
        check(AudioSessionUsers.counts.claims == 1 && AudioSessionUsers.counts.ends == 1,
              "late old activation releases only its own claim")
        replacedHolder.close()
        check(AudioSessionUsers.counts.claims == 0 && AudioSessionUsers.counts.ends == 2,
              "replacement activation releases its separate claim")

        AudioSessionUsers.reset(blockNext: 1)
        let cancelledHolder = NeuralPreviewSession()
        let cancelledActivation = Task { try await cancelledHolder.prepare() }
        await until { AudioSessionUsers.counts.begins == 1 }
        cancelledActivation.cancel()
        let sharedActivation = Task { try await cancelledHolder.prepare() }
        AudioSessionUsers.unblock()
        do { try await cancelledActivation.value; check(false, "cancelled preview preparation propagates") }
        catch is CancellationError { check(true, "cancelled preview preparation propagates") }
        catch { check(false, "cancelled preparation returns cancellation") }
        try await sharedActivation.value
        check(AudioSessionUsers.counts.begins == 1 && AudioSessionUsers.counts.claims == 1,
              "cancelling one click preserves activation for the next preview")
        cancelledHolder.close()

        AudioSessionUsers.reset()
        var releasedHolder: NeuralPreviewSession? = NeuralPreviewSession()
        try await releasedHolder!.prepare()
        releasedHolder = nil
        check(AudioSessionUsers.counts.claims == 0 && AudioSessionUsers.counts.ends == 1,
              "releasing the library owner closes its session claim")

        print("Neural speaker regression: \(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
