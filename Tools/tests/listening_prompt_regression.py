#!/usr/bin/env python3
"""Exercise actual listening-prompt policy with synthetic time and motion.

Fault controls mutate temporary copies of production source. Every control must
compile and fail a behavioral assertion; a compiler failure or crash is an error.
"""
import argparse
import hashlib
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TESTS = Path(__file__).parent


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError("Update listening-prompt mutation anchor: " + old)
    return source.replace(old, new)


def variants(source, controls):
    yield "production", source, True
    if not controls:
        return
    for name, old, new in [
        ("active-guidance-never-hides", "return time < visibleUntil", "return true"),
        ("inactive-guidance-expires", "guard isActive, let visibleUntil else { return true }",
         "guard isActive, let visibleUntil else { return false }"),
        ("portrait-yaw-ignored", "return 2 * acos(min(1, dot))",
         "return z == 0 && other.z == 0 ? 2 * acos(min(1, dot)) : 0"),
        ("small-jitter-reveals", "static let rotationThreshold = Double.pi / 3",
         "static let rotationThreshold = Double.pi / 180"),
        ("rapid-turn-ignored", "|| motion.rotationRate >= Self.rapidRotationThreshold", "|| false"),
        ("rapid-translation-ignored", "|| motion.userAcceleration >= Self.accelerationThreshold", "|| false"),
        ("quaternion-sign-counts-as-motion", "let dot = abs(w * other.w + x * other.x + y * other.y + z * other.z)",
         "let dot = w * other.w + x * other.x + y * other.y + z * other.z"),
        ("continuous-motion-repeats", "if coolingDown || needsSettling {", "if coolingDown {"),
        ("settling-interval-removed", "static let settlingDuration: TimeInterval = 0.6",
         "static let settlingDuration: TimeInterval = 0"),
        ("cooldown-removed", "let coolingDown = lastReveal.map { time - $0 < Self.cooldownDuration } ?? false",
         "let coolingDown = false"),
        ("active-state-guard-removed", "guard isActive, time.isFinite,", "guard time.isFinite,"),
        ("backward-samples-accepted", "lastSampleTime.map({ time >= $0 }) ?? true", "true"),
        ("session-baseline-retained", "self = Self()", "visibleUntil = nil"),
        ("unchanged-active-state-restarts", "guard time.isFinite, active != isActive else { return }",
         "guard time.isFinite else { return }"),
        ("invalid-motion-accepted", "motion.rotationRate.isFinite, motion.rotationRate >= 0,\n"
         "              motion.userAcceleration.isFinite, motion.userAcceleration >= 0,", "true,"),
    ]:
        yield name, replace_once(source, old, new), False
    stationary = replace_once(source,
        "            self.reference = attitude\n            if motion.rotationRate",
        "            if motion.rotationRate")
    stationary = replace_once(stationary,
        "        self.reference = attitude\n        lastReveal = time",
        "        lastReveal = time")
    yield "held-rotation-repeatedly-reveals", stationary, False


def declaration(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def lifecycle_source(controller, screen):
    # Keep the full actual controller, including iOS sample conversion and all
    # cancellation/generation guards. Substitute only SDK/clock/task boundaries.
    controller = controller.replace("#if os(iOS)", "").replace("#endif", "").replace("import CoreMotion", "")
    controller = controller.replace("ProcessInfo.processInfo.systemUptime", "PromptTestClock.now")
    controller = replace_once(controller, "Task<Void, Never>", "PromptTestTask")
    controller = replace_once(controller, "hideTask = Task {", "hideTask = PromptTestTask {")
    controller = replace_once(controller, "Task.sleep(for:", "PromptTestSleep.sleep(for:")
    gates = "\n".join(declaration(screen, "private var " + name + ": Bool").replace("private var ", "var ", 1)
                      for name in ["listeningPromptIsActive", "showsListeningPrompt"])
    activity = declaration(screen, ".onChange(of: listeningPromptIsActive, initial: true)")
    activity = activity[activity.index("{ _, active in") + len("{ _, active in"): -1]
    disappear = declaration(screen, ".onDisappear")
    disappear = disappear[disappear.index("{") + 1: -1]
    fixture = (TESTS / "ListeningPromptLifecycleRegression.swift").read_text()
    return (fixture.replace("// INSERT_VISIBILITY_CONTROLLER", controller)
            .replace("// INSERT_SCREEN_GATES", gates)
            .replace("// INSERT_SCREEN_ACTIVITY", "func activityChanged(_ active: Bool) {" + activity + "}")
            .replace("// INSERT_SCREEN_DISAPPEAR", "func screenDisappeared() {" + disappear + "}"))


def lifecycle_variants(controller, screen, controls):
    yield "lifecycle-production", lifecycle_source(controller, screen), True
    if not controls:
        return
    for name, old, new in [
        ("duplicate-sensor-owner", "        guard active != policy.isActive else { return }", ""),
        ("deactivation-keeps-sensors-running", "        motionManager.stopDeviceMotionUpdates()\n        #endif\n        updateVisibility()",
         "        #endif\n        updateVisibility()"),
        ("previous-session-motion-accepted", "guard let self, self.generation == token, self.policy.isActive else { return }",
         "guard let self, self.policy.isActive else { return }"),
        ("delayed-motion-accepted", "guard timestamp <= now, now - timestamp < 0.5 else { return }", ""),
        ("timer-fails-to-hide", "self.isVisible = self.policy.isVisible(at: ProcessInfo.processInfo.systemUptime)",
         "self.isVisible = true"),
        ("timer-waits-zero-seconds", ".seconds(deadline - now)", ".zero"),
        ("old-deadline-takes-ownership", "self.policy.visibleUntil == deadline else { return }", "true else { return }"),
        ("timer-cancellation-removed", "        hideTask?.cancel()\n        hideTask = nil\n        policy.setActive",
         "        hideTask = nil\n        policy.setActive"),
        ("sensor-acceleration-axis-lost", "hypot(hypot(motion.userAcceleration.x, motion.userAcceleration.y), motion.userAcceleration.z)",
         "hypot(motion.userAcceleration.x, motion.userAcceleration.y)"),
        ("sensor-rotation-axis-lost", "hypot(hypot(motion.rotationRate.x, motion.rotationRate.y), motion.rotationRate.z)",
         "hypot(motion.rotationRate.x, motion.rotationRate.y)"),
        ("obsolete-timer-takes-ownership", "guard let self, self.generation == token, self.policy.isActive,\n"
         "                  self.policy.visibleUntil == deadline else { return }", "guard let self else { return }"),
        ("owner-release-keeps-sensors", "deinit {\n        hideTask?.cancel()\n        #if os(iOS)\n        motionManager.stopDeviceMotionUpdates()",
         "deinit {\n        hideTask?.cancel()\n        #if os(iOS)"),
    ]:
        yield name, lifecycle_source(replace_once(controller, old, new), screen), False
    for name, old, new in [
        ("background-keeps-sensors-running", "scenePhase == .active && ", ""),
        ("stopped-screen-keeps-sensors-running", "&& store.isListening &&", "&&"),
        ("nonlive-screen-keeps-sensors-running", "&& store.status == .live", ""),
        ("nonlive-guidance-hidden", "store.status != .live || ", ""),
        ("covering-sheet-keeps-sensors-running", "&& !showSettings && !showOnboarding && !showAddress && !showLanguages && !hitFreeLimit", ""),
        ("voiceover-guidance-hidden", "|| voiceOverEnabled", ""),
        ("disappearance-does-not-stop", ".onDisappear { listeningPrompt.setActive(false) }", ".onDisappear { }"),
    ]:
        yield name, lifecycle_source(controller, replace_once(screen, old, new)), False


def run_variant(work, name, source, production, fixtures):
    swift = work / (name + ".swift")
    swift.write_text(source)
    binary = work / name
    result = subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
        "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        "-enable-upcoming-feature", "InferIsolatedConformances",
        "-enable-upcoming-feature", "MemberImportVisibility", "-module-cache-path", str(work / "modules"),
        str(swift), *map(str, fixtures), "-o", str(binary),
    ], cwd=ROOT, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"{name} must compile:\n{result.stdout}{result.stderr}")
    result = subprocess.run([str(binary)], cwd=ROOT, capture_output=True, text=True, timeout=10)
    if production:
        print(result.stdout, end="", flush=True)
        if result.returncode or "PASS:" not in result.stdout:
            raise RuntimeError(result.stderr or "Listening prompt regression failed")
    elif result.returncode != 1 or "FAIL:" not in result.stdout:
        raise RuntimeError(f"{name} must fail an assertion, not crash:\n{result.stdout}{result.stderr}")
    else:
        print("PASS: " + name + " detected deliberate corruption", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    paths = [ROOT / p for p in ["Lively/Model/ListeningPromptPolicy.swift",
                               "Lively/Views/ListeningPromptVisibility.swift", "Lively/Views/ConversationScreen.swift"]]
    original, controller, screen = [p.read_bytes() for p in paths]
    digests = [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths]
    with tempfile.TemporaryDirectory(prefix="lively-listening-prompt-") as directory:
        work = Path(directory)
        control_count = 0
        # Compile the unchanged helpers against the actual iOS SDK as well as
        # our controlled boundaries, so SDK actor-isolation errors cannot hide
        # behind the fake sensor manager.
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
        architecture = "arm64" if platform.machine() == "arm64" else "x86_64"
        subprocess.run([
            "xcrun", "swiftc", "-typecheck", "-swift-version", "6", "-parse-as-library",
            "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
            "-enable-upcoming-feature", "InferIsolatedConformances",
            "-enable-upcoming-feature", "MemberImportVisibility", "-sdk", sdk,
            "-target", f"{architecture}-apple-ios26.0-simulator", "-module-cache-path", str(work / "modules-ios"),
            str(paths[0]), str(paths[1]),
        ], cwd=ROOT, check=True, timeout=90)
        print("PASS: actual helpers typecheck against iOS SDK with app concurrency flags", flush=True)
        for name, source, production in variants(original.decode(), args.negative_controls):
            run_variant(work, name, source, production, [TESTS / "ListeningPromptRegression.swift"])
            control_count += not production
        policy = work / "ActualListeningPromptPolicy.swift"
        policy.write_bytes(original)
        for name, source, production in lifecycle_variants(controller.decode(), screen.decode(), args.negative_controls):
            run_variant(work, name, source, production, [policy])
            control_count += not production
    if [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths] != digests:
        raise RuntimeError("Production source changed during the test; re-run against the current snapshot")
    print("PASS: production listening prompt source remained unchanged", flush=True)
    print(f"PASS: {control_count} compiling, assertion-based fault controls detected", flush=True)


if __name__ == "__main__":
    main()
