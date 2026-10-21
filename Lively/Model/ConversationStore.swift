import Foundation
import Network
import Observation
#if os(iOS)
import UIKit
#endif

/// Drives a live conversation: mic → Voxtral Realtime → turns → translation.
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
    /// Smoothed mic level for the meter, 0...1.
    private(set) var level: Float = 0
    var alert: String?

    private let settings: AppSettings
    private let mic = MicCapture()
    private let transcriber = RealtimeTranscriber()
    private let pathMonitor = NWPathMonitor()
    private var translator: TranslationService

    /// The turn currently receiving transcript text.
    private var current: Utterance?
    private var translations: [UUID: Task<Void, Never>] = [:]
    private var debounces: [UUID: Task<Void, Never>] = [:]
    private var silenceTimer: Task<Void, Never>?
    private var transcriberStatus: RealtimeTranscriber.Status = .idle
    private var demo: DemoConversation?
    private var audioPump: Task<Void, Never>?

    init(settings: AppSettings = .shared, demo: Bool = false) {
        self.settings = settings
        self.translator = demo
            ? DemoTranslator()
            : MistralTranslator(apiKey: settings.apiKey, model: settings.translationModel)
        if demo { self.demo = DemoConversation() }

        transcriber.onEvent = { [weak self] in self?.handle($0) }
        transcriber.onStatus = { [weak self] status in
            self?.transcriberStatus = status
            self?.refreshStatus()
        }

        // One stream keeps chunks in order on their way from the audio thread.
        let (chunks, continuation) = AsyncStream<(Data, Float)>.makeStream(bufferingPolicy: .bufferingNewest(500))
        mic.onChunk = { chunk, level in continuation.yield((chunk, level)) }
        audioPump = Task { [weak self] in
            for await (chunk, level) in chunks {
                guard let self else { return }
                guard self.isListening else { continue }
                self.transcriber.send(chunk)
                self.level = self.level * 0.6 + level * 0.4
            }
        }
        mic.onInterrupted = { [weak self] in
            Task { @MainActor in
                self?.stopListening()
                self?.alert = "The microphone stopped. Tap the mic to start again."
            }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.setOnline(online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "lively.path"))
    }

    // MARK: - Listening

    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    func startListening() {
        guard !isListening else { return }
        if let demo {
            isListening = true
            transcriberStatus = .live
            refreshStatus()
            demo.play(into: self)
            return
        }
        guard settings.hasAPIKey else {
            alert = "Add your Mistral API key in Settings to start."
            return
        }
        Task {
            guard await MicCapture.requestPermission() else {
                alert = "Lively needs microphone access. You can turn it on in Settings › Privacy & Security › Microphone."
                return
            }
            translator = MistralTranslator(apiKey: settings.apiKey, model: settings.translationModel)
            do {
                try mic.start()
            } catch {
                alert = error.localizedDescription
                return
            }
            isListening = true
            Self.keepScreenAwake(true)
            transcriber.start(.init(apiKey: settings.apiKey, streamingDelayMs: settings.latency.milliseconds))
        }
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        demo?.stop()
        mic.stop()
        transcriber.stop()
        level = 0
        Self.keepScreenAwake(false)
        finalizeCurrent()
        transcriberStatus = .idle
        refreshStatus()
    }

    func clear() {
        translations.values.forEach { $0.cancel() }
        debounces.values.forEach { $0.cancel() }
        translations.removeAll()
        debounces.removeAll()
        current = nil
        utterances.removeAll()
    }

    func retryTranslation(_ utterance: Utterance) {
        utterance.translatedSource = nil
        translate(utterance)
    }

    // MARK: - Transcript events

    /// Turn events arrive as soon as the audio is heard, but transcript text
    /// lags by the streaming delay. A boundary always follows at least
    /// `min_silence_ms` (350 ms) of silence, so the previous turn's last words
    /// arrive within (delay - 350 ms) of it. Waiting about that long keeps
    /// trailing words in their turn without swallowing the next speaker's first.
    private var boundaryDelay: Duration {
        demo == nil ? .milliseconds(max(60, settings.latency.milliseconds - 250)) : .zero
    }

    func handle(_ event: RealtimeTranscriber.Event) {
        switch event {
        case .text(let delta):
            let utterance: Utterance
            if let current {
                utterance = current
            } else {
                utterance = Utterance()
                utterances.append(utterance)
                current = utterance
            }
            utterance.append(utterance.source.isEmpty ? delta.trimmingLeadingWhitespace() : delta)
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

        case .sessionReset:
            finalizeCurrent()
        }
    }

    /// Ends the turn if no text and no turn events have arrived for a while,
    /// in case turn detection misses a boundary.
    private func armSilenceFallback() {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.finalizeCurrent()
        }
    }

    private func finalizeCurrent() {
        silenceTimer?.cancel()
        guard let utterance = current else { return }
        current = nil
        utterance.isFinal = true
        if utterance.trimmedSource.isEmpty {
            utterances.removeAll { $0 === utterance }
            return
        }
        if utterance.needsTranslation { scheduleTranslation(utterance, after: .zero) }
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
        guard !text.isEmpty, translations[utterance.id] == nil else { return }

        let language = utterance.language
        let context = Array(utterances.prefix { $0 !== utterance }.filter(\.isFinal).suffix(3))
        let script = settings.chineseScript
        let translator = self.translator

        utterance.translationState = .working
        translations[utterance.id] = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                // Hold the request until we're back online.
                if let self, !self.isOnline {
                    utterance.translationState = .waitingForNetwork
                    while !self.isOnline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
                    utterance.translationState = .working
                }
                do {
                    var output = ""
                    // Show tokens as they stream for a first translation. When
                    // revising an existing one, swap in the new text only when
                    // it's complete so the line doesn't flicker.
                    let streamLive = utterance.translation.isEmpty
                    for try await token in translator.translate(text, from: language, context: context, script: script) {
                        if Task.isCancelled { return }
                        output += token
                        if streamLive { utterance.translation = output }
                    }
                    if Task.isCancelled { return }
                    utterance.translation = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    utterance.translatedSource = text
                    utterance.translationState = utterance.needsTranslation ? .working : .current
                    self?.translations[utterance.id] = nil
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

    // MARK: - Status

    private func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        transcriber.networkAvailable = online
        refreshStatus()
    }

    private func refreshStatus() {
        switch transcriberStatus {
        case .idle: status = .idle
        case .connecting: status = isOnline ? .connecting : .offline
        case .live: status = .live
        case .reconnecting: status = isOnline ? .reconnecting : .offline
        case .failed(let message):
            status = .failed(message)
            if isListening {
                stopListening()
                alert = message
            }
        }
    }

    private static func keepScreenAwake(_ awake: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }

    private func after(_ delay: Duration, _ action: @escaping () -> Void) {
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
