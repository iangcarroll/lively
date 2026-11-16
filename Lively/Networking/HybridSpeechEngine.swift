import Foundation
import os

/// Uses cloud automatic recognition whenever a network path is available.
/// Only actual path loss enables the explicitly selected offline language.
/// The cloud socket buffers its audio while connecting or retrying.
final class HybridSpeechEngine: SpeechEngine {
    enum Source { case local, cloud }
    private enum Phase { case stopped, prewarmed, listening, paused }

    var onEvent: (SpeechEvent) -> Void = { _ in }
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    var onSourceChange: ((Source, TimeInterval) -> Void)?
    var activeSource: Source { active }
    var textLag: Duration { active == .cloud ? cloud.textLag : local.textLag }
    var drainsTextOnPause: Bool { active == .cloud ? cloud.drainsTextOnPause : local.drainsTextOnPause }
    var networkAvailable: Bool {
        get { pathAvailable }
        set {
            let changed = pathAvailable != newValue
            pathAvailable = newValue
            switch phase {
            case .stopped:
                active = newValue ? .cloud : .local
                cloud.networkAvailable = newValue
            case .paused, .prewarmed:
                // A restored path must not reconnect a paused socket through
                // its networkAvailable setter. Resume applies it explicitly.
                if !newValue {
                    cloud.networkAvailable = false
                }
            case .listening:
                guard changed else { return }
                if newValue {
                    let replay = buffer
                    let seconds = bufferedSeconds
                    buffer.removeAll()
                    bufferedSeconds = 0
                    beginListening(source: .cloud, warm: false, replay: replay, replayed: seconds, reset: true)
                } else {
                    let token = generation
                    cloud.networkAvailable = false
                    guard generation == token, phase == .listening, !pathAvailable else { return }
                    beginListening(source: .local, warm: false, replay: [], replayed: 0, reset: true)
                }
            }
        }
    }

    private var local: SpeechEngine
    /// Settings can change while cloud recognition keeps running. Build the
    /// next offline session from those current settings when it is needed.
    private let makeLocal: (() -> SpeechEngine)?
    private let cloud: SpeechEngine
    private var phase: Phase = .stopped
    private var active: Source = .cloud
    private var pathAvailable: Bool
    private var localStarted = false
    private var cloudStarted = false
    /// The retained cloud may be suspended by a missing path while the local
    /// recognizer runs. Only microphone pause puts it into its drain state.
    private var cloudPaused = false
    private var localOwned = false
    private var cloudOwned = false
    private var generation = 0
    private var localSession = 0
    private var cloudSession = 0
    private var transitioning = false
    private var pendingInput: [Data] = []
    private var pendingSeconds: TimeInterval = 0
    /// Pause clears the offline replay window before any path restoration.
    private var buffer: [Data] = []
    private var bufferedSeconds: TimeInterval = 0
    private let maxBufferSeconds: TimeInterval = 30
    private let bytesPerSecond: Double = 16_000 * Double(MemoryLayout<Int16>.size)
    private let logger = Logger(subsystem: "sh.ian.lively", category: "hybrid")

    init(local: SpeechEngine, cloud: SpeechEngine, makeLocal: (() -> SpeechEngine)? = nil) {
        self.local = local
        self.cloud = cloud
        self.makeLocal = makeLocal
        pathAvailable = cloud.networkAvailable
        active = pathAvailable ? .cloud : .local
    }

    func start() { resume() }

    func resume() {
        guard phase != .listening else { return }
        let source: Source = pathAvailable ? .cloud : .local
        let warm = (phase == .paused || phase == .prewarmed) && source == active
        beginListening(source: source, warm: warm, replay: [], replayed: 0, reset: source != active)
    }

    func pause() {
        guard phase == .listening else { return }
        generation += 1
        phase = .paused
        transitioning = false
        pendingInput.removeAll()
        pendingSeconds = 0
        buffer.removeAll()
        bufferedSeconds = 0
        // Keep this callback epoch: already accepted cloud audio can produce
        // final tokens after the microphone has stopped.
        if cloudStarted, !cloudPaused {
            cloudPaused = true
            cloud.pause()
        }
        if active == .local, localStarted { local.pause() }
    }

    func stop() {
        tearDown()
        onStatus(.idle)
    }

    private func tearDown() {
        generation += 1
        phase = .stopped
        transitioning = false
        pendingInput.removeAll()
        pendingSeconds = 0
        buffer.removeAll()
        bufferedSeconds = 0
        stopCloud()
        stopLocal()
    }

    func prewarm() {
        guard phase == .stopped, pathAvailable else { return }
        generation += 1
        let token = generation
        phase = .prewarmed
        active = .cloud
        onSourceChange?(.cloud, 0)
        guard generation == token, phase == .prewarmed else { return }
        cloudSession += 1
        wireCloud(session: cloudSession)
        cloudStarted = true
        cloudOwned = true
        cloudPaused = true
        cloud.networkAvailable = true
        cloud.prewarm()
    }

    func send(_ chunk: Data) {
        guard phase == .listening, !chunk.isEmpty else { return }
        if transitioning {
            append(chunk, to: &pendingInput, seconds: &pendingSeconds)
        } else if active == .cloud {
            if cloudStarted { cloud.send(chunk) }
        } else {
            append(chunk, to: &buffer, seconds: &bufferedSeconds)
            if localStarted { local.send(chunk) }
        }
    }

    func endTurn() {
        guard phase == .listening else { return }
        if active == .cloud { cloud.endTurn() } else { local.endTurn() }
    }

    func networkPathChanged() {
        guard phase == .listening, active == .cloud, pathAvailable, cloudStarted else { return }
        cloud.networkPathChanged()
    }

    private func beginListening(source: Source, warm: Bool, replay: [Data], replayed: TimeInterval, reset: Bool) {
        generation += 1
        let token = generation
        phase = .listening
        transitioning = true
        pendingInput.removeAll()
        pendingSeconds = 0
        if source != active {
            if active == .local { stopLocal() }
            // The socket owns the earlier cloud interval, including audio
            // not yet finalized. A path outage suspends it without clearing
            // that bounded backlog. Rebind callbacks to reject old source
            // callbacks without destroying the retained socket.
            cloudSession += 1
            wireCloud(session: cloudSession)
        }
        active = source
        if reset {
            onEvent(.sessionReset)
            guard generation == token, phase == .listening else { return }
        }
        // Select the store's translator before synchronous readiness or text.
        onSourceChange?(source, replayed)
        guard generation == token, phase == .listening else { return }
        if source == .cloud {
            if cloudOwned, cloudStarted {
                cloud.networkAvailable = pathAvailable
                guard generation == token, phase == .listening else { return }
                if cloudPaused {
                    cloudPaused = false
                    cloud.resume()
                }
            } else {
                stopCloud()
                cloudSession += 1
                wireCloud(session: cloudSession)
                cloudStarted = true
                cloudOwned = true
                cloudPaused = false
                cloud.networkAvailable = pathAvailable
                cloud.start()
            }
        } else if warm, localStarted {
            local.resume()
        } else {
            stopLocal()
            if let makeLocal { local = makeLocal() }
            localSession += 1
            wireLocal(session: localSession)
            localStarted = true
            localOwned = true
            local.start()
        }
        guard generation == token, phase == .listening else { return }
        for chunk in replay {
            cloud.send(chunk)
            guard generation == token, phase == .listening else { return }
        }
        // A source callback can synchronously supply fresh input. Replay the
        // older offline interval before those chunks or later live audio.
        while !pendingInput.isEmpty {
            let chunk = pendingInput.removeFirst()
            pendingSeconds -= Double(chunk.count) / bytesPerSecond
            if source == .cloud { cloud.send(chunk) }
            else {
                append(chunk, to: &buffer, seconds: &bufferedSeconds)
                if localStarted { local.send(chunk) }
            }
            guard generation == token, phase == .listening else { return }
        }
        transitioning = false
        logger.info("recognition source: \(source == .cloud ? "cloud" : "local", privacy: .public)")
    }

    private func stopCloud() {
        cloudSession += 1
        cloudStarted = false
        cloudPaused = false
        guard cloudOwned else { return }
        cloudOwned = false
        cloud.stop()
    }
    private func stopLocal() {
        localSession += 1
        localStarted = false
        guard localOwned else { return }
        localOwned = false
        local.stop()
    }

    private func wireCloud(session: Int) {
        cloud.onEvent = { [weak self] event in
            guard let self, self.cloudSession == session, self.active == .cloud,
                  self.phase != .stopped else { return }
            self.onEvent(event)
        }
        cloud.onStatus = { [weak self] status in
            guard let self, self.cloudSession == session, self.phase != .stopped else { return }
            // A retained socket can reach its drain deadline or fail while
            // the explicitly selected offline recognizer owns the screen.
            // Track its lifecycle without ending the microphone's session.
            if status == .idle { self.cloudStarted = false }
            if case .failed = status { self.cloudStarted = false }
            guard self.active == .cloud, self.pathAvailable else { return }
            switch status {
            case .failed:
                self.tearDown()
                self.onStatus(status)
            default:
                // Online service failures never activate a fixed-locale
                // recognizer. The cloud socket owns its retry and backlog.
                self.onStatus(status)
            }
        }
    }

    private func wireLocal(session: Int) {
        local.onEvent = { [weak self] event in
            guard let self, self.localSession == session, self.active == .local,
                  self.phase != .stopped else { return }
            self.onEvent(event)
        }
        local.onStatus = { [weak self] status in
            guard let self, self.localSession == session, self.active == .local,
                  self.phase != .stopped else { return }
            if status == .idle { self.localStarted = false }
            if case .failed = status {
                if self.phase == .listening, !self.pathAvailable, self.cloudOwned {
                    // Missing local assets must not terminate an online
                    // conversation during a short path outage. Keep new PCM
                    // in the bounded replay window until the path returns.
                    self.stopLocal()
                    self.onStatus(.reconnecting)
                    return
                }
                self.tearDown()
            }
            self.onStatus(status)
        }
    }

    private func append(_ chunk: Data, to chunks: inout [Data], seconds: inout TimeInterval) {
        chunks.append(chunk)
        seconds += Double(chunk.count) / bytesPerSecond
        while seconds > maxBufferSeconds, !chunks.isEmpty {
            let removed = chunks.removeFirst()
            seconds -= Double(removed.count) / bytesPerSecond
        }
    }
}
