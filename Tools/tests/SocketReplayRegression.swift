import Foundation

enum MicCapture {
    static let sampleRate = 16_000.0
    static let chunkDuration = 0.08
}

@MainActor final class ReplayDialect: SocketDialect {
    let endpoint: URL
    let supportsSideStreams: Bool
    var requests: [SocketStream] = []
    var ended: [SocketStream] = []
    var audio: [SocketStream: [Int]] = [:]
    var confirmed: [SocketStream: [Int]] = [:]
    var completed: [SocketStream: [Int]] = [:]
    var opened: [SocketStream] = []
    var physicallyOnline = true

    init(_ endpoint: URL, sides: Bool) {
        self.endpoint = endpoint
        supportsSideStreams = sides
    }
    func makeRequest(for stream: SocketStream) async throws -> URLRequest {
        requests.append(stream)
        guard physicallyOnline else { throw URLError(.notConnectedToInternet) }
        return URLRequest(url: endpoint.appendingPathComponent(stream.isCatchUp ? "catchup" : "primary"))
    }
    func openingMessages() -> [URLSessionWebSocketTask.Message] { [.string("configure")] }
    func audioMessage(_ chunk: Data) -> URLSessionWebSocketTask.Message { .data(chunk) }
    var endOfAudioMessage: URLSessionWebSocketTask.Message? { .string("") }
    var keepaliveMessage: URLSessionWebSocketTask.Message? { .string("keepalive") }
    var pauseMessage: URLSessionWebSocketTask.Message? { .string("finalize") }
    var readyWhenOpen: Bool { false }
    var reportsFinalizedAudio: Bool { true }
    var rejectedKeyMessage: String { "Unused loopback credential" }
    func sessionDidReset(_ stream: SocketStream) {}
    func sessionDidOpen(_ stream: SocketStream) { opened.append(stream) }
    func sideStreamDidEnd(_ stream: SocketStream) { ended.append(stream) }
    func finalizedAudio(on stream: SocketStream) -> TimeInterval {
        Double(confirmed[stream, default: []].count) * MicCapture.chunkDuration
    }
    func receive(_ message: URLSessionWebSocketTask.Message, on stream: SocketStream) -> SocketSignal {
        guard let value = message.jsonObject, let event = value["event"] as? String else { return .none }
        switch event {
        case "ready": return .ready
        case "audio":
            audio[stream, default: []].append(value["marker"] as! Int)
        case "progress", "finished":
            confirmed[stream] = value["markers"] as? [Int]
            if event == "finished" {
                completed[stream] = confirmed[stream]
                return stream.isCatchUp ? .retry("Replay completed") : .boundary
            }
        default: break
        }
        return .none
    }
}

@MainActor final class ReplayCloud: SpeechEngine {
    var onEvent: (SpeechEvent) -> Void = { _ in }
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    let socket: ResilientSocket
    var networkAvailable: Bool {
        get { socket.networkAvailable }
        set { socket.networkAvailable = newValue }
    }
    init(_ dialect: ReplayDialect) {
        socket = ResilientSocket(dialect: dialect)
        socket.onStatus = { [weak self] in self?.onStatus($0) }
    }
    func start() { socket.start() }
    func stop() { socket.stop() }
    func send(_ chunk: Data) { socket.send(chunk) }
    func pause() { socket.pause() }
    func resume() { socket.resume() }
    func prewarm() { socket.prewarm() }
    func networkPathChanged() { socket.networkPathChanged() }
}

@MainActor final class ReplayLocal: SpeechEngine {
    var onEvent: (SpeechEvent) -> Void = { _ in }
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    var networkAvailable = false
    var chunks: [Data] = []
    func start() { onStatus(.live) }
    func stop() {}
    func send(_ chunk: Data) { chunks.append(chunk) }
}

@MainActor @main struct SocketReplayRegression {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { print("FAIL: " + message); exit(1) }
    }
    static func wait(_ message: String, timeout: Duration = .seconds(5), until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        check(condition(), message)
    }
    static func pcm(_ marker: Int) -> Data {
        [Int16](repeating: Int16(marker).littleEndian, count: 1_280).withUnsafeBytes { Data($0) }
    }
    static func ordered(_ values: [SocketStream: [Int]]) -> [[Int]] {
        values.keys.sorted { $0.id < $1.id }.map { values[$0]! }
    }
    static func main() async {
        let endpoint = URL(string: CommandLine.arguments[1])!
        let mode = CommandLine.arguments[2]
        let longReplay = mode == "cold" || mode == "outage" || mode == "bounded-primary"
        let dialect = ReplayDialect(endpoint, sides: !longReplay)
        let cloud = ReplayCloud(dialect)
        let local = ReplayLocal()
        let hybrid = HybridSpeechEngine(local: local, cloud: cloud)
        let socket = cloud.socket
        var reportedReplay: TimeInterval = 0
        hybrid.onSourceChange = { source, seconds in
            if source == .cloud, seconds > 0 {
                reportedReplay = seconds
                // New input from the source callback must follow older replay.
                hybrid.send(pcm(12_000))
            }
        }
        if longReplay {
            hybrid.start()
            if mode == "outage" {
                await wait("initial cloud session ready") { socket.status == .live }
                hybrid.networkAvailable = false
            }
            let count = mode == "bounded-primary" ? 1_000 : 312
            let markers = (0..<count).map { $0.isMultiple(of: 3) ? 0 : 4_000 + $0 }
            for marker in markers { hybrid.send(pcm(marker)) }
            if mode == "outage" { hybrid.networkAvailable = true }
            await wait("entire retained replay reaches the actual WebSocket") {
                dialect.audio.values.reduce(0) { $0 + $1.count } == min(count, 750) + (mode == "outage" ? 1 : 0)
            }
            if mode != "outage" { hybrid.send(pcm(12_000)) }
            hybrid.pause()
            await wait("ordered replay receives its final response") { !dialect.completed.isEmpty }
            let expected = Array(markers.suffix(750)) + [12_000]
            check(ordered(dialect.completed).flatMap { $0 } == expected,
                  "all retained PCM precedes new audio without a five-second truncation")
            check(dialect.requests.allSatisfy { !$0.isCatchUp }, "single-session provider never opens side streams")
            if mode == "outage" {
                check(abs(reportedReplay - 24.96) < 0.000_001, "Hybrid reports exactly the interval delivered to cloud")
                check(local.chunks.count == 312, "local recognizer also receives the retained outage interval")
            } else {
                check(local.chunks.isEmpty, "online cold startup does not invoke offline recognition")
            }
            hybrid.stop()
        } else {
            socket.start()
            let input = Array(repeating: 0, count: 20) + Array(4_000..<4_040) + Array(repeating: 0, count: 20)
            for marker in input { socket.send(pcm(marker)) }
            if mode != "healthy" {
                await wait("first catch-up failure is observed") { !dialect.ended.isEmpty }
            }
            if mode == "pending-offline" || mode == "expired" {
                dialect.physicallyOnline = false
                socket.networkAvailable = false
                let interval: Duration = mode == "expired" ? .seconds(31) : .milliseconds(1_700)
                try? await Task.sleep(for: interval)
                check(dialect.requests.filter(\.isCatchUp).count == 1,
                      "catch-up backoff never opens a connection while the path is unavailable")
                dialect.physicallyOnline = true
                socket.networkAvailable = true
            }
            if mode == "stop-restart" {
                socket.stop()
                socket.start()
                await wait("new session starts after queued retry cancellation") { dialect.opened.filter { !$0.isCatchUp }.count == 2 }
                socket.send(pcm(8_000)); socket.pause()
                await wait("new-session audio finalizes") { !dialect.completed.isEmpty }
                try? await Task.sleep(for: .milliseconds(1_300))
                check(dialect.requests.filter(\.isCatchUp).count == 1, "stop invalidates the prior session's delayed replay")
                check(ordered(dialect.completed) == [[8_000]], "restart cannot upload the previous conversation's retained PCM")
            } else if mode == "expired" {
                await wait("primary reconnects after expired offline wait") { socket.status == .live }
                try? await Task.sleep(for: .milliseconds(400))
                check(dialect.requests.filter(\.isCatchUp).count == 1 && dialect.completed.isEmpty,
                      "restoration after the original deadline cannot revive expired catch-up audio")
            } else {
                await wait("unfinished catch-up audio is recovered", timeout: .seconds(8)) { !dialect.completed.isEmpty }
                let expected = Array(repeating: 0, count: 3) + Array(4_000..<4_040) + Array(repeating: 0, count: 3)
                check(ordered(dialect.confirmed).flatMap { $0 } == expected,
                      "confirmed prefixes and recovered suffix cover every retained chunk exactly once")
                let sides = ordered(dialect.audio.filter { $0.key.isCatchUp })
                if mode == "sent-fail" {
                    check(sides == [expected, Array(expected.dropFirst(20))],
                          "retry starts after the provider-finalized prefix, retaining all 26 unfinished chunks")
                } else if mode == "multi-fail" {
                    check(sides == [expected, Array(expected.dropFirst(20)), Array(expected.dropFirst(30))],
                          "successive retries use each new stream's timestamps without replaying old finalized prefixes")
                } else {
                    check(sides == [expected], "unsent retry or healthy completion reaches the wire once")
                }
                check(dialect.audio.filter { !$0.key.isCatchUp }.values.allSatisfy(\.isEmpty),
                      "retained catch-up audio does not overtake fresh speech on the primary")
            }
            socket.stop()
        }
        print("PASS: \(mode) replay recovery (\(assertions) assertions)")
    }
}
