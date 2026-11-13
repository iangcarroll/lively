// The runner compiles actual MicCapture and AudioSessionUsers with real
// AVFoundation, replacing only the hardware engine-start call. Session
// ownership, asynchronous lifecycle work, teardown and deinit are unchanged.
extension MicCapture {
    func testLifecycleQueue() -> DispatchQueue { lifecycle }
}

@main struct DirectionalSpeechAdversarialMic {
    static var failures = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() { print("PASS: \(message)") }
        else { failures += 1; print("FAIL: \(message)") }
    }
    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    static func main() async throws {
        var stopped: MicCapture? = MicCapture()
        try await stopped!.start()
        check(AudioSessionUsers.current.contains(.mic), "explicit-stop control acquires the actual session claim")
        stopped!.stop()
        await settle { !AudioSessionUsers.current.contains(.mic) }
        check(AudioSessionUsers.current.isEmpty, "explicit-stop control releases the actual session claim")
        weak let stoppedReference = stopped
        stopped = nil
        await settle { stoppedReference == nil }
        check(stoppedReference == nil, "explicit-stop control deallocates capture")

        var abandoned: MicCapture? = MicCapture()
        try await abandoned!.start()
        check(AudioSessionUsers.current.contains(.mic), "deinit case acquires the actual session claim")
        weak let abandonedReference = abandoned
        abandoned = nil
        await settle { abandonedReference == nil }
        check(abandonedReference == nil, "deinit case actually deallocates capture")
        await settle { !AudioSessionUsers.current.contains(.mic) }
        check(AudioSessionUsers.current.isEmpty, "deallocating a running capture releases its session claim")
        // Keep this executable isolated, even when the assertion failed.
        AudioSessionUsers.end(.mic)

        // Delay only the old object's lifecycle queue. The replacement must
        // retain ownership while the old object's queued destructor runs.
        var prior: MicCapture? = MicCapture()
        try await prior!.start()
        let priorQueue = prior!.testLifecycleQueue()
        let blocked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        priorQueue.async { blocked.signal(); release.wait() }
        check(blocked.wait(timeout: .now() + 1) == .success, "replacement case holds the old lifecycle queue")
        weak let priorReference = prior
        prior = nil
        check(priorReference == nil, "replacement case deallocates old capture before its cleanup runs")

        let replacement = MicCapture()
        try await replacement.start()
        check(AudioSessionUsers.current.contains(.mic), "replacement acquires its actual session claim")
        release.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            priorQueue.async { continuation.resume() }
        }
        check(AudioSessionUsers.current.contains(.mic), "old capture cleanup preserves the replacement session claim")
        replacement.stop()
        await settle { AudioSessionUsers.current.isEmpty }
        check(AudioSessionUsers.current.isEmpty, "replacement explicitly releases its session claim")

        print("Adversarial microphone result: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
