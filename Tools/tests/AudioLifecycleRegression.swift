// Regression checks for MicCapture's start/stop lifecycle and
// AudioSessionUsers, run on macOS outside the app. Uses the DEBUG
// `LivelyAudioFile` path, so no microphone or permission is needed.
//
//   swiftc -swift-version 6 -parse-as-library -D DEBUG \
//     -default-isolation MainActor \
//     -enable-upcoming-feature NonisolatedNonsendingByDefault \
//     Lively/Audio/MicCapture.swift Tools/tests/AudioLifecycleRegression.swift \
//     -o "$TMPDIR/audio-lifecycle" && "$TMPDIR/audio-lifecycle"

import AVFoundation
import os

@main
struct AudioLifecycleRegression {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("ok   \(message)")
        } else {
            failures += 1
            print("FAIL \(message)")
        }
    }

    static func main() async throws {
        requests()
        sessionUsers()
        try await capture()
        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func requests() {
        var r = CaptureRequests()
        let a = r.begin()
        check(r.isCurrent(a), "a started request is current")
        r.cancel()
        check(!r.isCurrent(a) && r.active == nil, "stop makes the request stale")
        let b = r.begin()
        check(!r.isCurrent(a) && r.isCurrent(b), "a newer start supersedes an older one")
        r.fail(a)
        check(r.isCurrent(b), "an old request failing doesn't stop a newer one")
        check(!r.hasFailed(a), "an old failure isn't reported against a newer request")
        r.fail(b)
        check(r.active == nil && r.hasFailed(b), "the current request failing stops capture")
        _ = r.begin()
        check(!r.hasFailed(b), "a delayed failure report is dropped once a new start begins")
    }

    static func sessionUsers() {
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            let user: AudioSessionUsers.User = i.isMultiple(of: 2) ? .mic : .speech
            try? AudioSessionUsers.begin(user)
            AudioSessionUsers.end(user)
        }
        check(AudioSessionUsers.current.isEmpty, "concurrent begin/end leave no users behind")
    }

    static func capture() async throws {
        let url = try makeTone()
        UserDefaults.standard.register(defaults: ["LivelyAudioFile": url.path])
        let mic = MicCapture()
        let chunks = OSAllocatedUnfairLock(initialState: 0)
        mic.onChunk = { _, _ in chunks.withLock { $0 += 1 } }
        func count() -> Int { chunks.withLock { $0 } }

        try await mic.start()
        try await Task.sleep(for: .milliseconds(300))
        check(count() > 0, "a started capture delivers chunks")
        mic.stop()
        try await Task.sleep(for: .milliseconds(50))
        let atStop = count()
        try await Task.sleep(for: .milliseconds(300))
        check(count() == atStop, "no chunks after stop")

        // A start whose task only runs after stop(), cancelled by the stopper.
        let late = Task { try await mic.start() }
        mic.stop()
        late.cancel()
        try await late.value
        try await Task.sleep(for: .milliseconds(300))
        check(count() == atStop, "a cancelled start that runs after stop doesn't revive capture")

        // stop() lands while the start is queued: it must not come up.
        let stale = Task { try await mic.start() }
        await Task.yield()
        mic.stop()
        try await stale.value
        try await Task.sleep(for: .milliseconds(300))
        check(count() == atStop, "a start stopped mid-flight doesn't revive capture")

        // An old start finishing doesn't stop a newer session.
        let old = Task { try await mic.start() }
        await Task.yield()
        mic.stop()
        try await mic.start()
        try await old.value
        try await Task.sleep(for: .milliseconds(300))
        check(count() > atStop, "the newer session keeps running")

        // Hammer start/stop from many tasks; the last word is stop.
        var churn: [Task<Void, Never>] = []
        for i in 0..<200 {
            churn.append(Task {
                if i.isMultiple(of: 2) { try? await mic.start() } else { mic.stop() }
            })
        }
        for task in churn { await task.value }
        mic.stop()
        try await Task.sleep(for: .milliseconds(100))
        let settled = count()
        try await Task.sleep(for: .milliseconds(300))
        check(count() == settled, "after start/stop churn ending in stop, capture is off")
    }

    /// One second of a 440 Hz tone at 48 kHz, written to a temporary file.
    static func makeTone() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lively-tone-\(UUID()).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<48_000 {
            buffer.floatChannelData![0][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 48_000)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
