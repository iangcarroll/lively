import Foundation

// The protocol integration feeds explicit provider frames into the real parser.
// This boundary never opens a socket, requests a key, or captures microphone audio.
// ResilientSocket has a separate loopback WebSocket lifecycle regression.
protocol SocketDialect: AnyObject {}

struct SocketStream {
    let id: Int
    let isCatchUp: Bool
}

enum SocketSignal {
    case none, ready, boundary
    case retry(String, throttled: Bool = false)
    case fail(String)
}

final class ResilientSocket {
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    var networkAvailable = true
    init(dialect: any SocketDialect) {}
    func start() {}
    func prewarm() {}
    func pause() {}
    func resume() {}
    func stop() {}
    func send(_ chunk: Data) {}
    func networkPathChanged() {}
}

final class SonioxKeyProvider {
    struct Key {
        let value: String
        let websocketURL: URL
        let region: String
    }
    final class Regions {
        func connectSucceeded(region: String) {}
        func connectFailed(region: String) {}
    }
    let regions = Regions()
    func startRefreshing() {}
    func stopRefreshing() {}
    func takeKey() async throws -> Key { throw URLError(.unsupportedURL) }
}

enum MicCapture { static let sampleRate = 16_000.0 }

extension URLSessionWebSocketTask.Message {
    static func json(_ value: [String: Any]) -> Self {
        .data(try! JSONSerialization.data(withJSONObject: value))
    }

    var jsonObject: [String: Any]? {
        let data: Data
        switch self {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
