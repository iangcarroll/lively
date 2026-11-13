#!/usr/bin/env python3
"""Run deterministic startup regressions against ConversationStore's real methods.

Usage: python3 Tools/tests/conversation_startup_regression.py [--baseline HEAD]
The app has no test target. This compiles its startup methods verbatim with
controlled permission/audio fakes; no network, microphone, or app state is used.
"""

import argparse
import pathlib
import re
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = "Lively/Model/ConversationStore.swift"


def method(source, name):
    match = re.search(r"^    func " + name + r"\([^\n]*\) \{", source, re.M)
    if not match:
        raise RuntimeError("Missing production method: " + name)
    start = match.start()
    opening = source.index("{", start)
    # These lifecycle methods contain no string literals with unmatched braces.
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def build_source(source):
    names = ["isListening", "level", "isHearing", "alert", "settings", "mic",
             "demo", "gate", "speaker", "transcriberStatus", "listeningStart",
             "listeningGeneration", "utterances", "pendingDiscard"]
    fields = []
    for name in names:
        match = re.search(r"^    (?:private(?:\(set\))? )?(?:let|var) " + name + r"(?:[ : =].*)?$", source, re.M)
        if match:
            fields.append(match.group())
        # Older baselines predate stopgap turns; keep their methods buildable
        # so the original startup failure is still detected at runtime.
        elif name == "utterances":
            fields.append("    private(set) var utterances: [Utterance] = []")
        elif name == "pendingDiscard":
            fields.append("    private var pendingDiscard: TimeInterval?")
    methods = [method(source, name) for name in ["toggleListening", "startListening", "stopListening", "didEnterBackground"]]
    return PRELUDE + "\n@MainActor final class ConversationStore {\n" + "\n".join(fields) + SUPPORT + "\n".join(methods) + "\n}\n" + TESTS


PRELUDE = r'''
import Foundation

enum Failure: LocalizedError {
    case startup
    var errorDescription: String? { "injected startup failure" }
}
enum SpeechEngineStatus { case idle, live }
struct Credential: Sendable { let name: String }
struct SpeechProvider: Sendable {
    let id: String
    let credentials: [Credential]
    init(id: String = "cloud", credentials: [Credential] = [Credential(name: "test")]) {
        self.id = id
        self.credentials = credentials
    }
    static let onDevice = SpeechProvider(id: "on-device", credentials: [])
}
@MainActor final class AppSettings {
    var provider = SpeechProvider()
    var hasCredentials = true
}
struct NoiseGate { mutating func reset() {} }
@MainActor final class Utterance {
    var isProvisional: Bool
    init(isProvisional: Bool) { self.isProvisional = isProvisional }
}
@MainActor final class DemoConversation {
    func play(into: ConversationStore) {}
    func stop() {}
}
@MainActor final class Player {
    var stopCount = 0
    func stop() { stopCount += 1 }
}
@MainActor protocol TranslationSpeaker: AnyObject { func stop() }
@MainActor final class SonioxSpeaker: TranslationSpeaker {
    let player = Player()
    var stopCount = 0
    func stop() { stopCount += 1; player.stop() }
}

nonisolated final class MicCapture: @unchecked Sendable {
    @MainActor static var permissions: [CheckedContinuation<Bool, Never>] = []
    @MainActor static func requestPermission() async -> Bool {
        await withCheckedContinuation { permissions.append($0) }
    }
    @MainActor var starts: [CheckedContinuation<Void, Error>] = []
    private let lock = NSLock()
    private var syncStarts = 0
    @MainActor var stopCount = 0

    // The overload lets the original detached synchronous call compile too.
    func start() throws {
        lock.lock()
        syncStarts += 1
        lock.unlock()
    }
    @MainActor func start() async throws {
        try await withCheckedThrowingContinuation { starts.append($0) }
    }
    @MainActor func stop() { stopCount += 1 }
    func originalStartCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return syncStarts
    }
}
'''

SUPPORT = r'''
    var engineStarts = 0
    var engineReleases = 0
    var enginePauses = 0
    var stopDuringEngineStart = false
    init() { settings = AppSettings() }
    var testMic: MicCapture { mic }
    var testSettings: AppSettings { settings }
    var testPendingDiscard: TimeInterval? { pendingDiscard }
    func injectSpeaker(_ value: SonioxSpeaker) { speaker = value }
    func seedProvisionalTurn() -> Utterance {
        let utterance = Utterance(isProvisional: true)
        utterances.append(utterance)
        pendingDiscard = 5
        return utterance
    }
    func startEngine(_ provider: SpeechProvider) {
        engineStarts += 1
        if stopDuringEngineStart {
            stopListening()
            releaseEngine()
        }
    }
    func releaseEngine() { engineReleases += 1 }
    func pauseEngine() { enginePauses += 1 }
    func finalizeCurrent() {}
    func refreshStatus() {}
    static func keepScreenAwake(_ awake: Bool) {}
'''

TESTS = r'''
@main struct Regression {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        require(false, "timed out waiting for controlled suspension")
    }
    @MainActor static func drain() async {
        for _ in 0..<100 { await Task.yield() }
    }
    @MainActor static func permission(_ allowed: Bool) {
        require(!MicCapture.permissions.isEmpty, "no pending permission request")
        MicCapture.permissions.removeFirst().resume(returning: allowed)
    }
    @MainActor static func main() async throws {
        // Releasing a held mic while permission is visible must cancel startup.
        let released = ConversationStore()
        released.startListening()
        await until { !MicCapture.permissions.isEmpty }
        released.stopListening()
        permission(true)
        await drain()
        require(!released.isListening && released.engineStarts == 0,
                "released permission request restarted recording")
        require(released.testMic.starts.isEmpty && released.testMic.originalStartCount() == 0,
                "released permission request reached microphone startup")

        // Backgrounding uses the same cancellation path before permission returns.
        let background = ConversationStore()
        background.startListening()
        await until { !MicCapture.permissions.isEmpty }
        background.didEnterBackground()
        permission(true)
        await drain()
        require(!background.isListening && background.engineStarts == 0,
                "backgrounded permission request restarted recording")

        // A second tap cancels rather than creating another permission request.
        let toggled = ConversationStore()
        toggled.toggleListening()
        await until { !MicCapture.permissions.isEmpty }
        toggled.toggleListening()
        permission(true)
        await drain()
        require(!toggled.isListening && MicCapture.permissions.isEmpty,
                "second tap did not cancel pending startup")

        // An old permission callback must not clear or fail the newer request.
        let pending = ConversationStore()
        pending.startListening()
        await until { MicCapture.permissions.count == 1 }
        pending.stopListening()
        pending.startListening()
        await until { MicCapture.permissions.count == 2 }
        permission(false)
        await drain()
        pending.startListening()
        await drain()
        require(MicCapture.permissions.count == 1 && pending.alert == nil,
                "stale permission callback changed the newer request")
        permission(true)
        await until { pending.testMic.starts.count == 1 }
        pending.testMic.starts.removeFirst().resume()
        await drain()
        require(pending.isListening, "new request was lost after old permission callback")
        pending.stopListening()

        // A cancelled task may finish after the next session owns the mic.
        for staleFails in [false, true] {
            let store = ConversationStore()
            store.startListening()
            await until { !MicCapture.permissions.isEmpty }
            permission(true)
            await until { store.testMic.starts.count == 1 }
            store.stopListening()
            require(store.testMic.stopCount == 1, "stop did not reach capture")
            store.startListening()
            await until { !MicCapture.permissions.isEmpty }
            permission(true)
            await until { store.testMic.starts.count == 2 }
            let old = store.testMic.starts.removeFirst()
            if staleFails { old.resume(throwing: Failure.startup) }
            else { old.resume() }
            await drain()
            require(store.isListening && store.testMic.stopCount == 1,
                    "stale startup completion stopped the newer session")
            require(store.alert == nil && store.engineReleases == 0,
                    "stale startup failure changed the newer session")
            store.testMic.starts.removeFirst().resume()
            await drain()
            store.stopListening()
        }

        // Real startup errors still stop capture and reach the user.
        let failed = ConversationStore()
        failed.startListening()
        await until { !MicCapture.permissions.isEmpty }
        permission(true)
        await until { failed.testMic.starts.count == 1 }
        failed.testMic.starts.removeFirst().resume(throwing: Failure.startup)
        await drain()
        require(!failed.isListening && failed.testMic.stopCount == 1 && failed.engineReleases == 1,
                "current startup failure failed to clean up")
        require(failed.alert == "injected startup failure", "current startup failure was hidden")

        // Starting the mic cancels the entire speech producer. Stopping only
        // its player would allow an in-flight synthesis stream to refill it.
        let interruptedSpeech = ConversationStore()
        let producer = SonioxSpeaker()
        interruptedSpeech.injectSpeaker(producer)
        interruptedSpeech.startListening()
        await until { !MicCapture.permissions.isEmpty }
        permission(true)
        await until { interruptedSpeech.testMic.starts.count == 1 }
        require(producer.stopCount == 1 && producer.player.stopCount == 1,
                "microphone start stopped playback without cancelling synthesis")
        interruptedSpeech.testMic.starts.removeFirst().resume()
        await drain()
        interruptedSpeech.stopListening()

        // A local or hybrid engine can fail synchronously before mic startup.
        // That failure must cancel startup without taking an audio session.
        let engineFailed = ConversationStore()
        engineFailed.stopDuringEngineStart = true
        engineFailed.startListening()
        await until { !MicCapture.permissions.isEmpty }
        permission(true)
        await drain()
        require(!engineFailed.isListening && engineFailed.engineStarts == 1
                && engineFailed.engineReleases == 1 && engineFailed.enginePauses == 1,
                "synchronous engine failure did not stop the current request")
        require(engineFailed.testMic.starts.isEmpty
                && engineFailed.testMic.originalStartCount() == 0,
                "synchronous engine failure reached microphone startup")
        engineFailed.stopDuringEngineStart = false
        engineFailed.startListening()
        await until { !MicCapture.permissions.isEmpty }
        permission(true)
        await until { engineFailed.testMic.starts.count == 1 }
        engineFailed.testMic.starts.removeFirst().resume()
        await drain()
        require(engineFailed.isListening, "engine failure blocked the next start")
        engineFailed.stopListening()

        // On-device recognition doesn't need cloud credentials. A cloud
        // provider without credentials must still stop before permission.
        let local = ConversationStore()
        local.testSettings.provider = .onDevice
        local.testSettings.hasCredentials = false
        local.startListening()
        await until { !MicCapture.permissions.isEmpty }
        permission(true)
        await until { local.testMic.starts.count == 1 }
        local.testMic.starts.removeFirst().resume()
        await drain()
        require(local.isListening && local.engineStarts == 1 && local.alert == nil,
                "on-device startup required cloud credentials")

        // A stop keeps stopgap text and clears the pending cloud replacement.
        let provisional = local.seedProvisionalTurn()
        local.stopListening()
        require(!provisional.isProvisional && local.testPendingDiscard == nil,
                "stopping left provisional text pending replacement")
        require(!local.isListening && local.testMic.stopCount == 1,
                "stopping on-device capture did not stop the microphone")

        let noCredentials = ConversationStore()
        noCredentials.testSettings.hasCredentials = false
        noCredentials.startListening()
        await drain()
        require(noCredentials.engineStarts == 0 && MicCapture.permissions.isEmpty
                && noCredentials.testMic.starts.isEmpty && noCredentials.alert != nil,
                "cloud startup without credentials reached permission or capture")

        print("PASS: permission release, background, toggle cancellation, stale permission, stale success/failure, startup failure, synthesis interruption, synchronous engine failure, on-device credentials, provisional stop cleanup")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", metavar="REV", help="compile source from a git revision (expected to fail)")
    args = parser.parse_args()
    source = (subprocess.check_output(["git", "show", f"{args.baseline}:{SOURCE}"], cwd=ROOT, text=True)
              if args.baseline else (ROOT / SOURCE).read_text())
    with tempfile.TemporaryDirectory(prefix="lively-startup-regression-") as directory:
        directory = pathlib.Path(directory)
        swift = directory / "ConversationStartupRegression.swift"
        swift.write_text(build_source(source))
        executable = directory / "regression"
        subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(directory / "module-cache"), str(swift), "-o", str(executable)], check=True, cwd=ROOT)
        result = subprocess.run([str(executable)], cwd=ROOT, timeout=30)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
