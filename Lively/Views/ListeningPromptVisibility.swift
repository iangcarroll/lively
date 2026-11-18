import Foundation
import Observation
#if os(iOS)
import CoreMotion
#endif

/// One owner for both readers and every conversation layout.
@Observable
@MainActor
final class ListeningPromptVisibility {
    private(set) var isVisible = true
    @ObservationIgnored private var policy = ListeningPromptPolicy()
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    #if os(iOS)
    @ObservationIgnored private let motionManager = CMMotionManager()
    #endif

    func setActive(_ active: Bool) {
        guard active != policy.isActive else { return }
        generation += 1
        hideTask?.cancel()
        hideTask = nil
        policy.setActive(active, at: ProcessInfo.processInfo.systemUptime)
        #if os(iOS)
        motionManager.stopDeviceMotionUpdates()
        #endif
        updateVisibility()
        guard active else { return }
        #if os(iOS)
        guard motionManager.isDeviceMotionAvailable else { return }
        let token = generation
        motionManager.deviceMotionUpdateInterval = 0.1
        // An arbitrary reference frame measures handoffs without compass or
        // location data, including a turn around the phone's vertical axis.
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let quaternion = motion.attitude.quaternion
            let sample = ListeningPromptMotion(
                attitude: ListeningPromptAttitude(w: quaternion.w, x: quaternion.x, y: quaternion.y, z: quaternion.z),
                rotationRate: hypot(hypot(motion.rotationRate.x, motion.rotationRate.y), motion.rotationRate.z),
                userAcceleration: hypot(hypot(motion.userAcceleration.x, motion.userAcceleration.y), motion.userAcceleration.z)
            )
            let timestamp = motion.timestamp
            // The delivery queue is the main operation queue. A queued callback
            // from a previous listening session must not update its successor.
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.policy.isActive else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard timestamp <= now, now - timestamp < 0.5 else { return }
                if self.policy.receive(sample, at: now) { self.updateVisibility() }
            }
        }
        #endif
    }

    private func updateVisibility() {
        hideTask?.cancel()
        hideTask = nil
        let now = ProcessInfo.processInfo.systemUptime
        isVisible = policy.isVisible(at: now)
        guard policy.isActive, let deadline = policy.visibleUntil, deadline > now else { return }
        let token = generation
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(deadline - now)) }
            catch { return }
            guard let self, self.generation == token, self.policy.isActive,
                  self.policy.visibleUntil == deadline else { return }
            self.isVisible = self.policy.isVisible(at: ProcessInfo.processInfo.systemUptime)
            self.hideTask = nil
        }
    }

    isolated deinit {
        hideTask?.cancel()
        #if os(iOS)
        motionManager.stopDeviceMotionUpdates()
        #endif
    }
}
