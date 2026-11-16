import Foundation

/// A realtime speech-to-text service that `ConversationStore` can drive.
///
/// Engines report either raw transcript deltas plus turn boundaries (and
/// leave translation to a `TranslationService`), or whole segments that
/// already carry their translation.
protocol SpeechEngine: AnyObject {
    var onEvent: (SpeechEvent) -> Void { get set }
    var onStatus: (SpeechEngineStatus) -> Void { get set }
    /// Set from `NWPathMonitor`. Flipping it back on retries right away.
    var networkAvailable: Bool { get set }
    /// How far transcript text lags behind turn events. The store waits this
    /// long after a boundary so trailing words stay in their turn.
    var textLag: Duration { get }
    /// Raw transcript deltas can finish after pause. Keep their current turn
    /// open until the server's final boundary instead of splitting its tail.
    var drainsTextOnPause: Bool { get }

    func start()
    /// Opens a server session ahead of listening, held like `pause()`, so
    /// the first `resume()` is instant. Engines that can't hold one idle do
    /// nothing, and `resume()` connects as usual.
    func prewarm()
    func stop()
    /// Stops taking audio but may keep the server session open for a while,
    /// so `resume()` doesn't have to reconnect. Call `stop()` to let it go.
    func pause()
    /// Takes audio again after `pause()`.
    func resume()
    /// Queues one 16 kHz mono PCM16 chunk. Safe to call while disconnected.
    func send(_ chunk: Data)
    /// The store ended the current turn on its own after a silence.
    func endTurn()
    /// The device moved to a different network interface, such as from
    /// Wi-Fi to cellular, while staying online.
    func networkPathChanged()
}

extension SpeechEngine {
    var textLag: Duration { .zero }
    var drainsTextOnPause: Bool { false }
    func prewarm() {}
    func pause() { stop() }
    func resume() { start() }
    func endTurn() {}
    func networkPathChanged() {}
}

enum SpeechEvent {
    /// More transcript text for the current turn.
    case text(String)
    /// The whole transcript of the current turn so far, for engines whose
    /// recognizer revises provisional words instead of appending deltas.
    case replaceText(String, Language?)
    case turnStarted
    case turnEagerEnded
    case turnResumed
    case turnEnded
    /// The latest state of a turn from an engine that translates by itself.
    /// A local timeout can close it before the provider finishes, so accepted
    /// audio may still produce source corrections or more translation.
    case segment(SpeechSegment)
    /// Unrestricted speech with explicit source evidence and target.
    case autoSegment(AutoSpeechSegment)
    /// The server session was replaced; any open turn will not continue.
    case sessionReset
}

struct SpeechSegment {
    var id: Int
    var source: String
    var translation: String
    /// The start of `translation` that won't be revised, which speech-to-speech
    /// can read out before the rest arrives.
    var stableTranslation: String
    var language: Language?
    /// Closed in the conversation UI; a local close can still drain results.
    var isClosed: Bool
    /// Speech held during a dropout and transcribed late, on its own session,
    /// while live speech carried on.
    var isCatchUp = false
}

struct AutoSpeechSegment: Equatable, Sendable {
    var id: Int
    var source: String
    var language: Language?
    /// The canonical final source has a coherent language, even in catch-up.
    var languageIsFinal: Bool
    /// Nil for outgoing speech until its target has been discovered.
    var target: Language?
    var translation: String
    var stableTranslation: String
    var isClosed: Bool
    /// Provider completion, distinct from a local UI timeout.
    var isSourceFinal: Bool
    var isCatchUp: Bool
    /// Live, corroborated provider completion that may identify a partner.
    var isPartnerEvidence = false
}

enum SpeechEngineStatus: Equatable {
    case idle
    case connecting
    case live
    case reconnecting
    case failed(String)
}
