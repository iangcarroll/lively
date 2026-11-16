import Foundation

enum MicCapture {
    static let sampleRate = 16_000.0
    static let chunkDuration = 0.08
}

@MainActor
final class LocalDialect: SocketDialect {
    let endpoint: URL
    let keepsWarm: Bool
    let setupDelay: Duration
    let readyAtHandshake: Bool
    let tracksFinalized: Bool
    let supportsSideStreams: Bool
    var requests = 0
    var opened = 0
    var finals: [[Int]] = []
    var audio: [Int] = []
    var audioByStream: [SocketStream: [Int]] = [:]
    var finalized: [SocketStream: TimeInterval] = [:]

    init(_ endpoint: URL, keepsWarm: Bool, setupDelay: Duration = .zero, readyAtHandshake: Bool = false,
         tracksFinalized: Bool = false, supportsSideStreams: Bool = false) {
        self.endpoint = endpoint
        self.keepsWarm = keepsWarm
        self.setupDelay = setupDelay
        self.readyAtHandshake = readyAtHandshake
        self.tracksFinalized = tracksFinalized
        self.supportsSideStreams = supportsSideStreams
    }

    func makeRequest(for stream: SocketStream) async throws -> URLRequest {
        requests += 1
        // Deliberately finishes even if cancelled: the socket must invalidate
        // stale setup completions rather than rely on a cooperative broker.
        try? await Task.sleep(for: setupDelay)
        let destination = stream.isCatchUp ? endpoint.appendingPathComponent("catchup") : endpoint
        return URLRequest(url: destination)
    }

    func openingMessages() -> [URLSessionWebSocketTask.Message] { [.string("configure")] }
    func audioMessage(_ chunk: Data) -> URLSessionWebSocketTask.Message { .data(chunk) }
    var endOfAudioMessage: URLSessionWebSocketTask.Message? { .string("") }
    var keepaliveMessage: URLSessionWebSocketTask.Message? { keepsWarm ? .string("keepalive") : nil }
    var pauseMessage: URLSessionWebSocketTask.Message? { keepsWarm ? .string("finalize") : nil }
    var readyWhenOpen: Bool { readyAtHandshake }
    var rejectedKeyMessage: String { "Local test server has no credentials" }
    var reportsFinalizedAudio: Bool { tracksFinalized }
    func finalizedAudio(on stream: SocketStream) -> TimeInterval { finalized[stream] ?? 0 }
    func sessionDidReset(_ stream: SocketStream) {}
    func sessionDidOpen(_ stream: SocketStream) { opened += 1 }

    func receive(_ message: URLSessionWebSocketTask.Message, on stream: SocketStream) -> SocketSignal {
        guard let value = message.jsonObject, let event = value["event"] as? String else { return .none }
        switch event {
        case "ready": return .ready
        case "audio":
            let marker = value["marker"] as! Int
            audio.append(marker)
            audioByStream[stream, default: []].append(marker)
            return .none
        case "final":
            let markers = value["markers"] as! [Int]
            finals.append(markers)
            finalized[stream] = Double(markers.count) * MicCapture.chunkDuration
            if stream.isCatchUp { return .retry("Local catch-up finished") }
            return keepsWarm ? .boundary : .retry("End of local audio")
        case "retry": return .retry("Deliberate local connection failure")
        default: return .none
        }
    }
}

@MainActor @main
struct SocketLifecycleRegression {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    }

    static func wait(_ message: String, timeout: Duration = .seconds(3), until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(condition(), message)
    }

    static func pcm(_ marker: Int16) -> Data {
        [Int16](repeating: marker.littleEndian, count: 1_280).withUnsafeBytes { Data($0) }
    }

    static func bufferedSpeech(_ socket: ResilientSocket, first: Int16 = 4_000) {
        // Quiet chunks establish the gate's floor. Distinct PCM amplitudes
        // identify actual bytes received by the server, independent of events.
        for marker: Int16 in [0, 0, 0, 0, 0, first, first + 1_000, first + 2_000, 0, 0, 0, 0, 0] {
            socket.send(pcm(marker))
        }
    }

    static func window(_ path: String, since start: Date) {
        // The server independently compares its connection/PCM timestamps
        // with these periods when no network work was authorized.
        print("OFFLINE_WINDOW \(path) \(start.timeIntervalSince1970) \(Date().timeIntervalSince1970)")
    }

    static func main() async {
        guard CommandLine.arguments.count == 2, let base = URL(string: CommandLine.arguments[1]) else {
            fatalError("Pass local WebSocket base URL")
        }

        let warm = LocalDialect(base.appendingPathComponent("warm"), keepsWarm: true,
                                setupDelay: .milliseconds(150))
        let warmSocket = ResilientSocket(dialect: warm)
        var warmStatus: SpeechEngineStatus = .idle
        warmSocket.onStatus = { warmStatus = $0 }
        warmSocket.start()
        bufferedSpeech(warmSocket)
        warmSocket.pause()
        warmSocket.send(pcm(9_000))
        await wait("pause before ready preserves speech and receives its final reply") { warm.finals.count == 1 }
        check(warm.finals[0] == [0, 0, 0, 4_000, 5_000, 6_000, 0, 0, 0],
              "buffered PCM must precede finalize in exact order; paused PCM must be absent")
        check(warm.requests == 1 && warm.opened == 1, "paused startup opens exactly one session")
        check(warmStatus == .live, "paused warm connection remains available")
        let pausedAudioCount = warm.audio.count
        warmSocket.send(pcm(9_000))
        try? await Task.sleep(for: .milliseconds(150))
        check(warm.audio.count == pausedAudioCount, "sending while paused cannot reach the wire")
        warmSocket.resume()
        warmSocket.send(pcm(7_000))
        warmSocket.pause()
        await wait("warm resume receives another finalized response") { warm.finals.count == 2 }
        check(warm.finals[1] == warm.finals[0] + [7_000], "warm resume appends new PCM once")
        check(warm.requests == 1 && warm.opened == 1, "warm resume reuses the original WebSocket")
        warmSocket.stop()
        check(warmStatus == .idle, "stop returns the warm socket to idle")

        let handshake = LocalDialect(base.appendingPathComponent("handshake"), keepsWarm: true,
                                     readyAtHandshake: true)
        let handshakeSocket = ResilientSocket(dialect: handshake)
        handshakeSocket.start()
        bufferedSpeech(handshakeSocket)
        handshakeSocket.pause()
        await wait("handshake-ready dialect finalizes audio paused before open") { handshake.finals.count == 1 }
        check(handshake.finals[0] == [0, 0, 0, 4_000, 5_000, 6_000, 0, 0, 0],
              "handshake readiness preserves ordered accepted PCM")
        check(handshake.opened == 1, "handshake readiness opens once without a ready frame")
        handshakeSocket.stop()

        let prewarm = LocalDialect(base.appendingPathComponent("prewarm"), keepsWarm: true)
        let prewarmSocket = ResilientSocket(dialect: prewarm)
        prewarmSocket.prewarm()
        await wait("prewarm establishes the ready session") { prewarm.opened == 1 }
        check(prewarm.audio.isEmpty && prewarm.finals.isEmpty, "empty prewarm sends no PCM or finalize")
        prewarmSocket.resume()
        prewarmSocket.send(pcm(4_000))
        prewarmSocket.pause()
        await wait("prewarmed session finalizes first speech") { prewarm.finals.count == 1 }
        check(prewarm.requests == 1 && prewarm.finals[0] == [4_000],
              "first speech reuses the prewarmed socket")
        prewarmSocket.stop()

        let eof = LocalDialect(base.appendingPathComponent("eof"), keepsWarm: false)
        let eofSocket = ResilientSocket(dialect: eof)
        var eofStatus: SpeechEngineStatus = .idle
        eofSocket.onStatus = { eofStatus = $0 }
        eofSocket.start()
        bufferedSpeech(eofSocket)
        eofSocket.pause()
        await wait("old EOF session receives all accepted PCM while its final reply is delayed") { eof.audio.count == 9 }
        eofSocket.pause()
        eofSocket.resume()
        bufferedSpeech(eofSocket, first: 7_000)
        eofSocket.pause()
        eofSocket.pause()
        await wait("rapid EOF resume and repeated pause preserve both final replies") { eof.finals.count == 2 }
        check(eof.finals[0] == [0, 0, 0, 4_000, 5_000, 6_000, 0, 0, 0],
              "old EOF reply must complete before new-session audio")
        check(eof.finals[1] == [0, 0, 0, 7_000, 8_000, 9_000, 0, 0, 0],
              "new PCM must be buffered for a new socket, never sent after old EOF")
        check(eof.requests == 2 && eof.opened == 2, "rapid EOF resume opens exactly one replacement session")
        await wait("repeated pause during EOF drain settles to idle") { eofStatus == .idle }
        eofSocket.resume()
        await wait("finished EOF dialect resumes on a fresh ready session") { eof.opened == 3 }
        eofSocket.send(pcm(8_000))
        eofSocket.pause()
        await wait("fresh EOF session finalizes new PCM") { eof.finals.count == 3 }
        check(eof.finals[2] == [8_000], "new session does not replay old finalized PCM")
        eofSocket.stop()

        let stopped = LocalDialect(base.appendingPathComponent("stopped"), keepsWarm: true,
                                   setupDelay: .milliseconds(600))
        let stoppedSocket = ResilientSocket(dialect: stopped)
        var stoppedStatus: SpeechEngineStatus = .idle
        stoppedSocket.onStatus = { stoppedStatus = $0 }
        stoppedSocket.start()
        await wait("setup request starts before cancellation") { stopped.requests == 1 }
        stoppedSocket.send(pcm(4_000))
        stoppedSocket.pause()
        stoppedSocket.stop()
        stoppedSocket.send(pcm(9_000))
        try? await Task.sleep(for: .milliseconds(800))
        check(stopped.opened == 0 && stopped.audio.isEmpty && stopped.finals.isEmpty,
              "late setup completion after stop cannot reopen or deliver audio")
        check(stoppedStatus == .idle, "stale asynchronous work cannot change idle status")

        let suspended = LocalDialect(base.appendingPathComponent("suspend"), keepsWarm: true,
                                     tracksFinalized: true)
        let suspendedSocket = ResilientSocket(dialect: suspended)
        suspendedSocket.start()
        await wait("path-loss case establishes its original ready socket") { suspended.opened == 1 }
        for marker: Int16 in [0, 4_000, 0] { suspendedSocket.send(pcm(marker)) }
        await wait("original server receives the still-unfinalized cloud interval") { suspended.audio == [0, 4_000, 0] }
        suspendedSocket.networkAvailable = false
        let lossBegan = Date()
        for marker: Int16 in [0, 5_000, 6_000, 0] { suspendedSocket.send(pcm(marker)) }
        suspendedSocket.networkPathChanged()
        try? await Task.sleep(for: .milliseconds(500))
        check(suspended.requests == 1 && suspended.audio == [0, 4_000, 0] && suspendedSocket.status == .reconnecting,
              "false path suspends sockets and upload while accepting a bounded local backlog")
        window("suspend", since: lossBegan)
        suspendedSocket.networkAvailable = true
        await wait("restored path replays the unfinalized interval before offline PCM") { suspended.audio.count == 10 }
        suspendedSocket.pause()
        await wait("restored cloud interval completes its final response") { suspended.finals.count == 1 }
        check(suspended.finals[0] == [0, 4_000, 0, 0, 5_000, 6_000, 0] && suspended.requests == 2,
              "restoration preserves old unfinalized audio and new offline bytes exactly once and in order")
        suspendedSocket.stop()

        let pausedLoss = LocalDialect(base.appendingPathComponent("paused-suspend"), keepsWarm: true,
                                      tracksFinalized: true)
        let pausedLossSocket = ResilientSocket(dialect: pausedLoss)
        pausedLossSocket.start()
        await wait("paused path-loss case establishes its original socket") { pausedLoss.opened == 1 }
        for marker: Int16 in [0, 7_000, 0] { pausedLossSocket.send(pcm(marker)) }
        await wait("paused path-loss case has accepted unfinalized PCM") { pausedLoss.audio == [0, 7_000, 0] }
        pausedLossSocket.pause()
        pausedLossSocket.networkAvailable = false
        let pausedLossBegan = Date()
        pausedLossSocket.send(pcm(9_000))
        pausedLossSocket.networkAvailable = true
        try? await Task.sleep(for: .milliseconds(500))
        check(pausedLoss.requests == 1 && pausedLoss.audio == [0, 7_000, 0],
              "a restored path cannot connect or upload until explicit paused-session resume")
        window("paused-suspend", since: pausedLossBegan)
        pausedLossSocket.resume()
        await wait("resume with no primary preserves and replays accepted PCM") { pausedLoss.audio.count == 6 }
        pausedLossSocket.pause()
        await wait("resumed suspended cloud interval receives its final reply") { pausedLoss.finals.count == 1 }
        check(pausedLoss.finals[0] == [0, 7_000, 0] && pausedLoss.requests == 2,
              "no-primary resume keeps old accepted bytes and excludes paused microphone input")
        pausedLossSocket.stop()

        let setupLoss = LocalDialect(base.appendingPathComponent("suspend-setup"), keepsWarm: true,
                                     setupDelay: .milliseconds(400))
        let setupLossSocket = ResilientSocket(dialect: setupLoss)
        setupLossSocket.start()
        bufferedSpeech(setupLossSocket)
        await wait("setup suspension begins during the asynchronous request") { setupLoss.requests == 1 }
        setupLossSocket.networkAvailable = false
        let setupLossBegan = Date()
        try? await Task.sleep(for: .milliseconds(600))
        check(setupLoss.opened == 0 && setupLoss.audio.isEmpty && setupLoss.requests == 1,
              "a cancelled request finishing while offline cannot open or upload")
        window("suspend-setup", since: setupLossBegan)
        setupLossSocket.networkAvailable = true
        setupLossSocket.pause()
        await wait("restoration drains audio accepted before the original setup completed") { setupLoss.finals.count == 1 }
        check(setupLoss.requests == 2 && setupLoss.opened == 1 && setupLoss.finals[0] == [0, 0, 0, 4_000, 5_000, 6_000, 0, 0, 0],
              "suspended setup retains backlog and only its replacement reaches the wire")
        setupLossSocket.stop()

        let bounded = LocalDialect(base.appendingPathComponent("bounded"), keepsWarm: true,
                                   supportsSideStreams: true)
        let boundedSocket = ResilientSocket(dialect: bounded)
        boundedSocket.networkAvailable = false
        boundedSocket.start()
        let boundedBegan = Date()
        let longInput: [Int16] = (0..<1_000).map { $0.isMultiple(of: 3) ? 0 : Int16(4_000 + $0) }
        for marker in longInput { boundedSocket.send(pcm(marker)) }
        try? await Task.sleep(for: .milliseconds(200))
        check(bounded.requests == 0 && bounded.audio.isEmpty, "starting offline only buffers PCM without a socket request")
        window("bounded", since: boundedBegan)
        boundedSocket.networkAvailable = true
        await wait("long offline backlog completes via its bounded catch-up stream", timeout: .seconds(5)) { bounded.finals.count == 1 }
        let expectedBounded = longInput.suffix(750).map(Int.init)
        check(bounded.finals[0] == expectedBounded && bounded.requests == 2 && bounded.opened == 2,
              "the sixty-second backlog cap retains the newest 750 real chunks in exact order")
        check(bounded.audioByStream.filter { !$0.key.isCatchUp }.values.allSatisfy(\.isEmpty),
              "a long catch-up interval never blocks fresh audio on the primary stream")
        boundedSocket.stop()

        let retryPaused = LocalDialect(base.appendingPathComponent("retry-paused"), keepsWarm: true)
        let retryPausedSocket = ResilientSocket(dialect: retryPaused)
        var retryStatuses: [SpeechEngineStatus] = []
        retryPausedSocket.onStatus = { retryStatuses.append($0) }
        retryPausedSocket.start()
        bufferedSpeech(retryPausedSocket)
        retryPausedSocket.pause()
        retryPausedSocket.send(pcm(9_000))
        await wait("a failed paused connection retries its already accepted PCM until a final reply") { retryPaused.finals.count == 1 }
        check(retryPaused.finals[0] == [0, 0, 0, 4_000, 5_000, 6_000, 0, 0, 0]
              && retryPaused.requests == 2 && retryStatuses.contains(.reconnecting),
              "paused retry preserves exact accepted bytes while excluding new microphone input")
        retryPausedSocket.stop()

        let eofLoss = LocalDialect(base.appendingPathComponent("eof-suspend"), keepsWarm: false,
                                  tracksFinalized: true)
        let eofLossSocket = ResilientSocket(dialect: eofLoss)
        eofLossSocket.start()
        await wait("EOF path-loss case establishes its first ready socket") { eofLoss.opened == 1 }
        for marker: Int16 in [0, 4_000, 0] { eofLossSocket.send(pcm(marker)) }
        await wait("EOF path-loss case accepts its original phrase") { eofLoss.audio == [0, 4_000, 0] }
        eofLossSocket.pause()
        eofLossSocket.resume()
        for marker: Int16 in [0, 7_000, 0] { eofLossSocket.send(pcm(marker)) }
        // The old EOF drain now owns an ending primary and a deadline.
        // Path suspension must replace that ownership before reconnecting.
        eofLossSocket.networkAvailable = false
        let eofLossBegan = Date()
        try? await Task.sleep(for: .milliseconds(300))
        check(eofLoss.requests == 1 && eofLoss.audio == [0, 4_000, 0],
              "rapid EOF resume cannot upload queued new audio during path loss")
        window("eof-suspend", since: eofLossBegan)
        eofLossSocket.networkAvailable = true
        await wait("EOF path restoration replays old unfinalized audio before queued new audio") { eofLoss.audio.count == 9 }
        // Leave this unpaused replacement alive through the timeout tests.
        // An obsolete EOF timer must not reset it ten seconds later.

        // Start a retrying drain alongside the existing unready timeout so
        // both exercise the real ten-second bound without doubling runtime.
        let retryTimeout = LocalDialect(base.appendingPathComponent("retry-timeout"), keepsWarm: true)
        let retryTimeoutSocket = ResilientSocket(dialect: retryTimeout)
        retryTimeoutSocket.start()
        bufferedSpeech(retryTimeoutSocket)
        retryTimeoutSocket.pause()
        let retryTimeoutBegan = ContinuousClock.now

        let noReady = LocalDialect(base.appendingPathComponent("no-ready"), keepsWarm: true)
        let noReadySocket = ResilientSocket(dialect: noReady)
        var noReadyStatus: SpeechEngineStatus = .idle
        noReadySocket.onStatus = { noReadyStatus = $0 }
        noReadySocket.start()
        bufferedSpeech(noReadySocket)
        noReadySocket.pause()
        let pauseBegan = ContinuousClock.now
        await wait("unready paused session stops within the bounded drain window", timeout: .seconds(11)) {
            noReadyStatus == .idle
        }
        check(pauseBegan.duration(to: .now) >= .seconds(9), "timeout cannot discard pending audio immediately")
        check(noReady.requests == 1 && noReady.audio.isEmpty && noReady.finals.isEmpty,
              "unready pause cannot send PCM or reconnect after the deadline")
        noReadySocket.stop()
        await wait("repeated connection failures keep the original paused drain deadline", timeout: .seconds(2)) {
            retryTimeoutSocket.status == .idle
        }
        check(retryTimeout.requests >= 2 && retryTimeout.audio.isEmpty && retryTimeout.finals.isEmpty,
              "bounded paused retries never upload to an unready server")
        check(retryTimeoutBegan.duration(to: .now) >= .seconds(9) && retryTimeoutBegan.duration(to: .now) < .seconds(12),
              "retry backoff cannot reset or bypass the authorized drain window")
        retryTimeoutSocket.stop()
        check(eofLoss.requests == 2 && eofLoss.opened == 2 && eofLossSocket.status == .live,
              "an obsolete EOF drain cannot reset a restored active session at its old deadline")
        eofLossSocket.send(pcm(8_000))
        eofLossSocket.pause()
        await wait("the restored EOF session completes both accepted phrases and fresh speech") { eofLoss.finals.count == 1 }
        check(eofLoss.finals[0] == [0, 4_000, 0, 0, 7_000, 0, 8_000],
              "EOF path recovery preserves every accepted interval once without leaking a stale final response")
        eofLossSocket.stop()
        print("PASS: real WebSocket socket lifecycle (\(assertions) assertions)")
    }
}
