import Foundation
import Network
import Observation
import Translation
#if os(iOS)
import UIKit
#endif

/// Drives a live conversation: mic → speech engine → turns → translation.
///
/// The engine comes from the provider chosen in Settings. Engines that only
/// transcribe report deltas and turn boundaries, and turns are translated
/// here with a `TranslationService`. Engines that translate by themselves
/// report whole segments, which map one-to-one onto utterances.
@Observable
final class ConversationStore {
    enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case live
        case reconnecting
        case offline
        case failed(String)
    }

    private(set) var utterances: [Utterance] = []
    private(set) var isListening = false
    private(set) var status: ConnectionStatus = .idle
    private(set) var isOnline = true
    /// Listening, but the speech service isn't connected yet, so nobody is heard.
    var isConnecting: Bool { isListening && (status == .connecting || status == .reconnecting) }
    /// Smoothed mic level for the meter, 0...1.
    private(set) var level: Float = 0
    /// The noise gate is letting the mic through: someone is close enough to translate.
    private(set) var isHearing = false
    var alert: String?

    private let settings: AppSettings
    /// The languages of the turns in `utterances`.
    private var languages: LanguagePair
    private let mic = MicCapture()
    private var engine: SpeechEngine?
    /// The provider `engine` was built from, so a different one isn't resumed.
    private var engineProviderID: String?
    private let pathMonitor = NWPathMonitor()
    private var translator: TranslationService?
    /// The chosen provider's translator, and the one used while the local
    /// stopgap is in charge.
    private var primaryTranslator: TranslationService?
    private var fallbackTranslator: TranslationService?
    /// The local engine is transcribing while the server session connects.
    private var usingStopgap = false
    /// Provisional turns stay visible until the server produces its first
    /// real transcript, so the handoff doesn't blank the conversation.
    private var pendingDiscard: TimeInterval?
    /// True while the on-device engine is standing in for the chosen provider.
    private(set) var isUsingOnDevice = false
    /// A cloud engine failed and the on-device engine took over this session.
    private var didFallBackToOnDevice = false

    /// The turn currently receiving transcript text.
    private var current: Utterance?
    private var translations: [UUID: Task<Void, Never>] = [:]
    private var debounces: [UUID: Task<Void, Never>] = [:]
    private var silenceTimer: Task<Void, Never>?
    private var transcriberStatus: SpeechEngineStatus = .idle
    /// Utterances of recent segments from a translating engine, by segment id.
    private var segmentUtterances: [Int: Utterance] = [:]
    /// Utterances of segments from a catch-up session, by segment id.
    private var catchUpUtterances: [Int: Utterance] = [:]
    /// Where speech from the last dropout belongs in `utterances`.
    private var dropoutIndex: Int?
    /// The interface the network path last used, to spot handoffs.
    private var interface: NWInterface.InterfaceType?
    private var demo: DemoConversation?
    private var audioPump: Task<Void, Never>?
    /// A press can end while permission or audio startup is still pending.
    private var listeningStart: Task<Void, Never>?
    private var listeningGeneration = UUID()
    /// Sends quiet chunks as silence, per the pickup range in Settings.
    private var gate = NoiseGate()
    /// Ends a paused engine's session once it's been idle for `warmPause`.
    private var idleTeardown: Task<Void, Never>?
    /// How long a paused session stays open for a quick resume. Soniox bills
    /// for the open stream, so this is kept short.
    private static let warmPause: Duration = .seconds(60)
    /// Settings changed while listening, so the engine isn't kept warm.
    private var engineIsStale = false
    /// Speech-to-speech: reads translations into the second language aloud.
    /// Made when first needed.
    private var speaker: (any TranslationSpeaker)?
    private var speakerUsesOnDevice = false
    /// Characters of each turn's translation already sent to the speaker;
    /// `Int.max` once the whole turn has been.
    private var spoken: [UUID: Int] = [:]
    /// Speaks a translation's unpunctuated tail once it stops growing.
    private var speechFlushes: [UUID: Task<Void, Never>] = [:]
    /// Turns from before speech-to-speech was switched on aren't read out.
    private var speakingSince: Date?

    init(settings: AppSettings = .shared, demo: Bool = false) {
        self.settings = settings
        languages = settings.languages
        if settings.speaksTranslations { speakingSince = .now }
        if demo {
            self.demo = DemoConversation()
            self.translator = DemoTranslator()
        }

        // One stream keeps chunks in order on their way from the audio thread.
        let (chunks, continuation) = AsyncStream<(Data, Float)>.makeStream(bufferingPolicy: .bufferingNewest(500))
        mic.onChunk = { chunk, decibels in continuation.yield((chunk, decibels)) }
        audioPump = Task { [weak self] in
            for await (chunk, decibels) in chunks {
                guard let self else { return }
                guard self.isListening else { continue }
                // Gated chunks go as silence rather than not at all, so the
                // engine still hears the pause and ends the turn.
                // While a translation is read aloud the mic would hear it and
                // translate it back, so it sends silence (but not into headphones).
                let heard = self.gate.process(decibels, range: self.settings.pickupRange)
                    && !(self.speaker?.player.mutesMic ?? false)
                self.isHearing = heard
                self.engine?.send(heard ? chunk : Data(count: chunk.count))
                self.level = self.level * 0.6 + MicCapture.meterLevel(decibels) * 0.4
            }
        }
        mic.onInterrupted = { [weak self] in
            self?.stopListening()
            self?.alert = "The microphone stopped. Tap the mic to start again."
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let interface = path.availableInterfaces.first?.type
            Task { @MainActor in
                self?.setPath(online: online, interface: interface)
                // A new interface or route can change which region is closest.
                if online { self?.regionProber?.probe(minimumInterval: 5) }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "lively.path"))
        speechSettingChanged()
        regionProber?.probe()
        prefetchKey()
    }

    /// Only the first screen to appear in a launch prewarms.
    private static var didPrewarm = false

    /// Opens a speech session as the app launches, so the first tap on the
    /// mic is live at once instead of waiting on the connect. It's held like
    /// a pause and closed after `warmPause` if nobody starts listening. Call
    /// it once onboarding is done, which asks for the mic and may change the
    /// languages. Not from `init`: SwiftUI makes and throws away stores while
    /// it re-renders, and each would open a session.
    func prewarm() {
        guard !Self.didPrewarm, demo == nil, engine == nil, !isListening, settings.hasCredentials else { return }
        Self.didPrewarm = true
        makeEngine(settings.provider).prewarm()
        scheduleIdleTeardown()
    }

    /// Re-measures Soniox regions and gets a key ready when the app comes to
    /// the foreground, so tapping the mic doesn't wait on the key broker.
    func didBecomeActive() {
        regionProber?.probe()
        prefetchKey()
    }

    /// The app went to the background, where iOS takes the mic and suspends
    /// sockets: stop, and don't keep a session warm.
    func didEnterBackground() {
        stopListening()
        releaseEngine()
    }

    private func prefetchKey() {
        guard regionProber != nil else { return }
        SonioxKeyProvider.shared?.prefetch()
    }

    /// Set when Soniox keys come from the broker, which mints in any of its regions.
    private var regionProber: RegionProber? {
        guard demo == nil, settings.providerID == SpeechProvider.soniox.id,
              settings.credential(.soniox).isEmpty else { return nil }
        return SonioxKeyProvider.shared?.regions
    }

    // MARK: - Listening

    func toggleListening() {
        if isListening || listeningStart != nil {
            stopListening()
        } else {
            startListening()
        }
    }

    func startListening() {
        guard !isListening, listeningStart == nil else { return }
        if let demo {
            isListening = true
            transcriberStatus = .live
            refreshStatus()
            demo.play(into: self)
            return
        }
        let provider = settings.provider
        guard provider.id == SpeechProvider.onDevice.id || settings.hasCredentials else {
            let names = provider.credentials.map(\.name).formatted(.list(type: .and))
            alert = "Add your \(names) in Settings to start."
            return
        }
        let generation = UUID()
        listeningGeneration = generation
        listeningStart = Task {
            defer {
                if listeningGeneration == generation { listeningStart = nil }
            }
            let permitted = await MicCapture.requestPermission()
            guard !Task.isCancelled, listeningGeneration == generation else { return }
            guard permitted else {
                alert = "Lively needs microphone access. You can turn it on in Settings › Privacy & Security › Microphone."
                return
            }
            guard !isListening else { return }
            isListening = true
            gate.reset()
            // Someone wants to talk: cut off a translation being read out.
            speaker?.stop()
            Self.keepScreenAwake(true)
            // Connect while the mic starts up. Audio that arrives before the
            // session is ready waits in the socket's backlog.
            startEngine(provider)
            guard !Task.isCancelled, listeningGeneration == generation, isListening else { return }
            do {
                // Capture serializes graph changes off the main thread.
                try await mic.start()
            } catch {
                guard !Task.isCancelled, listeningGeneration == generation else { return }
                stopListening()
                releaseEngine()
                alert = error.localizedDescription
                return
            }
            // stopListening already stopped this request. A newer press may
            // now own the mic, so an old completion must leave it alone.
        }
    }

    private func startEngine(_ provider: SpeechProvider) {
        if let engine, engineProviderID == provider.id, !(engine is HybridSpeechEngine) {
            // Still warm from the last pause.
            idleTeardown?.cancel()
            idleTeardown = nil
            engine.resume()
            refreshStatus()
            return
        }
        // A session built for another provider can't be reused, and a hybrid
        // one restarts from the local stopgap on every listen.
        if let engine {
            engine.stop()
            self.engine = nil
            engineProviderID = nil
        }
        makeEngine(provider).start()
    }

    private func makeEngine(_ provider: SpeechProvider) -> SpeechEngine {
        let pipeline = provider.makePipeline(settings)
        primaryTranslator = pipeline.translator
        fallbackTranslator = pipeline.fallbackTranslator
        let engine = pipeline.engine
        if let hybrid = engine as? HybridSpeechEngine {
            // The on-device model is the stopgap until the server connects,
            // and translates its provisional turns itself.
            translator = pipeline.fallbackTranslator
            isUsingOnDevice = true
            usingStopgap = true
            hybrid.onSourceChange = { [weak self] source, replayed in
                self?.sourceChanged(source, replayed: replayed)
            }
        } else {
            translator = pipeline.translator
            isUsingOnDevice = provider.id == SpeechProvider.onDevice.id
            usingStopgap = false
        }
        engine.onEvent = { [weak self] in self?.handle($0) }
        engine.onStatus = { [weak self] status in
            guard let self else { return }
            if case .failed(let message) = status, self.canFallBackToOnDevice {
                self.fallBackToOnDevice(reason: message)
                return
            }
            self.transcriberStatus = status
            if self.isListening {
                self.refreshStatus()
            } else if case .failed = status {
                // A paused session failed; start over next time.
                self.releaseEngine()
            }
        }
        engine.networkAvailable = isOnline
        self.engine = engine
        engineProviderID = provider.id
        return engine
    }

    /// The hybrid engine moved between the local stopgap and the server.
    private func sourceChanged(_ source: HybridSpeechEngine.Source, replayed: TimeInterval) {
        switch source {
        case .local:
            translator = fallbackTranslator
            isUsingOnDevice = true
            usingStopgap = true
            pendingDiscard = nil
        case .cloud:
            translator = primaryTranslator
            isUsingOnDevice = false
            usingStopgap = false
            // Keep the local turns until the server says something; the
            // first substantial server result replaces the matching ones.
            pendingDiscard = replayed
        }
        refreshStatus()
    }

    /// Removes the on-device turns whose audio the server just re-transcribed.
    /// Turns older than the replayed window stay; they weren't sent again.
    private func discardProvisionalTurns(replayed: TimeInterval) {        let cutoff = Date().addingTimeInterval(-replayed)
        let doomed = utterances.filter {
            $0.isProvisional && ($0.createdAt >= cutoff || $0 === current)
        }
        guard !doomed.isEmpty else { return }
        let identifiers = Set(doomed.map { ObjectIdentifier($0) })
        for utterance in doomed {
            translations.removeValue(forKey: utterance.id)?.cancel()
            debounces.removeValue(forKey: utterance.id)?.cancel()
            speechFlushes.removeValue(forKey: utterance.id)?.cancel()
            spoken[utterance.id] = Int.max
            if current === utterance { current = nil }
        }
        utterances.removeAll { identifiers.contains(ObjectIdentifier($0)) }
        segmentUtterances = segmentUtterances.filter { !identifiers.contains(ObjectIdentifier($0.value)) }
        catchUpUtterances = catchUpUtterances.filter { !identifiers.contains(ObjectIdentifier($0.value)) }
    }

    /// Waits for a substantial server result before replacing the stopgap
    /// turns, so the transcript doesn't go blank during the handoff.
    private func discardPendingIfReady(length: Int) {
        guard let replayed = pendingDiscard, length >= 10 else { return }
        pendingDiscard = nil
        discardProvisionalTurns(replayed: replayed)
    }

    /// A cloud engine failed before the fallback was already in use.
    private var canFallBackToOnDevice: Bool {
        isListening && !isUsingOnDevice && !didFallBackToOnDevice
            && SpeechProvider.onDevice.supports(languages)
    }

    /// Replaces a failed cloud session with the on-device one, keeping the
    /// microphone and the rest of the conversation running.
    private func fallBackToOnDevice(reason: String) {
        guard canFallBackToOnDevice else { return }
        didFallBackToOnDevice = true
        isUsingOnDevice = true
        // The failed session's turn can't continue on the new engine.
        handle(.sessionReset)
        engine?.stop()
        engine = nil
        engineProviderID = nil
        transcriberStatus = .connecting
        makeEngine(.onDevice).start()
        refreshStatus()
    }

    func stopListening() {
        listeningGeneration = UUID()
        listeningStart?.cancel()
        listeningStart = nil
        guard isListening else { return }
        isListening = false
        demo?.stop()
        mic.stop()
        pauseEngine()
        level = 0
        isHearing = false
        Self.keepScreenAwake(false)
        // Turns heard while the server was still connecting stay in the
        // transcript if listening ends before it does.
        for utterance in utterances where utterance.isProvisional {
            utterance.isProvisional = false
        }
        pendingDiscard = nil
        finalizeCurrent()
        refreshStatus()
    }

    /// Turns with something to show: not empty, and not only filler words.
    var visibleUtterances: [Utterance] { utterances.filter(\.hasContent) }

    /// Keeps the engine's session open for `warmPause`, so listening again
    /// right away doesn't reconnect.
    private func pauseEngine() {
        guard let engine else { return }
        guard !engineIsStale else {
            releaseEngine()
            return
        }
        engine.pause()
        scheduleIdleTeardown()
    }

    private func scheduleIdleTeardown() {
        idleTeardown?.cancel()
        idleTeardown = Task { [weak self] in
            try? await Task.sleep(for: Self.warmPause)
            guard !Task.isCancelled else { return }
            self?.releaseEngine()
        }
    }

    /// Settings can change the provider or key, which a warm session can't
    /// pick up, so the next start builds a new engine.
    func settingsDidClose() {
        if languages != settings.languages {
            // Turns in the old languages don't fit the new pair, and the
            // engine listens for the old one.
            languages = settings.languages
            stopListening()
            clear()
        }
        // The Soniox key may have changed.
        speaker?.stop()
        speaker = nil
        speechSettingChanged()
        if isListening { engineIsStale = true } else { releaseEngine() }
    }

    /// Closes a paused engine's session.
    private func releaseEngine() {
        guard !isListening else { return }
        engineIsStale = false
        idleTeardown?.cancel()
        idleTeardown = nil
        engine?.stop()
        engine = nil
        engineProviderID = nil
        isUsingOnDevice = false
        didFallBackToOnDevice = false
        usingStopgap = false
        pendingDiscard = nil
        primaryTranslator = nil
        fallbackTranslator = nil
        translator = nil
        transcriberStatus = .idle
    }

    func clear() {
        speaker?.stop()
        spoken.removeAll()
        speechFlushes.values.forEach { $0.cancel() }
        speechFlushes.removeAll()
        translations.values.forEach { $0.cancel() }
        debounces.values.forEach { $0.cancel() }
        translations.removeAll()
        debounces.removeAll()
        current = nil
        segmentUtterances.removeAll()
        catchUpUtterances.removeAll()
        dropoutIndex = nil
        pendingDiscard = nil
        utterances.removeAll()
    }

    /// Removes one turn. A translating engine's later updates to that
    /// segment go to the removed utterance, so it stays gone; words still
    /// arriving for a removed transcript-only turn start a new one.
    func delete(_ utterance: Utterance) {
        guard let index = utterances.firstIndex(where: { $0 === utterance }) else { return }
        translations.removeValue(forKey: utterance.id)?.cancel()
        debounces.removeValue(forKey: utterance.id)?.cancel()
        speechFlushes.removeValue(forKey: utterance.id)?.cancel()
        spoken[utterance.id] = Int.max
        if current === utterance { current = nil }
        utterances.remove(at: index)
        if let dropoutIndex, index < dropoutIndex { self.dropoutIndex = dropoutIndex - 1 }
    }

    /// Replaces a finished turn's transcript, such as a misheard name, and
    /// translates it again with the typed-text translator. The old
    /// translation stays until the new one is complete.
    func edit(_ utterance: Utterance, to text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard utterance.isFinal, !text.isEmpty, text != utterance.trimmedSource else { return }
        translations.removeValue(forKey: utterance.id)?.cancel()
        debounces.removeValue(forKey: utterance.id)?.cancel()
        // A translating engine's late update to the segment must not undo the edit.
        segmentUtterances = segmentUtterances.filter { $0.value !== utterance }
        catchUpUtterances = catchUpUtterances.filter { $0.value !== utterance }
        utterance.setSource(text, language: nil)
        utterance.isTyped = true
        utterance.translatedSource = nil
        translate(utterance)
    }

    /// Adds a typed turn and translates it. `language` is the typist's
    /// language, used when the text doesn't say which of the pair it's in.
    func submitTyped(_ text: String, language: Language) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let detected = Language.detect(text, in: languages) ?? (languages.contains(language) ? language : languages.first)
        let utterance = Utterance(source: text, language: detected, languages: languages)
        utterance.isTyped = true
        utterance.isFinal = true
        utterances.append(utterance)
        translate(utterance)
    }

    /// Translates typed turns. Engines that translate speech by themselves
    /// don't translate text, so this uses the broker's DeepSeek, falling back
    /// to on-device translation; then a Mistral key if there is one.
    private var textTranslator: TranslationService {
        if usesOnDeviceServices { return AppleTranslator() }
        if let translator { return translator }
        if let broker = BrokerTranslator.shared { return FallbackTranslator(primary: broker, fallback: AppleTranslator()) }
        let key = settings.credential(.mistral)
        if !key.isEmpty { return MistralTranslator(apiKey: key, model: settings.translationModel) }
        return AppleTranslator()
    }

    /// True when typed text needs on-device languages.
    var translatesTypedTextOnDevice: Bool { textTranslator is AppleTranslator }

    private var usesOnDeviceServices: Bool {
        settings.provider.id == SpeechProvider.onDevice.id || isUsingOnDevice || !isOnline
    }

    /// The selected offline recognizer must change with the visible selector.
    func offlineSpeakerDidChange() {
        let resume = isListening
        stopListening()
        releaseEngine()
        if languages != settings.languages {
            languages = settings.languages
            clear()
        }
        speechRoutingDidChange()
        translations.values.forEach { $0.cancel() }
        translations.removeAll()
        if resume { startListening() }
        for utterance in utterances where utterance.needsTranslation { translate(utterance) }
    }

    func retryTranslation(_ utterance: Utterance) {
        utterance.translatedSource = nil
        translate(utterance)
    }

    // MARK: - Transcript events

    /// Wait this long after a turn boundary so the turn's trailing words,
    /// which lag behind the boundary event, stay in it.
    private var boundaryDelay: Duration { engine?.textLag ?? .zero }

    func handle(_ event: SpeechEvent) {
        switch event {
        case .text(let delta):
            discardPendingIfReady(length: delta.count)
            let utterance: Utterance
            if let current {
                utterance = current
            } else {
                utterance = Utterance(languages: languages)
                utterance.isProvisional = usingStopgap
                utterances.append(utterance)
                current = utterance
            }
            utterance.append(utterance.source.isEmpty ? delta.trimmingLeadingWhitespace() : delta)
            scheduleTranslation(utterance, after: .milliseconds(280))
            armSilenceFallback()

        case .replaceText(let text, let language):
            discardPendingIfReady(length: text.count)
            // The on-device recognizer revises provisional words, so its
            // results replace the turn's transcript instead of appending.
            let utterance: Utterance
            if let current {
                utterance = current
            } else {
                utterance = Utterance(languages: languages)
                utterance.isProvisional = usingStopgap
                utterances.append(utterance)
                current = utterance
            }
            utterance.setSource(text, language: language)
            scheduleTranslation(utterance, after: .milliseconds(280))
            armSilenceFallback()

        case .turnStarted:
            // Close the previous turn once its trailing text has arrived.
            let previous = current
            after(boundaryDelay) { [weak self] in
                guard let self, let previous, self.current === previous else { return }
                self.finalizeCurrent()
            }

        case .turnEagerEnded:
            // The speaker has probably finished. Translate now instead of waiting for turn.end.
            if let current { scheduleTranslation(current, after: .zero) }

        case .turnResumed:
            break

        case .turnEnded:
            let ending = current
            after(boundaryDelay) { [weak self] in
                guard let self, let ending, self.current === ending else { return }
                self.finalizeCurrent()
            }

        case .segment(let segment):
            discardPendingIfReady(length: segment.source.count)
            apply(segment)

        case .sessionReset:
            finalizeCurrent()
            dropoutIndex = utterances.count
        }
    }

    /// Shows a segment from an engine that translates by itself. Its
    /// translation fills `Utterance.translation` directly.
    private func apply(_ segment: SpeechSegment) {
        if segment.isCatchUp {
            applyCatchUp(segment)
            return
        }
        let utterance: Utterance
        if let existing = segmentUtterances[segment.id] {
            utterance = existing
        } else {
            guard !segment.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            finalizeCurrent()
            // Earlier segments' translations are complete once a new one starts.
            for older in segmentUtterances.values where older.translationState == .working {
                older.translationState = .current
            }
            // Keep the last one: its translation can still arrive. Catch-up
            // segments share the id sequence, so ids can skip.
            let last = segmentUtterances.keys.max()
            segmentUtterances = segmentUtterances.filter { $0.key == last }
            utterance = Utterance(languages: languages)
            utterances.append(utterance)
            segmentUtterances[segment.id] = utterance
        }

        show(segment, in: utterance)

        if segment.isClosed {
            if current === utterance { finalizeCurrent() } else { utterance.isFinal = true }
            if !utterance.hasContent { utterances.removeAll { $0 === utterance } }
        } else if !utterance.isFinal {
            current = utterance
            armSilenceFallback()
        }
        if utterance.hasContent { speak(utterance, stable: segment.stableTranslation, complete: false) }
    }

    /// Shows a segment of speech from a dropout where the dropout happened,
    /// ahead of whatever was said since.
    private func applyCatchUp(_ segment: SpeechSegment) {
        let utterance: Utterance
        if let existing = catchUpUtterances[segment.id] {
            utterance = existing
        } else {
            guard !segment.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            for older in catchUpUtterances.values where older.translationState == .working {
                older.translationState = .current
            }
            let last = catchUpUtterances.keys.max()
            catchUpUtterances = catchUpUtterances.filter { $0.key == last }
            utterance = Utterance(languages: languages)
            utterance.isLate = true
            let index = min(dropoutIndex ?? utterances.count, utterances.count)
            utterances.insert(utterance, at: index)
            dropoutIndex = index + 1
            catchUpUtterances[segment.id] = utterance
        }

        show(segment, in: utterance)
        utterance.isFinal = segment.isClosed
        if segment.isClosed && !utterance.hasContent {
            utterances.removeAll { $0 === utterance }
            dropoutIndex = dropoutIndex.map { max(0, $0 - 1) }
        }
        if utterance.hasContent { speak(utterance, stable: segment.stableTranslation, complete: false) }
    }

    private func show(_ segment: SpeechSegment, in utterance: Utterance) {
        // Detect first, so only Chinese text gets the chosen script; Japanese kanji must not.
        let source = segment.source.trimmingLeadingWhitespace()
        let language = segment.language ?? Language.detect(source, in: languages) ?? utterance.language
        let target = languages.other(than: language)
        utterance.setSource(convertScript(source, in: language), language: language)
        utterance.translation = convertScript(Filler.strip(segment.translation, in: target), in: target)
        utterance.translatedSource = utterance.trimmedSource
        utterance.translationState = segment.isClosed && !utterance.translation.isEmpty ? .current : .working
    }

    private func convertScript(_ text: String, in language: Language) -> String {
        language == .chinese ? settings.chineseScript.convert(text) : text
    }

    /// Ends the turn if no text and no turn events have arrived for a while,
    /// in case turn detection misses a boundary.
    private func armSilenceFallback() {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.engine?.endTurn()
            self?.finalizeCurrent()
        }
    }

    private func finalizeCurrent() {
        silenceTimer?.cancel()
        guard let utterance = current else { return }
        current = nil
        utterance.isFinal = true
        if !utterance.hasContent {
            utterances.removeAll { $0 === utterance }
            return
        }
        if utterance.needsTranslation {
            scheduleTranslation(utterance, after: .zero)
        } else if translator != nil, utterance.translationState == .current {
            // Translated while it was spoken. A translating engine's turns
            // are read out as their segments arrive instead.
            speak(utterance, stable: utterance.translation, complete: true)
        }
    }

    // MARK: - Translation

    /// Throttles translation while someone is speaking: at most one request
    /// in flight per turn, and a new one starts as soon as it finishes if the
    /// transcript has grown. Long monologues keep updating instead of waiting
    /// for a pause.
    private func scheduleTranslation(_ utterance: Utterance, after delay: Duration) {
        if translations[utterance.id] != nil { return }
        if delay > .zero, debounces[utterance.id] != nil { return }
        debounces[utterance.id]?.cancel()
        debounces[utterance.id] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.debounces[utterance.id] = nil
            if utterance.needsTranslation { self.translate(utterance) }
        }
    }

    private func translate(_ utterance: Utterance) {
        let text = utterance.trimmedSource
        guard !text.isEmpty, translations[utterance.id] == nil,
              let translator = utterance.isTyped ? textTranslator : translator else { return }

        let language = utterance.language
        let target = utterance.target
        let context = Array(utterances.prefix { $0 !== utterance }.filter { $0.isFinal && $0.hasContent }.suffix(3))
        let script = settings.chineseScript

        utterance.translationState = .working
        translations[utterance.id] = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                // Re-evaluate after a failed cloud attempt so a connection
                // loss never leaves local translation waiting for the network.
                let service: TranslationService = self?.demo == nil && self?.usesOnDeviceServices == true ? AppleTranslator() : translator
                do {
                    var output = ""
                    // Show tokens as they stream for a first translation. When
                    // revising an existing one, swap in the new text only when
                    // it's complete so the line doesn't flicker.
                    let streamLive = utterance.translation.isEmpty
                    for try await token in service.translate(text, from: language, to: target, context: context, script: script) {
                        if Task.isCancelled { return }
                        output += token
                        if streamLive { utterance.translation = output }
                    }
                    if Task.isCancelled { return }
                    utterance.translation = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    utterance.translatedSource = text
                    utterance.translationState = utterance.needsTranslation ? .working : .current
                    self?.translations[utterance.id] = nil
                    if utterance.isFinal && utterance.translationState == .current {
                        self?.speak(utterance, stable: utterance.translation, complete: true)
                    }
                    // The speaker kept talking while we translated; catch up.
                    if utterance.needsTranslation { self?.translate(utterance) }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    attempt += 1
                    let permanent = (error as? TranslationError)?.isPermanent ?? false
                    if permanent || attempt >= 4 {
                        utterance.translationState = .failed(error.localizedDescription)
                        self?.translations[utterance.id] = nil
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
                }
            }
        }
    }

    // MARK: - Speech-to-speech

    /// Switches speech-to-speech mode, from the speaker button or Settings.
    func setSpeaksTranslations(_ on: Bool) {
        settings.speaksTranslations = on
        speechSettingChanged()
    }

    /// Local voices also work without a Soniox credential.
    var canSpeakTranslations: Bool { true }

    /// A language change applies immediately, including while Settings is open.
    /// Old turns must not be spoken for a newly selected listener.
    func speechRoutingDidChange() {
        speaker?.stop()
        speaker = nil
        speechFlushes.values.forEach { $0.cancel() }
        speechFlushes.removeAll()
        spoken.removeAll()
        speakingSince = settings.speaksTranslations ? .now : nil
    }

    private func speechSettingChanged() {
        AudioSessionUsers.setDirectionalSpeechEnabled(settings.speaksTranslations && SpeechPlayer.supportsDirectionalOutput)
        if settings.speaksTranslations {
            if speakingSince == nil { speakingSince = .now }
        } else {
            speakingSince = nil
            speaker?.stop()
            speechFlushes.values.forEach { $0.cancel() }
            speechFlushes.removeAll()
        }
    }

    /// Reads each direction to its listener, a sentence at a time.
    /// `stable` is the part of the translation that
    /// won't change; `complete` means nothing more is coming.
    private func speak(_ utterance: Utterance, stable: String, complete: Bool) {
        guard settings.speaksTranslations, let speakingSince, utterance.createdAt >= speakingSince,
              utterance.languages == settings.languages else { return }
        let output: SpeechPlayer.Output
        if SpeechPlayer.supportsDirectionalOutput {
            output = utterance.target == settings.speechListenerLanguage ? .headphones : .speaker
        } else {
            guard utterance.target == languages.second else { return }
            output = .automatic
        }
        let sent = spoken[utterance.id] ?? 0
        guard stable.count > sent else { return }
        let fresh = String(stable.dropFirst(sent))
        let ready = complete ? fresh : Self.completeSentences(in: fresh)
        if !ready.isEmpty {
            guard let speaker = activeSpeaker() else { return }
            speaker.speak(ready, in: utterance.target, output: output)
        }
        speechFlushes.removeValue(forKey: utterance.id)?.cancel()
        if complete {
            spoken[utterance.id] = Int.max
        } else {
            spoken[utterance.id] = sent + ready.count
            // A last sentence without closing punctuation is read once the
            // turn has ended and its translation stops growing.
            guard ready.count < fresh.count, utterance.isFinal else { return }
            speechFlushes[utterance.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                self.speechFlushes[utterance.id] = nil
                self.speak(utterance, stable: stable, complete: true)
            }
        }
    }

    private func activeSpeaker() -> (any TranslationSpeaker)? {
        let local = usesOnDeviceServices || SonioxSpeaker.credential(settings) == nil
        if let speaker, speakerUsesOnDevice == local { return speaker }
        speaker?.stop()
        let speaker: any TranslationSpeaker
        if local {
            speaker = OfflineSpeaker(script: settings.chineseScript)
        } else if let credential = SonioxSpeaker.credential(settings) {
            speaker = SonioxSpeaker(credential: credential)
        } else { return nil }
        speaker.onError = { [weak self] message in
            self?.setSpeaksTranslations(false)
            self?.alert = message
        }
        self.speaker = speaker
        speakerUsesOnDevice = local
        return speaker
    }

    /// The text up to and including the last sentence end, or "" if none.
    /// A period after a digit may be a decimal point, so it doesn't count
    /// at the very end.
    static func completeSentences(in text: String) -> String {
        let enders: Set<Character> = [".", "!", "?", "。", "！", "？", "…", ";", "；", "؟", "।"]
        var end: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if enders.contains(text[index]) {
                let atEnd = next == text.endIndex
                let followedBySpace = !atEnd && text[next].isWhitespace
                let wide = !text[index].isASCII
                let afterDigit = index > text.startIndex && text[text.index(before: index)].isNumber
                if wide || followedBySpace || (atEnd && !afterDigit) { end = next }
            }
            index = next
        }
        return end.map { String(text[..<$0]) } ?? ""
    }

    // MARK: - Status

    private func setPath(online: Bool, interface: NWInterface.InterfaceType?) {
        let handoff = online && isOnline && interface != self.interface && self.interface != nil && interface != nil
        if online { self.interface = interface }
        if handoff { engine?.networkPathChanged() }
        guard online != isOnline else { return }
        isOnline = online
        // Invalidate an in-flight cloud TTS stream as soon as connectivity
        // changes. Subsequent sentences choose the matching local/cloud voice.
        speaker?.stop()
        speaker = nil
        engine?.networkAvailable = online
        if !online {
            // A cloud request may still be waiting on its socket. Restart it
            // locally now instead of waiting for that request to time out.
            translations.values.forEach { $0.cancel() }
            translations.removeAll()
            for utterance in utterances where utterance.needsTranslation { translate(utterance) }
        }
        refreshStatus()
    }

    private func refreshStatus() {
        guard isListening else {
            status = .idle
            return
        }
        switch transcriberStatus {
        case .idle: status = .idle
        case .connecting: status = isOnline ? .connecting : .offline
        case .live: status = .live
        case .reconnecting: status = isOnline ? .reconnecting : .offline
        case .failed(let message):
            status = .failed(message)
            stopListening()
            releaseEngine()
            alert = message
        }
    }

    private static func keepScreenAwake(_ awake: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }

    private func after(_ delay: Duration, _ action: @escaping () -> Void) {
        if delay == .zero {
            action()
            return
        }
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            action()
        }
    }
}

private extension String {
    func trimmingLeadingWhitespace() -> String {
        String(drop(while: \.isWhitespace))
    }
}
