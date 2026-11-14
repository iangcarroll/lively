import CoreML
import Foundation
import XCTest
@testable import NeuralVoices

final class EnginePolicyTests: XCTestCase, @unchecked Sendable {
    func testDefaultComputeUnitsMatchesPlatformSafetyPolicy() {
        #if os(iOS)
        XCTAssertEqual(NeuralVoiceEngine.defaultComputeUnits, .cpuOnly,
                       "iOS must avoid the observed INT8 MPSGraph compiler abort by default")
        #elseif os(macOS)
        XCTAssertEqual(NeuralVoiceEngine.defaultComputeUnits, .all,
                       "macOS retains its tested CoreML compute route")
        #else
        XCTFail("Define and validate the compute policy before supporting another platform")
        #endif
    }

    func testDistributionIncludesSourceAndResourceNotices() {
        let notices = NeuralVoiceEngine.licenseNotices
        XCTAssertTrue(notices.contains("31d676c6a7f1a3f9e3004c06914de54e61f0f987"))
        XCTAssertTrue(notices.contains("Apache License"))
        XCTAssertTrue(notices.contains("Copyright (c) 2016 dohliam"))
        XCTAssertTrue(notices.contains("Copyright (c) 2026 Stefan Taubert"))
    }

    func testUnloadedEngineDoesNotProduceAudio() async {
        let engine = NeuralVoiceEngine()
        do {
            _ = try await engine.synthesize(text: "Hello", voiceID: "af_heart", language: "en")
            XCTFail("An unloaded engine returned audio")
        } catch {
            XCTAssertEqual(error as? NeuralVoiceError, .unloaded)
        }
        let loaded = await engine.isLoaded
        XCTAssertFalse(loaded)
    }

    func testMissingAssetsAndUnload() async throws {
        let engine = NeuralVoiceEngine()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await engine.load(directory: directory)
            XCTFail("An empty directory loaded")
        } catch let NeuralVoiceError.missingAssets(files) {
            XCTAssertTrue(files.contains("vocab_index.json"))
            XCTAssertTrue(files.contains("kokoro_5s.mlmodelc/weights/weight.bin"))
        }
        await engine.unload()
        let voices = await engine.availableVoiceIDs
        XCTAssertTrue(voices.isEmpty)
    }

    func testStreamReportsUnloadedWithoutYielding() async {
        let engine = NeuralVoiceEngine()
        var chunks = 0
        do {
            for try await _ in engine.stream(text: "こんにちは。", voiceID: "jf_alpha", language: "ja") { chunks += 1 }
            XCTFail("An unloaded stream completed successfully")
        } catch {
            XCTAssertEqual(error as? NeuralVoiceError, .unloaded)
        }
        XCTAssertEqual(chunks, 0)
    }

    func testCancelledTaskStopsBeforeAssetWork() async {
        let engine = NeuralVoiceEngine()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.load(directory: URL(fileURLWithPath: "/definitely-missing-neural-voice-assets"))
        }
        do {
            try await task.value
            XCTFail("Cancelled loading succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
