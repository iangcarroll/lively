// Independent burst-route scenarios for directional_speech_adversarial.py.
// Main is deliberately occupied while notifications run on another thread:
// a headset can disconnect and return before actor-bound cleanup gets time.
@main struct DirectionalSpeechAdversarial {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("PASS: \(message)")
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func route(reversed: Bool = false, headphones: Bool = true) -> AVAudioSessionRouteDescription {
        let speaker = AVAudioSessionPortDescription(uid: "speaker", type: .builtInSpeaker, channels: 2)
        let headset = AVAudioSessionPortDescription(uid: "headset", type: .bluetoothHFP, channels: 1)
        return AVAudioSessionRouteDescription(outputs:
            headphones ? (reversed ? [headset, speaker] : [speaker, headset]) : [speaker])
    }

    static func drainActor() async {
        for _ in 0..<100 { await Task.yield() }
    }

    // The semaphore keeps the notification callback honest: it cannot wait
    // for the main actor, and its immediate mute is checked before yielding.
    static func notifyOffMain(_ routes: [AVAudioSessionRouteDescription]) {
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for route in routes {
                AVAudioSession.sharedInstance().currentRoute = route
                NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
                                                object: AVAudioSession.sharedInstance())
            }
            returned.signal()
        }
        check(returned.wait(timeout: .now() + 1) == .success,
              "route notification burst returns while main actor is occupied")
    }

    static func unchangedRouteControl() async throws {
        AVAudioSession.sharedInstance().currentRoute = route()
        let player = SpeechPlayer()
        let ready = try await player.prepare(output: .headphones)
        check(ready, "control private preparation succeeds")
        player.play(Data([1, 0]))
        let node = AVAudioPlayerNode.last!
        let mixer = AVAudioEngine.last!.mainMixerNode
        notifyOffMain([route()])
        await drainActor()
        check(node.buffers.count == 1 && mixer.outputVolume == 1,
              "unchanged topology notification preserves audible private playback")
        player.stop()
    }

    static func burst(temporaryRoute: AVAudioSessionRouteDescription, label: String) async throws {
        AVAudioSession.sharedInstance().currentRoute = route()
        let player = SpeechPlayer()
        let ready = try await player.prepare(output: .headphones)
        check(ready, "\(label): initial preparation succeeds")
        player.play(Data([1, 0]))
        let node = AVAudioPlayerNode.last!
        let mixer = AVAudioEngine.last!.mainMixerNode

        notifyOffMain([temporaryRoute, route()])
        check(mixer.outputVolume == 0, "\(label): burst immediately mutes old private audio")
        await drainActor()
        check(node.buffers.isEmpty, "\(label): burst discards old scheduled private audio")

        // Reconnection must allow a fresh sentence, while the old sentence
        // stays dropped. Simply unmuting old buffers would violate privacy.
        let reconnected = try await player.prepare(output: .headphones)
        check(reconnected, "\(label): new preparation succeeds")
        player.play(Data([2, 0]))
        check(mixer.outputVolume == 1, "\(label): fresh preparation restores audible playback")
        check(node.buffers == [[Float(2) / 32768]], "\(label): only the fresh sentence is scheduled")
        player.stop()
    }

    static func resumeBeforeCleanup() async throws {
        AVAudioSession.sharedInstance().currentRoute = route()
        let player = SpeechPlayer()
        let initial = try await player.prepare(output: .headphones)
        check(initial, "early recovery: initial preparation succeeds")
        player.play(Data([1, 0]))
        let node = AVAudioPlayerNode.last!
        let mixer = AVAudioEngine.last!.mainMixerNode

        notifyOffMain([route(headphones: false), route()])
        // This is still the same main-actor turn: its pending route cleanup
        // has not run, even though the hardware is back to the initial route.
        player.play(Data([99, 0]))
        check(node.buffers.isEmpty,
              "early recovery: incoming chunk cannot revive an invalidated route")
        let recovered = try await player.prepare(output: .headphones)
        check(recovered, "early recovery: fresh preparation succeeds")
        player.play(Data([2, 0]))
        await drainActor()
        check(mixer.outputVolume == 1 && node.buffers == [[Float(2) / 32768]],
              "early recovery: delayed old cleanup preserves freshly prepared speech")
        player.stop()
    }

    static func main() async throws {
        try await unchangedRouteControl()
        try await burst(temporaryRoute: route(headphones: false), label: "disconnect/reconnect")
        try await burst(temporaryRoute: route(reversed: true), label: "channel reorder/restore")
        try await resumeBeforeCleanup()
        check(AudioSessionUsers.users.isEmpty, "all players release their session claims")
        print("Adversarial route result: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
