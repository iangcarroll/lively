import Foundation

/// Errors produced internally by the adapted Kokoro runtime.
enum AudioModelError: LocalizedError {
    case modelLoadFailed(modelId: String, reason: String)
    case inferenceFailed(operation: String, reason: String)
    case voiceNotFound(voice: String, searchPath: String)

    var errorDescription: String? {
        switch self {
        case let .modelLoadFailed(model, reason): "\(model): \(reason)"
        case let .inferenceFailed(operation, reason): "\(operation): \(reason)"
        case let .voiceNotFound(voice, path): "Voice \(voice) unavailable: \(path)"
        }
    }
}
