import Foundation

/// Relative orientation, independent of the phone's portrait/landscape layout.
nonisolated struct ListeningPromptAttitude: Sendable {
    let w: Double
    let x: Double
    let y: Double
    let z: Double

    fileprivate var normalized: Self? {
        let length = hypot(hypot(w, x), hypot(y, z))
        guard length.isFinite, length > 0 else { return nil }
        return Self(w: w / length, x: x / length, y: y / length, z: z / length)
    }

    fileprivate func angle(to other: Self) -> Double {
        // q and -q describe the same attitude. The absolute dot product also
        // avoids a spurious full turn when Core Motion changes quaternion sign.
        let dot = abs(w * other.w + x * other.x + y * other.y + z * other.z)
        return 2 * acos(min(1, dot))
    }
}

nonisolated struct ListeningPromptMotion: Sendable {
    let attitude: ListeningPromptAttitude
    /// Magnitude in radians per second.
    let rotationRate: Double
    /// Magnitude in g, excluding gravity.
    let userAcceleration: Double
}

/// A short reminder after listening starts or the phone is handed to someone.
/// Uses monotonic time so clock changes cannot extend or suppress the reminder.
nonisolated struct ListeningPromptPolicy: Sendable {
    static let displayDuration: TimeInterval = 5
    static let cooldownDuration: TimeInterval = 2
    static let settlingDuration: TimeInterval = 0.6
    static let rotationThreshold = Double.pi / 3
    static let rapidRotationThreshold = 2.5
    static let accelerationThreshold = 0.55
    static let quietRotationThreshold = 0.7
    static let quietAccelerationThreshold = 0.18

    private(set) var isActive = false
    private(set) var visibleUntil: TimeInterval?
    private var reference: ListeningPromptAttitude?
    private var lastReveal: TimeInterval?
    private var lastSampleTime: TimeInterval?
    private var settledSince: TimeInterval?
    private var needsSettling = false

    mutating func setActive(_ active: Bool, at time: TimeInterval) {
        guard time.isFinite, active != isActive else { return }
        self = Self()
        isActive = active
        if active {
            visibleUntil = time + Self.displayDuration
            lastReveal = time
            lastSampleTime = time
        }
    }

    func isVisible(at time: TimeInterval) -> Bool {
        guard isActive, let visibleUntil else { return true }
        return time < visibleUntil
    }

    /// Returns true only when a fresh movement reveals or extends the reminder.
    mutating func receive(_ motion: ListeningPromptMotion, at time: TimeInterval) -> Bool {
        guard isActive, time.isFinite,
              motion.rotationRate.isFinite, motion.rotationRate >= 0,
              motion.userAcceleration.isFinite, motion.userAcceleration >= 0,
              let attitude = motion.attitude.normalized,
              lastSampleTime.map({ time >= $0 }) ?? true else { return false }
        lastSampleTime = time
        guard let reference else {
            self.reference = attitude
            return false
        }

        let coolingDown = lastReveal.map { time - $0 < Self.cooldownDuration } ?? false
        if coolingDown || needsSettling {
            // Follow the phone while it is moving, then start measuring from its
            // new resting position. Holding it turned must not retrigger forever.
            self.reference = attitude
            if motion.rotationRate < Self.quietRotationThreshold,
               motion.userAcceleration < Self.quietAccelerationThreshold {
                if settledSince == nil { settledSince = time }
                if !coolingDown, let settledSince, time - settledSince >= Self.settlingDuration {
                    needsSettling = false
                }
            } else {
                settledSince = nil
            }
            return false
        }

        guard reference.angle(to: attitude) >= Self.rotationThreshold
                || motion.rotationRate >= Self.rapidRotationThreshold
                || motion.userAcceleration >= Self.accelerationThreshold else { return false }
        self.reference = attitude
        lastReveal = time
        visibleUntil = time + Self.displayDuration
        settledSince = nil
        needsSettling = true
        return true
    }
}
