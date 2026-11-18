// Exercises the production policy with synthetic monotonic time and motion.
// No microphone, device sensor, app arguments, or network access is required.
import Foundation

@main
struct ListeningPromptRegression {
    static var assertions = 0
    static var failures = 0

    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func attitude(_ degrees: Double, axis: Int = 2) -> ListeningPromptAttitude {
        let half = degrees * .pi / 360
        let sine = sin(half)
        return ListeningPromptAttitude(w: cos(half), x: axis == 0 ? sine : 0,
                                       y: axis == 1 ? sine : 0, z: axis == 2 ? sine : 0)
    }

    static func motion(_ degrees: Double = 0, axis: Int = 2,
                       rate: Double = 0, acceleration: Double = 0) -> ListeningPromptMotion {
        ListeningPromptMotion(attitude: attitude(degrees, axis: axis),
                              rotationRate: rate, userAcceleration: acceleration)
    }

    static func visibleWindow() {
        var policy = ListeningPromptPolicy()
        check(policy.isVisible(at: 100), "stopped guidance remains visible")
        policy.setActive(true, at: 100)
        check(policy.isVisible(at: 100), "starting listening immediately shows guidance")
        check(policy.isVisible(at: 104.999), "guidance remains readable for five seconds")
        check(!policy.isVisible(at: 105), "active guidance expires at its deadline")
        check(!policy.isVisible(at: 1_000), "guidance stays hidden without a handoff")
        policy.setActive(true, at: 1_000)
        check(!policy.isVisible(at: 1_000), "an unchanged active state cannot restart its timer")
        policy.setActive(false, at: 1_001)
        check(policy.isVisible(at: 50_000), "inactive guidance never expires")
        policy.setActive(true, at: 1_002)
        check(policy.isVisible(at: 1_002), "a genuinely new listening session shows guidance")
        check(!policy.isVisible(at: 1_007), "new session guidance also expires")
    }

    static func rotationHandoffs() {
        for axis in 0...2 {
            var policy = ListeningPromptPolicy()
            policy.setActive(true, at: 0)
            check(!policy.receive(motion(0, axis: axis), at: 0), "first attitude is a baseline, axis \(axis)")
            check(!policy.receive(motion(30, axis: axis), at: 6), "small attitude change is ignored, axis \(axis)")
            check(policy.receive(motion(180, axis: axis), at: 6.1), "a half turn reveals guidance, axis \(axis)")
            check(policy.isVisible(at: 6.1), "half-turn cue appears promptly, axis \(axis)")
            check(!policy.isVisible(at: 11.1), "half-turn cue expires, axis \(axis)")
        }
        var gradual = ListeningPromptPolicy()
        gradual.setActive(true, at: 0)
        _ = gradual.receive(motion(), at: 0)
        for (index, degrees) in [10.0, 20, 30, 40, 50].enumerated() {
            check(!gradual.receive(motion(degrees), at: 6 + Double(index) * 0.1),
                  "small cumulative turn below threshold does not reveal: \(degrees)")
        }
        check(gradual.receive(motion(70), at: 6.6), "a gradual substantial turn is measured from its baseline")
        // A yaw turn can hand the phone to someone else while remaining portrait.
        // Quaternion angular distance must also treat q and -q as one attitude.
        var sign = ListeningPromptPolicy()
        sign.setActive(true, at: 0)
        _ = sign.receive(motion(), at: 0)
        check(!sign.receive(ListeningPromptMotion(attitude: ListeningPromptAttitude(w: -1, x: 0, y: 0, z: 0),
                                                 rotationRate: 0, userAcceleration: 0), at: 6),
              "equivalent quaternion sign is not a handoff")
        check(sign.receive(motion(180), at: 6.1), "portrait-to-portrait yaw turn is detected")
    }

    static func motionThresholds() {
        var gentle = ListeningPromptPolicy()
        gentle.setActive(true, at: 0)
        _ = gentle.receive(motion(), at: 0)
        for index in 1...400 {
            let t = Double(index) * 0.05
            let degrees = sin(t * 7) * 4
            check(!gentle.receive(motion(degrees, rate: 0.15, acceleration: 0.04), at: t),
                  "ordinary hand jitter does not reveal at sample \(index)")
        }
        check(!gentle.isVisible(at: 20), "jitter cannot keep active instructions visible")

        var translation = ListeningPromptPolicy()
        translation.setActive(true, at: 0)
        _ = translation.receive(motion(), at: 0)
        check(!translation.receive(motion(acceleration: 0.4), at: 6), "modest acceleration is ignored")
        check(translation.receive(motion(acceleration: 0.8), at: 6.1), "an abrupt translation reveals without attitude change")

        var fastTurn = ListeningPromptPolicy()
        fastTurn.setActive(true, at: 0)
        _ = fastTurn.receive(motion(), at: 0)
        check(!fastTurn.receive(motion(3, rate: 1), at: 6), "ordinary angular velocity is ignored")
        check(fastTurn.receive(motion(5, rate: 3), at: 6.1), "rapid turning reveals before a large angle accumulates")
    }

    static func settleAndRepeat() {
        var held = ListeningPromptPolicy()
        held.setActive(true, at: 0)
        _ = held.receive(motion(), at: 0)
        check(held.receive(motion(180), at: 6), "first handoff reveals")
        for index in 1...160 {
            check(!held.receive(motion(180), at: 6 + Double(index) * 0.05),
                  "holding the turned phone cannot renew its cue at sample \(index)")
        }
        check(!held.isVisible(at: 14), "held rotation fades after the handoff")
        check(held.receive(motion(), at: 14.1), "a separate return handoff reveals after settling")
        check(held.isVisible(at: 14.1), "return handoff has a new visible window")

        var impulse = ListeningPromptPolicy()
        impulse.setActive(true, at: 0)
        _ = impulse.receive(motion(), at: 0)
        check(impulse.receive(motion(acceleration: 1), at: 6), "first rapid movement reveals")
        for index in 1...80 {
            check(!impulse.receive(motion(acceleration: 1), at: 6 + Double(index) * 0.1),
                  "ongoing abrupt motion cannot repeatedly reveal at sample \(index)")
        }
        check(!impulse.isVisible(at: 14), "ongoing motion cannot hold the cue indefinitely")
        check(!impulse.receive(motion(), at: 14.1), "quiet begins a settling interval")
        check(!impulse.receive(motion(), at: 14.5), "a short quiet pause is not a new handoff")
        check(!impulse.receive(motion(acceleration: 0.9), at: 14.6), "a too-short quiet pause does not rearm a continuing movement")
        check(!impulse.receive(motion(), at: 14.8), "another quiet interval establishes its own baseline")
        check(!impulse.receive(motion(), at: 15.5), "a settled baseline does not reveal itself")
        check(impulse.receive(motion(acceleration: 0.9), at: 15.6), "a distinct movement after settling reveals again")

        var cooldown = ListeningPromptPolicy()
        cooldown.setActive(true, at: 0)
        _ = cooldown.receive(motion(), at: 0)
        check(cooldown.receive(motion(180), at: 6), "cooldown starts after a handoff")
        _ = cooldown.receive(motion(180), at: 6.1)
        _ = cooldown.receive(motion(180), at: 6.8)
        check(!cooldown.receive(motion(), at: 7), "a quick bounce during cooldown is ignored")
        _ = cooldown.receive(motion(), at: 7.1)
        _ = cooldown.receive(motion(), at: 8.1)
        check(cooldown.receive(motion(180), at: 8.2), "cooldown eventually permits another deliberate handoff")
    }

    static func lifecycleAndBadInput() {
        var stopped = ListeningPromptPolicy()
        stopped.setActive(true, at: 0)
        _ = stopped.receive(motion(), at: 0)
        stopped.setActive(false, at: 6)
        check(stopped.isVisible(at: 100), "stopped or unavailable guidance stays visible after old deadline")
        check(!stopped.receive(motion(180, acceleration: 1), at: 7), "motion after leaving active listening is ignored")
        check(!stopped.receive(motion(0, acceleration: 1), at: 7.1), "repeated stale sensor callbacks stay inert")
        stopped.setActive(true, at: 8)
        check(!stopped.receive(motion(180), at: 8), "resuming establishes a fresh attitude baseline")
        check(!stopped.isVisible(at: 13), "stopped time cannot extend the next listening cue")
        check(stopped.receive(motion(), at: 14), "fresh session still detects a new handoff")

        var delayedSensor = ListeningPromptPolicy()
        delayedSensor.setActive(true, at: 0)
        _ = delayedSensor.receive(motion(), at: 0)
        delayedSensor.setActive(false, at: 6)
        delayedSensor.setActive(true, at: 8)
        check(!delayedSensor.receive(motion(180), at: 14),
              "delayed first sample after resuming cannot reuse a prior session baseline")
        check(!delayedSensor.isVisible(at: 14), "delayed first sensor sample does not restart an expired cue")

        var invalid = ListeningPromptPolicy()
        invalid.setActive(true, at: 10)
        _ = invalid.receive(motion(), at: 10)
        check(!invalid.receive(motion(180, acceleration: 1), at: 9), "out-of-order sensor time is rejected")
        check(!invalid.receive(motion(180, acceleration: 1), at: .nan), "non-finite sensor time is rejected")
        check(!invalid.receive(motion(180, acceleration: 1), at: .infinity), "infinite sensor time is rejected")
        check(!invalid.isVisible(at: 16), "invalid timestamps cannot extend a visible window")
        check(invalid.receive(motion(180), at: 16.1), "invalid samples do not corrupt the valid motion baseline")

        let malformed: [ListeningPromptMotion] = [
            motion(rate: -.infinity), motion(rate: .nan), motion(rate: -1),
            motion(acceleration: .infinity), motion(acceleration: .nan), motion(acceleration: -1),
            ListeningPromptMotion(attitude: ListeningPromptAttitude(w: 0, x: 0, y: 0, z: 0), rotationRate: 3, userAcceleration: 1),
            ListeningPromptMotion(attitude: ListeningPromptAttitude(w: .nan, x: 0, y: 0, z: 0), rotationRate: 3, userAcceleration: 1),
        ]
        for (index, sample) in malformed.enumerated() {
            var policy = ListeningPromptPolicy()
            policy.setActive(true, at: 0)
            _ = policy.receive(motion(), at: 0)
            check(!policy.receive(sample, at: 6), "malformed motion is rejected: \(index)")
            check(!policy.isVisible(at: 6), "malformed motion cannot show guidance: \(index)")
            check(policy.receive(motion(180), at: 6.1), "valid motion still works after malformed sample: \(index)")
        }

        var scaled = ListeningPromptPolicy()
        scaled.setActive(true, at: 0)
        _ = scaled.receive(motion(), at: 0)
        let half = ListeningPromptAttitude(w: 0, x: 0, y: 0, z: 2)
        check(scaled.receive(ListeningPromptMotion(attitude: half, rotationRate: 0, userAcceleration: 0), at: 6),
              "sensor quaternion scale is normalized before angle comparison")
    }

    static func main() {
        visibleWindow()
        rotationHandoffs()
        motionThresholds()
        settleAndRepeat()
        lifecycleAndBadInput()
        print("\(failures == 0 ? "PASS" : "FAIL"): \(assertions) listening prompt policy assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
