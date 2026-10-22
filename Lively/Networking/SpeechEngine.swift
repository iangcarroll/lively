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

    func start()
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
    func pause() { stop() }
    func resume() { start() }
    func endTurn() {}
    func networkPathChanged() {}
}

enum SpeechEvent {
    /// More transcript text for the current turn.
    case text(String)
    case turnStarted
    case turnEagerEnded
    case turnResumed
    case turnEnded
    /// The latest state of a segment from an engine that translates by itself.
    /// Segments may be revised until they're closed, and their translation can
    /// keep arriving after that.
    case segment(SpeechSegment)
    /// The server session was replaced; any open turn will not continue.
    case sessionReset
}

struct SpeechSegment {
    var id: Int
    var source: String
    var translation: String
    var language: Language?
    var isClosed: Bool
    /// Speech held during a dropout and transcribed late, on its own session,
    /// while live speech carried on.
    var isCatchUp = false
}

enum SpeechEngineStatus: Equatable {
    case idle
    case connecting
    case live
    case reconnecting
    case failed(String)
}
