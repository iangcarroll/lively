import Foundation
import os

/// Runs the on-device recognizer as a stopgap the moment listening starts,
/// while the chosen cloud engine connects in the background. When the cloud
/// becomes live, the audio heard during the wait is replayed to it and the
/// store swaps the provisional on-device turns for the server's transcript.
/// If the server never arrives — or drops later — the local engine carries on.
final class HybridSpeechEngine: SpeechEngine {
    enum Source {
        case local
        case cloud
    }

    var onEvent: (SpeechEvent) -> Void = { _ in }
    var onStatus: (SpeechEngineStatus) -> Void = { _ in }
    var networkAvailable: Bool {
        get { cloud.networkAvailable }
        set { cloud.networkAvailable = newValue }
    }
    var textLag: Duration { active == .local ? local.textLag : cloud.textLag }

    /// Events start coming from the other engine. `replayed` is how many
    /// seconds of audio were just handed to the cloud after a switch to it.
    var onSourceChange: ((Source, TimeInterval) -> Void)?

    private let local: SpeechEngine
    private let cloud: SpeechEngine
    private var active: Source = .local
    private var running = false
    private var cloudLive = false
    private var localLive = false
    private var localFailed = false
    private var cloudFailed = false

    /// Audio kept while the local engine is the stopgap. It's replayed to the
    /// cloud once it connects, so the server can transcribe that stretch more
    /// accurately. Capped so a long outage doesn't grow without bound.
    private var buffer: [Data] = []
    private var bufferedSeconds: TimeInterval = 0
    private let maxBufferSeconds: TimeInterval = 30
    private let sampleRate: Double = 16_000
    private let logger = Logger(subsystem: "sh.ian.lively", category: "hybrid")

    init(local: SpeechEngine, cloud: SpeechEngine) {
        self.local = local
        self.cloud = cloud
        wireLocal()
        wireCloud()
    }

    // MARK: - SpeechEngine

    func start() {
        guard !running else { return }
        running = true
        active = .local
        cloudLive = false
        localLive = false
        localFailed = false
        cloudFailed = false
        buffer.removeAll()
        bufferedSeconds = 0
        onStatus(.connecting)
        local.start()
        cloud.start()
    }

    func stop() {
        running = false
        buffer.removeAll()
        bufferedSeconds = 0
        local.stop()
        cloud.stop()
        onStatus(.idle)
    }

    func pause() { stop() }
    func resume() { start() }

    func prewarm() {
        // Only the server session is held; the local model is cheap to start.
        cloud.prewarm()
    }

    func send(_ chunk: Data) {
        guard running else { return }
        if active == .local {
            appendToBuffer(chunk)
            local.send(chunk)
        } else {
            cloud.send(chunk)
        }
    }

    func endTurn() {
        if active == .local { local.endTurn() } else { cloud.endTurn() }
    }

    func networkPathChanged() {
        cloud.networkPathChanged()
    }

    // MARK: - Wiring

    private func wireLocal() {
        local.onEvent = { [weak self] event in
            guard let self, self.running, self.active == .local else { return }
            self.onEvent(event)
        }
        local.onStatus = { [weak self] status in
            guard let self, self.running else { return }
            switch status {
            case .live:
                self.localLive = true
                self.localFailed = false
                if self.active == .local { self.onStatus(.live) }
            case .failed(let message):
                self.localLive = false
                self.localFailed = true
                guard self.active == .local else { return }
                // If the server is still on its way, wait for it instead of
                // failing the session over a missing local model.
                self.onStatus(self.cloudFailed ? .failed(message) : .connecting)
            case .connecting:
                if self.active == .local { self.onStatus(.connecting) }
            case .reconnecting, .idle:
                break
            }
        }
    }

    private func wireCloud() {
        cloud.onEvent = { [weak self] event in
            guard let self, self.running, self.active == .cloud else { return }
            self.onEvent(event)
        }
        cloud.onStatus = { [weak self] status in
            guard let self, self.running else { return }
            switch status {
            case .live:
                self.cloudFailed = false
                self.switchToCloud()
            case .reconnecting, .failed:
                self.cloudFailed = true
                if self.active == .cloud {
                    self.switchToLocal()
                } else if self.localFailed {
                    self.onStatus(.failed("Couldn't reach the speech service, and on-device recognition isn't available."))
                }
            case .connecting:
                if self.active == .cloud { self.onStatus(.connecting) }
            case .idle:
                break
            }
        }
    }

    // MARK: - Switching

    private func switchToCloud() {
        guard running else { return }
        guard active == .local else {
            onStatus(.live)
            return
        }
        // Close the stopgap turn so the server's transcript starts fresh.
        onEvent(.sessionReset)
        let replay = buffer
        let replayed = bufferedSeconds
        buffer.removeAll()
        bufferedSeconds = 0
        active = .cloud
        cloudLive = true
        onSourceChange?(.cloud, replayed)
        for chunk in replay { cloud.send(chunk) }
        local.stop()
        onStatus(.live)
        logger.info("server live; replayed \(replayed, format: .fixed(precision: 1)) s of stopgap audio")
    }

    private func switchToLocal() {
        guard running, active == .cloud else { return }
        onEvent(.sessionReset)
        active = .local
        cloudLive = false
        buffer.removeAll()
        bufferedSeconds = 0
        onSourceChange?(.local, 0)
        local.start()
        onStatus(.connecting)
        logger.info("server unavailable; on-device stopgap active")
    }

    // MARK: - Audio buffer

    private func appendToBuffer(_ chunk: Data) {
        buffer.append(chunk)
        bufferedSeconds += Double(chunk.count / MemoryLayout<Int16>.size) / sampleRate
        while bufferedSeconds > maxBufferSeconds, !buffer.isEmpty {
            let removed = buffer.removeFirst()
            bufferedSeconds -= Double(removed.count / MemoryLayout<Int16>.size) / sampleRate
        }
    }
}
