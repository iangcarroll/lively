import AVFoundation
import CoreMedia
import Foundation
import os

// Speech API fakes deliberately provide no download method. Compiling the real
// engine here also verifies that listening cannot initiate an asset download.
enum Language: String, Hashable, Sendable {
    case english = "en", chinese = "zh", french = "fr"
    var englishName: String { switch self { case .english: "English"; case .chinese: "Chinese"; case .french: "French" } }
}
struct LanguagePair {
    var first: Language = .english
    var second: Language = .chinese
    var all: [Language] { [first, second] }
    func contains(_ language: Language) -> Bool { all.contains(language) }
}
enum ChineseScript { case simplified, traditional }
enum SpeechEvent { case replaceText(String, Language?), turnStarted, turnEnded }
enum SpeechEngineStatus: Equatable { case idle, connecting, live, failed(String) }
protocol SpeechEngine: AnyObject {
    var onEvent: (SpeechEvent) -> Void { get set }
    var onStatus: (SpeechEngineStatus) -> Void { get set }
    var networkAvailable: Bool { get set }
    var textLag: Duration { get }
    func start()
    func stop()
    func pause()
    func resume()
    func send(_ data: Data)
    func endTurn()
}
struct AnalyzerInput {
    var buffer: AVAudioPCMBuffer
    var bufferStartTime: CMTime?
    init(buffer: AVAudioPCMBuffer, bufferStartTime: CMTime? = nil) {
        self.buffer = buffer
        self.bufferStartTime = bufferStartTime
    }
}
@MainActor enum Hooks {
    static var available = true
    static var supported = true
    static var installed = true
    static var delayStart = false
    static var starts: [CheckedContinuation<Void, Error>] = []
    static var transcribers: [SpeechTranscriber] = []
    static var analyzers: [SpeechAnalyzer] = []
    static var requestedLocales: [Locale] = []
    static var format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    static func reset() {
        available = true; supported = true; installed = true; delayStart = false
        starts.removeAll(); transcribers.removeAll(); analyzers.removeAll(); requestedLocales.removeAll()
    }
}
@MainActor final class SpeechTranscriber {
    enum ReportingOption: Hashable { case volatileResults, fastResults }
    enum AttributeOption: Hashable { case audioTimeRange }
    struct Result: Sendable {
        var text: AttributedString
        var range: CMTimeRange
        var isFinal: Bool
    }
    let locale: Locale
    let results: AsyncThrowingStream<Result, Error>
    private let output: AsyncThrowingStream<Result, Error>.Continuation
    init(locale: Locale, transcriptionOptions: Set<Int>, reportingOptions: Set<ReportingOption>, attributeOptions: Set<AttributeOption>) {
        self.locale = locale
        let pair = AsyncThrowingStream<Result, Error>.makeStream()
        results = pair.stream
        output = pair.continuation
        Hooks.transcribers.append(self)
    }
    static var isAvailable: Bool { Hooks.available }
    static func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        Hooks.requestedLocales.append(locale)
        return Hooks.supported ? locale : nil
    }
    func emit(_ text: String, from: Double, to: Double, final: Bool = false) {
        output.yield(Result(text: AttributedString(text), range: CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 16000), end: CMTime(seconds: to, preferredTimescale: 16000)), isFinal: final))
    }
    func fail() { output.finish(throwing: TestFailure.injected) }
}
@MainActor enum AssetInventory {
    enum Status { case unsupported, supported, installed }
    static func status(forModules modules: [SpeechTranscriber]) async -> Status { Hooks.installed ? .installed : .supported }
}
@MainActor final class SpeechAnalyzer {
    var cancelled = false
    var received: [AnalyzerInput] = []
    var boundaries: [CMTime] = []
    private var consumer: Task<Void, Never>?
    init(modules: [SpeechTranscriber]) { Hooks.analyzers.append(self) }
    static func bestAvailableAudioFormat(compatibleWith modules: [SpeechTranscriber]) async -> AVAudioFormat? { Hooks.format }
    func start(inputSequence: AsyncStream<AnalyzerInput>) async throws {
        if Hooks.delayStart {
            try await withCheckedThrowingContinuation { Hooks.starts.append($0) }
        }
        consumer = Task { [weak self] in
            for await input in inputSequence {
                guard !Task.isCancelled else { return }
                self?.received.append(input)
            }
        }
    }
    func cancelAndFinishNow() async { cancelled = true; consumer?.cancel(); consumer = nil }
    func finalize(through time: CMTime?) async throws { if let time { boundaries.append(time) } }
}
// A cross-boundary result without word timestamps must be discarded rather
// than leaking old text. Native Speech supplies these attributes in the app.
extension AttributedString {
    func rangeOfAudioTimeRangeAttributes(intersecting timeRange: CMTimeRange) -> Range<AttributedString.Index>? { nil }
}
enum TestFailure: Error { case injected }

// INSERT_ACTUAL_OFFLINE_ENGINE

extension OfflineSpeechEngine {
    var testIsRunning: Bool { isRunning }
    var testPendingCount: Int { pendingAudio.count }
}

@main struct Regression {
    @MainActor static var assertions = 0
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { print("FAIL: \(message)"); exit(1) }
    }
    @MainActor static func until(_ predicate: () -> Bool) async {
        for _ in 0..<20_000 { if predicate() { return }; await Task.yield() }
        require(false, "timed out at controlled suspension")
    }
    @MainActor static func drain() async { for _ in 0..<300 { await Task.yield() } }
    static func audio() -> Data {
        [Int16](repeating: 12_000, count: 1_280).withUnsafeBytes { Data($0) }
    }
    @MainActor static func main() async throws {
        for chosen in [Language.english, .chinese] {
            Hooks.reset()
            let engine = OfflineSpeechEngine(languages: LanguagePair(), script: .simplified, spokenLanguage: chosen)
            var statuses: [SpeechEngineStatus] = []
            var sources: [Language?] = []
            engine.onStatus = { statuses.append($0) }
            engine.onEvent = { if case .replaceText(_, let language) = $0 { sources.append(language) } }
            engine.networkAvailable = false
            engine.start()
            await until { statuses.contains(.live) }
            require(Hooks.transcribers.count == 1, "selected-speaker mode created competing recognizers")
            let expected = chosen == .chinese ? "zh-CN" : "en"
            require(Hooks.transcribers[0].locale.identifier == expected, "selected speaker did not select recognition locale")
            engine.send(audio())
            Hooks.transcribers[0].emit(chosen == .chinese ? "你好" : "yes", from: 0, to: 0.05)
            await until { !sources.isEmpty }
            require(sources == [chosen], "transcript carried a guessed or wrong language")
            await until { !Hooks.analyzers[0].received.isEmpty }
            require(Hooks.analyzers[0].received[0].buffer.format.sampleRate == 24_000, "analyzer received source sample rate instead of converted rate")
            require(Hooks.analyzers[0].received[0].bufferStartTime == .zero, "input time origin missing")
            engine.stop()
            await drain()
            require(!engine.testIsRunning && Hooks.analyzers.allSatisfy(\.cancelled), "stop left recognition resources active")
        }

        Hooks.reset(); Hooks.installed = false
        let missing = OfflineSpeechEngine(languages: LanguagePair(), script: .simplified)
        var missingStatuses: [SpeechEngineStatus] = []
        missing.onStatus = { missingStatuses.append($0) }
        missing.start()
        await until { missingStatuses.contains { if case .failed = $0 { true } else { false } } }
        if case .failed(let message) = missingStatuses.last {
            require(message.contains("Offline Languages") && message.contains("online"), "missing assets lacked download instructions")
        } else { require(false, "asset failure was overwritten by idle") }
        require(Hooks.analyzers.isEmpty && !missing.testIsRunning, "missing assets started an analyzer")

        Hooks.reset(); Hooks.available = false
        let unsupported = OfflineSpeechEngine(languages: LanguagePair(), script: .simplified)
        var unsupportedStatuses: [SpeechEngineStatus] = []
        unsupported.onStatus = { unsupportedStatuses.append($0) }
        unsupported.start()
        await until { unsupportedStatuses.count == 2 }
        require(Hooks.requestedLocales.isEmpty, "unsupported hardware attempted setup")
        require(!unsupported.testIsRunning, "unsupported hardware became live")

        // Cancel A while native analyzer startup is suspended, then suspend B.
        // A's eventual cancellation must not clear B's start task or stop B.
        Hooks.reset(); Hooks.delayStart = true
        let racing = OfflineSpeechEngine(languages: LanguagePair(), script: .simplified)
        racing.start()
        await until { Hooks.starts.count == 1 }
        let old = Hooks.starts.removeFirst()
        racing.stop(); racing.start()
        await until { Hooks.starts.count == 1 }
        old.resume(throwing: CancellationError())
        await drain()
        racing.start()
        await drain()
        require(Hooks.analyzers.count == 2 && Hooks.starts.count == 1, "old setup cleared the replacement's startup guard")
        Hooks.starts.removeFirst().resume()
        await until { racing.testIsRunning }
        require(Hooks.analyzers[0].cancelled && !Hooks.analyzers[1].cancelled, "stale setup cleaned up the replacement analyzer")
        racing.stop()
        await drain()

        Hooks.reset()
        var disposable: OfflineSpeechEngine? = OfflineSpeechEngine(languages: LanguagePair(), script: .simplified)
        weak var released = disposable
        disposable?.start()
        await until { disposable?.testIsRunning == true }
        await drain()
        disposable = nil
        await until { released == nil && Hooks.analyzers.allSatisfy(\.cancelled) }
        require(Hooks.analyzers.count == 1, "release cleanup lost track of its live analyzer")

        Hooks.reset(); Hooks.delayStart = true
        let buffered = OfflineSpeechEngine(languages: LanguagePair(), script: .simplified)
        buffered.start()
        await until { Hooks.starts.count == 1 }
        for _ in 0..<500 { buffered.send(Data(repeating: 0, count: 2560)) }
        require(buffered.testPendingCount == 375, "startup buffering was unbounded")
        buffered.stop()
        Hooks.starts.removeFirst().resume()
        await drain()
        require(buffered.testPendingCount == 0 && !buffered.testIsRunning, "cancelled startup replayed its pending audio")

        Hooks.reset()
        let turns = OfflineSpeechEngine(languages: LanguagePair(), script: .simplified)
        var events: [String] = []
        turns.onEvent = {
            switch $0 {
            case .turnStarted: events.append("start")
            case .turnEnded: events.append("end")
            case .replaceText(let text, _): events.append(text)
            }
        }
        turns.start()
        await until { turns.testIsRunning }
        turns.send(Data(repeating: 0, count: 2560))
        require(events.isEmpty, "silence opened a turn")
        turns.send(audio())
        let transcriber = Hooks.transcribers[0]
        transcriber.emit("go", from: 0.08, to: 0.10, final: true)
        await until { events.last == "go" }
        transcriber.emit("go", from: 0.08, to: 0.10, final: true)
        transcriber.emit("go", from: 0.10, to: 0.13, final: true)
        await until { events.last == "go go" }
        require(events == ["start", "go", "go go"], "final deduplication removed a distinct repeated word or repeated a final result")
        turns.endTurn()
        require(events.last == "go go", "turn ended before final recognition grace")
        turns.send(audio())
        require(Array(events.suffix(2)) == ["end", "start"], "new speech failed to close old turn before opening the next")
        transcriber.emit("late old words", from: 0.08, to: 0.13)
        transcriber.emit("crossing words", from: 0.13, to: 0.20)
        transcriber.emit("new words", from: 0.16, to: 0.20)
        await until { events.last == "new words" }
        require(!events.contains("late old words") && !events.contains("crossing words"), "previous-turn words leaked into a new turn")
        try await Task.sleep(for: .milliseconds(550))
        require(events.last == "new words", "old grace timer closed the newer turn")
        turns.endTurn()
        try await Task.sleep(for: .milliseconds(550))
        require(events.last == "end", "turn did not close after recognition grace")
        let beforeFailure = events.count
        transcriber.fail()
        await until { !turns.testIsRunning }
        turns.send(audio())
        require(events.count == beforeFailure, "failed recognition kept accepting speech")
        await drain()
        require(Hooks.analyzers.allSatisfy(\.cancelled), "result-stream failure retained analyzer")

        print("PASS: \(assertions) offline assertions for selected locale, installed-only assets, cancellation generations, bounded buffering, native conversion, and turn isolation")
    }
}
