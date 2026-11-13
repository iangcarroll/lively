import Foundation

enum ScenePhase { case active, inactive, background }
enum Failure: LocalizedError {
    case late
    var errorDescription: String? { "late preview failure" }
}
struct NeuralVoice: Equatable {
    let id: String
    static let first = Self(id: "af_heart")
    static let second = Self(id: "jf_alpha")
    static let third = Self(id: "zf_xiaoxiao")
}
final class AppSettings { var speaksTranslations = false }
enum SpeechPlayer { static var supportsDirectionalOutput = true }
enum AudioSessionUsers {
    static var configurations: [Bool] = []
    static func setDirectionalSpeechEnabled(_ value: Bool) { configurations.append(value) }
}
final class NeuralPreviewSession {
    var preparations = 0
    var closes = 0
    var suspend = false
    var pending: [CheckedContinuation<Void, Error>] = []
    func prepare() async throws {
        preparations += 1
        if suspend { try await withCheckedThrowingContinuation { pending.append($0) } }
    }
    func close() { closes += 1 }
}
final class NeuralSpeaker {
    static var instances: [NeuralSpeaker] = []
    var onPreviewStatus: (String) -> Void = { _ in }
    var voices: [NeuralVoice] = []
    var pending: [CheckedContinuation<Void, Error>] = []
    var stops = 0
    init() { Self.instances.append(self) }
    func preview(voice: NeuralVoice) async throws {
        voices.append(voice)
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    // Uncooperative completion/status callbacks are intentional: the UI's
    // own generation guards must handle a dependency returning after stop.
    func stop() { stops += 1; onPreviewStatus("Stopped old preview") }
    func emit(_ value: String) { onPreviewStatus(value) }
    func finish(_ error: Error? = nil) {
        guard !pending.isEmpty else { return }
        let continuation = pending.removeFirst()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
final class NeuralVoicePacks {
    var refreshes = 0
    func refresh() async { refreshes += 1 }
}
// Reference-backed, nonmutating state matches the production SwiftUI structs
// while letting their method bodies compile and run without a UI host.
@propertyWrapper struct TestState<Value> {
    private final class Storage {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    private let storage: Storage
    init(wrappedValue: Value) { storage = Storage(wrappedValue) }
    var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }
}
final class PauseCount { var value = 0 }
final class ConversationStore {
    var isListening = true
    var hasQueuedSpeech = true
    var calls: [String] = []
    func stopListening() { isListening = false; calls.append("stopListening") }
    func speechRoutingDidChange() { hasQueuedSpeech = false; calls.append("speechRoutingDidChange") }
}
struct ConversationPreviewBridge {
    let store = ConversationStore()
    // INSERT_CONVERSATION_PAUSE
}
struct SettingsView {
    let settings = AppSettings()
    var onPauseForVoicePreview: () -> Void = {}
    @TestState private var voicePreview: NeuralSpeaker?
    let voicePreviewSession = NeuralPreviewSession()
    @TestState private(set) var voicePreviewStatus: String?
    @TestState private var voicePreviewOperation = UUID()
    private let pauseCount = PauseCount()
    var pauses: Int { pauseCount.value }
    init(onPause: (() -> Void)? = nil) {
        let pauseCount = pauseCount
        onPauseForVoicePreview = onPause ?? { pauseCount.value += 1 }
    }
    func begin(_ voice: NeuralVoice) async throws { try await previewVoice(voice) }
    func stop() { stopVoicePreview() }
    func close() { closeVoicePreview() }
    var current: NeuralSpeaker? { voicePreview }
    // INSERT_SETTINGS_METHODS
    // INSERT_SETTINGS_SCENE
}
struct OfflineVoiceLibraryView {
    let packs = NeuralVoicePacks()
    var onPreview: @MainActor (NeuralVoice) async throws -> Void
    var onStopPreview: @MainActor () -> Void
    @TestState private(set) var previewingID: String?
    @TestState private(set) var previewError: String?
    @TestState private(set) var previewTask: Task<Void, Never>?
    @TestState private var previewOperation = UUID()
    init(onPreview: @escaping @MainActor (NeuralVoice) async throws -> Void,
         onStopPreview: @escaping @MainActor () -> Void = {}) {
        self.onPreview = onPreview
        self.onStopPreview = onStopPreview
    }
    func tap(_ voice: NeuralVoice) { preview(voice) }
    func stop() { stopPreview() }
    // INSERT_LIBRARY_METHODS
    // INSERT_LIBRARY_SCENE
}
final class PreviewCallbacks {
    struct Request { let voice: NeuralVoice; let continuation: CheckedContinuation<Void, Error> }
    var requests: [Request] = []
    var stops = 0
    func start(_ voice: NeuralVoice) async throws {
        try await withCheckedThrowingContinuation { requests.append(Request(voice: voice, continuation: $0)) }
    }
    func finish(_ index: Int, error: Error? = nil) {
        if let error { requests[index].continuation.resume(throwing: error) }
        else { requests[index].continuation.resume() }
    }
}

@main struct VoicePreviewLifecycleRegression {
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { print("FAIL: " + message); exit(1) }
    }
    static func until(_ value: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !value(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        if !value() { print("FAIL: timed out waiting for controlled UI work"); exit(1) }
    }
    static func tick() async { for _ in 0..<200 { await Task.yield() } }
    static func ignoreCancellation(_ task: Task<Void, Error>) async {
        do { try await task.value } catch is CancellationError {} catch { check(false, "unexpected preview error") }
    }
    static func reset() { AudioSessionUsers.configurations = []; NeuralSpeaker.instances = [] }

    static func main() async {
        reset()
        let cancelledEntry = SettingsView()
        let beforeEntry = Task { try await cancelledEntry.begin(.first) }
        beforeEntry.cancel()
        await ignoreCancellation(beforeEntry)
        check(cancelledEntry.pauses == 0, "cancel-before-entry never pauses conversation listening")
        check(cancelledEntry.voicePreviewSession.preparations == 0, "cancel-before-entry never activates preview audio")
        check(AudioSessionUsers.configurations.isEmpty && NeuralSpeaker.instances.isEmpty,
              "cancel-before-entry has no audio-mode or speaker side effects")

        let bridge = ConversationPreviewBridge()
        let previewWithConversation = SettingsView(onPause: { bridge.pauseForPreview() })
        previewWithConversation.voicePreviewSession.suspend = true
        let conversationPreview = Task { try await previewWithConversation.begin(.first) }
        await until { previewWithConversation.voicePreviewSession.pending.count == 1 }
        check(!bridge.store.isListening && !bridge.store.hasQueuedSpeech,
              "entering a preview stops capture and cancels already queued conversation speech")
        check(bridge.store.calls == ["stopListening", "speechRoutingDidChange"],
              "conversation capture stops before its speech routing is invalidated")
        previewWithConversation.close()
        previewWithConversation.voicePreviewSession.pending.removeFirst().resume()
        await tick()
        check(NeuralSpeaker.instances.isEmpty, "closed conversation preview cannot enter late synthesis")
        await ignoreCancellation(conversationPreview)

        reset()
        var rapidCallbacks: [String] = []
        let rapid = OfflineVoiceLibraryView(onPreview: { rapidCallbacks.append($0.id) })
        rapid.tap(.first)
        rapid.tap(.second)
        rapid.tap(.third)
        await tick()
        check(rapidCallbacks == [NeuralVoice.third.id], "rapid taps before tasks begin invoke only the latest preview")
        check(rapid.previewingID == nil && rapid.previewTask == nil, "completed latest preview clears its UI state")

        reset()
        let closedActivation = SettingsView()
        closedActivation.voicePreviewSession.suspend = true
        let activation = Task { try await closedActivation.begin(.first) }
        await until { closedActivation.voicePreviewSession.pending.count == 1 }
        check(closedActivation.voicePreviewStatus == "Preparing audio…" && closedActivation.pauses == 1,
              "activation reports progress after pausing live listening")
        closedActivation.close()
        check(closedActivation.voicePreviewSession.closes == 1 && closedActivation.current == nil,
              "closing settings closes its held preview session")
        check(AudioSessionUsers.configurations == [true, false], "closing restores disabled speech routing")
        closedActivation.voicePreviewSession.pending.removeFirst().resume()
        await tick()
        check(NeuralSpeaker.instances.isEmpty, "closed activation cannot enter late synthesis")
        await ignoreCancellation(activation)
        check(NeuralSpeaker.instances.isEmpty && closedActivation.voicePreviewStatus == nil,
              "a closed activation cannot start late speech or restore old status")

        reset()
        let stoppedActivation = SettingsView()
        stoppedActivation.voicePreviewSession.suspend = true
        let stoppedTask = Task { try await stoppedActivation.begin(.first) }
        await until { stoppedActivation.voicePreviewSession.pending.count == 1 }
        stoppedActivation.stop()
        stoppedActivation.voicePreviewSession.pending.removeFirst().resume()
        await ignoreCancellation(stoppedTask)
        check(NeuralSpeaker.instances.isEmpty && stoppedActivation.voicePreviewStatus == nil,
              "stopping a pending activation invalidates its completion")
        check(stoppedActivation.voicePreviewSession.closes == 0,
              "stopping a single preview preserves the library's session holder")
        stoppedActivation.close()

        reset()
        let generations = SettingsView()
        generations.voicePreviewSession.suspend = true
        let oldActivation = Task { try await generations.begin(.first) }
        await until { generations.voicePreviewSession.pending.count == 1 }
        generations.stop()
        let newerActivation = Task { try await generations.begin(.second) }
        await until { generations.voicePreviewSession.pending.count == 2 }
        generations.voicePreviewSession.pending.removeFirst().resume()
        await ignoreCancellation(oldActivation)
        check(generations.voicePreviewStatus == "Preparing audio…", "stale activation cleanup cannot clear the newer progress")
        generations.voicePreviewSession.pending.removeFirst().resume()
        await until { NeuralSpeaker.instances.count == 1 && NeuralSpeaker.instances[0].pending.count == 1 }
        let firstSpeaker = NeuralSpeaker.instances[0]
        firstSpeaker.emit("Playing second")
        check(generations.voicePreviewStatus == "Playing second", "current speaker can publish preview progress")
        let replacement = Task { try await generations.begin(.third) }
        await until { generations.voicePreviewSession.pending.count == 1 }
        check(firstSpeaker.stops == 1, "a replacement preview stops its previous player")
        generations.voicePreviewSession.pending.removeFirst().resume()
        await until { NeuralSpeaker.instances.count == 2 && NeuralSpeaker.instances[1].pending.count == 1 }
        let replacementSpeaker = NeuralSpeaker.instances[1]
        replacementSpeaker.emit("Playing third")
        firstSpeaker.emit("Playing stale second")
        check(generations.voicePreviewStatus == "Playing third", "stale in-flight status cannot override the newer speaker")
        firstSpeaker.finish()
        try? await newerActivation.value
        check(generations.voicePreviewStatus == "Playing third", "stale preview defer cannot clear newer playback status")
        replacementSpeaker.finish()
        try? await replacement.value
        check(generations.voicePreviewStatus == nil, "completed current preview clears progress")
        generations.close()

        reset()
        let failures = PreviewCallbacks()
        let library = OfflineVoiceLibraryView(onPreview: { try await failures.start($0) },
                                              onStopPreview: { failures.stops += 1 })
        library.tap(.first)
        await until { failures.requests.count == 1 }
        let oldLibraryTask = library.previewTask!
        library.tap(.second)
        await until { failures.requests.count == 2 }
        let currentLibraryTask = library.previewTask!
        failures.finish(0, error: Failure.late)
        await oldLibraryTask.value
        check(library.previewError == nil, "late cancelled preview errors remain suppressed")
        check(library.previewingID == NeuralVoice.second.id && library.previewTask != nil,
              "stale library defer leaves newer selection and task intact")
        failures.finish(1, error: Failure.late)
        await currentLibraryTask.value
        check(library.previewError == Failure.late.localizedDescription, "current preview failure is visible")
        check(library.previewingID == nil && library.previewTask == nil, "failed current preview clears its active state")

        let sameCallbacks = PreviewCallbacks()
        let same = OfflineVoiceLibraryView(onPreview: { try await sameCallbacks.start($0) },
                                           onStopPreview: { sameCallbacks.stops += 1 })
        same.tap(.first)
        await until { sameCallbacks.requests.count == 1 }
        let sameTask = same.previewTask!
        same.tap(.first)
        sameCallbacks.finish(0, error: Failure.late)
        await sameTask.value
        check(sameCallbacks.requests.count == 1 && same.previewingID == nil,
              "tapping the active voice stops it instead of queuing another preview")
        check(same.previewError == nil, "toggling a voice off suppresses its late error")

        reset()
        let backgroundSettings = SettingsView()
        backgroundSettings.settings.speaksTranslations = true
        backgroundSettings.voicePreviewSession.suspend = true
        let heldBackground = Task { try await backgroundSettings.begin(.first) }
        await until { backgroundSettings.voicePreviewSession.pending.count == 1 }
        backgroundSettings.sceneChanged(.inactive)
        check(backgroundSettings.voicePreviewSession.closes == 1 && AudioSessionUsers.configurations.last == true,
              "becoming inactive closes previews and restores enabled speech routing")
        backgroundSettings.voicePreviewSession.pending.removeFirst().resume()
        await ignoreCancellation(heldBackground)
        check(NeuralSpeaker.instances.isEmpty, "inactive activation cannot start speech afterward")
        backgroundSettings.sceneChanged(.active)
        check(backgroundSettings.voicePreviewSession.closes == 1, "becoming active does not close another session")

        reset()
        let settingsBridge = SettingsView()
        let backgroundLibrary = OfflineVoiceLibraryView(onPreview: { try await settingsBridge.begin($0) },
                                                        onStopPreview: { settingsBridge.stop() })
        backgroundLibrary.tap(.first)
        backgroundLibrary.sceneChanged(.background)
        settingsBridge.sceneChanged(.background)
        await tick()
        check(settingsBridge.pauses == 0 && settingsBridge.voicePreviewSession.preparations == 0,
              "backgrounding before a library task starts never enters settings playback")
        check(backgroundLibrary.previewingID == nil && backgroundLibrary.previewTask == nil,
              "backgrounding cancels queued library preview state")
        check(settingsBridge.voicePreviewSession.closes == 1 && AudioSessionUsers.configurations.last == false,
              "background cleanup releases the library holder and restores the idle mode")
        backgroundLibrary.sceneChanged(.active)
        await until { backgroundLibrary.packs.refreshes == 1 }
        check(backgroundLibrary.packs.refreshes == 1, "foregrounding rechecks downloaded files")

        print("Voice preview lifecycle: \(assertions) assertions, 0 failures")
    }
}
