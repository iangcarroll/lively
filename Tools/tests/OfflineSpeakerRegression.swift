import AVFoundation
import Foundation

// Production OfflineSpeaker.swift is compiled unchanged alongside this file.
struct Language: Equatable {
    let rawValue: String
    var englishName: String { rawValue }
    static let english = Language(rawValue: "en")
    static let chinese = Language(rawValue: "zh")
}
enum ChineseScript { case simplified, traditional }

final class SpeechPlayer {
    enum Output: Equatable { case automatic, headphones, speaker }
    static let sampleRate: Double = 24_000
    var prepared: [Output] = []
    var played: [Data] = []
    var headphonesAvailable = true
    var holdNextPrepare = false
    var prepareError: Error?
    private var drain: CheckedContinuation<Void, Error>?

    func prepare(output: Output) async throws -> Bool {
        prepared.append(output)
        if let prepareError { throw prepareError }
        if output == .headphones, !headphonesAvailable { return false }
        if holdNextPrepare {
            holdNextPrepare = false
            try await withCheckedThrowingContinuation { drain = $0 }
        }
        return true
    }
    func releasePrepare() { drain?.resume(); drain = nil }
    func play(_ data: Data) { played.append(data) }
    func stop() { drain?.resume(throwing: CancellationError()); drain = nil }
}

enum TestError: LocalizedError {
    case render, route
    var errorDescription: String? { self == .render ? "render failed" : "route failed" }
}

final class Renderer: OfflineSpeechRendering {
    var calls: [(String, Language)] = []
    var streams: [AsyncThrowingStream<Data, Error>.Continuation] = []
    var stops = 0
    var failure: Error?
    func audio(for text: String, language: Language) throws -> AsyncThrowingStream<Data, Error> {
        if let failure { throw failure }
        calls.append((text, language))
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        streams.append(continuation)
        return stream
    }
    // Deliberately retain callbacks after stop to model a late system result.
    func stop() { stops += 1 }
}

@main struct OfflineSpeakerRegression {
    static var assertions = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() {
            FileHandle.standardError.write(Data(("FAIL: \(message)\n").utf8))
            exit(1)
        }
    }
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        require(false, "timed out waiting for a controlled speech callback")
    }
    static func settle() async { for _ in 0..<100 { await Task.yield() } }

    static func main() async throws {
        let renderer = Renderer()
        let speaker = OfflineSpeaker(renderer: renderer)
        speaker.speak("  ", in: .english)
        await settle()
        require(renderer.calls.isEmpty, "empty speech reached synthesis")
        speaker.speak(" first ", in: .english, output: .headphones)
        speaker.speak("second", in: .chinese, output: .speaker)
        await until { renderer.calls.count == 1 }
        require(renderer.calls[0].0 == "first" && renderer.calls[0].1 == .english,
                "queued speech lost its text or language")
        renderer.streams[0].yield(Data([1, 2]))
        await until { speaker.player.played.count == 1 }
        speaker.player.holdNextPrepare = true
        renderer.streams[0].finish()
        await until { speaker.player.prepared.count == 2 }
        require(renderer.calls.count == 1, "next destination synthesized before playback drained")
        speaker.player.releasePrepare()
        await until { renderer.calls.count == 2 }
        renderer.streams[1].yield(Data([3, 4]))
        renderer.streams[1].finish()
        await until { speaker.player.played.count == 2 }
        require(speaker.player.prepared == [.headphones, .speaker], "sentence output changed in the queue")
        require(speaker.player.played == [Data([1, 2]), Data([3, 4])], "audio played out of order")
        speaker.stop()

        let privateRenderer = Renderer()
        let privateSpeaker = OfflineSpeaker(renderer: privateRenderer)
        privateSpeaker.player.headphonesAvailable = false
        privateSpeaker.speak("private", in: .english, output: .headphones)
        privateSpeaker.speak("public", in: .chinese, output: .speaker)
        await until { privateRenderer.calls.count == 1 }
        require(privateRenderer.calls[0].0 == "public", "missing headphones synthesized private speech")
        require(privateSpeaker.player.prepared == [.headphones, .speaker], "missing headphones blocked outgoing speech")
        privateRenderer.streams[0].finish()
        privateSpeaker.stop()

        let lateRenderer = Renderer()
        let lateSpeaker = OfflineSpeaker(renderer: lateRenderer)
        var lateErrors: [String] = []
        lateSpeaker.onError = { lateErrors.append($0) }
        lateSpeaker.speak("old", in: .english)
        await until { lateRenderer.calls.count == 1 }
        lateSpeaker.stop()
        lateSpeaker.speak("new", in: .chinese, output: .speaker)
        await until { lateRenderer.calls.count == 2 }
        lateRenderer.streams[0].yield(Data([9, 9]))
        lateRenderer.streams[0].finish(throwing: TestError.render)
        lateSpeaker.speak("third", in: .english, output: .headphones)
        await settle()
        require(lateRenderer.calls.count == 2, "old worker cleared the newer worker")
        lateRenderer.streams[1].yield(Data([5, 6]))
        lateRenderer.streams[1].finish()
        await until { lateRenderer.calls.count == 3 }
        require(lateSpeaker.player.played == [Data([5, 6])], "late cancelled speech reached playback")
        require(lateErrors.isEmpty, "late cancelled failure reached the user")
        lateRenderer.streams[2].finish()
        lateSpeaker.stop()

        let failingRenderer = Renderer()
        let failingSpeaker = OfflineSpeaker(renderer: failingRenderer)
        var errors: [String] = []
        failingSpeaker.onError = { errors.append($0) }
        failingRenderer.failure = TestError.render
        failingSpeaker.speak("fail", in: .english)
        failingSpeaker.speak("discard", in: .chinese)
        await until { !errors.isEmpty }
        require(errors == ["render failed"] && failingRenderer.calls.isEmpty,
                "synthesis failure was hidden or repeated against queued speech")
        failingRenderer.failure = nil
        failingSpeaker.speak("retry", in: .english)
        await until { failingRenderer.calls.count == 1 }
        failingRenderer.streams[0].finish()
        failingSpeaker.stop()

        let routeRenderer = Renderer()
        let routeSpeaker = OfflineSpeaker(renderer: routeRenderer)
        routeSpeaker.player.prepareError = TestError.route
        var routeErrors: [String] = []
        routeSpeaker.onError = { routeErrors.append($0) }
        routeSpeaker.speak("fail", in: .english, output: .headphones)
        await until { !routeErrors.isEmpty }
        require(routeErrors == ["route failed"] && routeRenderer.calls.isEmpty,
                "routing failure synthesized speech or hid the error")
        routeSpeaker.stop()

        voiceSelection()
        try await conversion()
        require(!OfflineSpeaker.hasVoice(for: Language(rawValue: "not-a-language")),
                "missing language used a default voice")
        print("PASS: offline speech queue, direction, drain, cancellation, stale callbacks, errors, voice ranking, native PCM conversion (\(assertions) assertions)")
    }

    static func voiceSelection() {
        typealias Voice = OfflineVoiceSelection.Candidate
        let legacy = Voice(identifier: "com.apple.eloquence.zh-CN.Reed", language: "zh-CN", quality: 1)
        let compact = Voice(identifier: "com.apple.voice.compact.zh-CN.Tingting", language: "zh-CN", quality: 1)
        let bundled = Voice(identifier: "com.apple.ttsbundle.Ting-Ting-compact", language: "zh-CN", quality: 1)
        let enhanced = Voice(identifier: "com.apple.voice.enhanced.zh-CN.Tingting", language: "zh-CN", quality: 2)
        let premiumOtherRegion = Voice(identifier: "com.apple.voice.premium.zh-TW.Meijia", language: "zh-TW", quality: 3)
        func chosen(_ candidates: [Voice], preferred: String? = nil) -> String? {
            OfflineVoiceSelection.best(in: candidates, preferredLanguage: "zh-CN", preferredIdentifier: preferred)
        }
        require(chosen([legacy, compact]) == compact.identifier,
                "lexically earlier legacy voice won over modern speech")
        require(chosen([compact, legacy], preferred: legacy.identifier) == compact.identifier,
                "legacy system choice displaced an available modern voice")
        require(chosen([legacy, bundled]) == bundled.identifier,
                "available bundled modern voice lost to legacy speech")
        require(chosen([compact, bundled], preferred: bundled.identifier) == bundled.identifier,
                "same-quality modern voices ignored the system's language choice")
        require(chosen([compact, enhanced], preferred: compact.identifier) == enhanced.identifier,
                "system preference displaced higher-quality installed speech")
        require(chosen([premiumOtherRegion, compact]) == compact.identifier,
                "voice selection changed the requested Mandarin region")
        require(chosen([legacy]) == legacy.identifier, "legacy-only device lost its available voice")
        require(chosen([]) == nil, "empty installed voice list produced a voice")
        require(chosen([compact], preferred: enhanced.identifier) == compact.identifier,
                "unavailable preferred voice displaced an installed voice")
        require(chosen([legacy, compact, enhanced]) == chosen([enhanced, compact, legacy]),
                "voice selection depended on the system's enumeration order")
    }

    static func conversion() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        input.frameLength = 480
        for index in 0..<480 { input.floatChannelData![0][index] = 0.25 }
        let end = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let pcm = OfflineSpeechPCMStream(continuation: continuation)
        for _ in 0..<10 { pcm.accept(input) }
        pcm.accept(end)
        // Late callbacks after the terminal buffer must not add samples.
        pcm.accept(input)
        var audio = Data()
        for try await bytes in stream { audio.append(bytes) }
        require(abs(audio.count / 2 - 2400) <= 2, "48 kHz speech wasn't converted to 24 kHz PCM16")
        let sample = audio.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1000, as: Int16.self) }
        require(abs(Int(sample) - 8192) < 10, "PCM16 speech amplitude or byte order changed")

        let (cancelledStream, cancelledContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let cancelled = OfflineSpeechPCMStream(continuation: cancelledContinuation)
        cancelled.cancel()
        cancelled.accept(input)
        cancelled.accept(end)
        var samples = 0
        do {
            for try await bytes in cancelledStream { samples += bytes.count }
            require(false, "cancelled synthesis completed as successful speech")
        } catch is CancellationError {
            require(samples == 0, "speech callback after cancellation produced audio")
        }

        let (emptyStream, emptyContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        OfflineSpeechPCMStream(continuation: emptyContinuation).accept(end)
        do {
            for try await _ in emptyStream {}
            require(false, "empty synthesis claimed success")
        } catch {
            require(error.localizedDescription.contains("didn't produce audio"), "empty synthesis lost its actionable error")
        }
    }
}
