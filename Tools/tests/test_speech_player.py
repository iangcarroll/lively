#!/usr/bin/env python3
"""Run with: python3 Tools/tests/test_speech_player.py (macOS with Xcode).

Compiles the current SpeechPlayer.swift with deterministic audio mocks; no
device, credentials, network, or Xcode project changes are needed. The audio
imports are replaced by API-shaped mocks. A second build enables the current
iOS code through a test compile condition, so the production routing, failure
handling, and lifecycle behavior run on the host without a copied implementation.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile


def production_retry(root):
    source = (root / "Lively/Audio/MicCapture.swift").read_text()
    start = source.index("    static func retryWithoutDirectionalSpeech(")
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    parser.add_argument("--thread-sanitizer", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = (root / "Lively/Audio/SpeechPlayer.swift").read_text()
    audio_import = "@preconcurrency import AVFoundation"
    if source.count(audio_import) != 1:
        raise RuntimeError("Update the test runner for SpeechPlayer's audio import")
    source = source.replace(audio_import, "")
    source = source.replace("import AudioToolbox", "")
    fixture = Path(__file__).with_name("SpeechPlayerRegression.swift").read_text()
    retry_marker = "    // INSERT_ACTUAL_DIRECTIONAL_RETRY"
    if fixture.count(retry_marker) != 1:
        raise RuntimeError("Expected one actual directional-retry marker")
    fixture = fixture.replace(retry_marker, production_retry(root))
    marker = "// INSERT_ACTUAL_SPEECH_PLAYER_SOURCE"
    if fixture.count(marker) != 1:
        raise RuntimeError("Expected one production-source marker in the test fixture")
    with tempfile.TemporaryDirectory(prefix="lively-speech-regression-") as directory:
        work = Path(directory)
        combined = work / "Regression.swift"
        variants = [("macos", source, [], None),
                    ("ios-routing", source.replace("#if os(iOS)", "#if LIVELY_AUDIO_ROUTING_TEST"),
                     ["-D", "LIVELY_AUDIO_ROUTING_TEST"], None)]
        if args.negative_controls:
            controls = [
                ("private-fallback-forgets-intent",
                 "private func bindOrdinaryOutput(for requested: Output) -> Bool {\n        output = requested",
                 "private func bindOrdinaryOutput(for requested: Output) -> Bool {\n        output = .automatic",
                 "rejected private fallback scheduled PCM"),
                ("mixed-route-treated-as-private", "!ports.isEmpty && ports.allSatisfy {", "ports.contains {",
                 "ordinary private fallback accepted an empty, public, mixed, or unverified output"),
                ("fallback-bypasses-route-binding",
                 "if output == .automatic { return true }",
                 "if output == .automatic || usesAutomaticFallback { return true }",
                 "rejected private fallback scheduled PCM"),
                ("queued-private-pcm-not-muted", "mixer.outputVolume = 0", "// Deliberately omit immediate muting.",
                 "scheduled private audio was not muted before disconnect notification returned"),
                ("activation-route-not-rechecked",
                 "guard start() else { return }\n        // Activating an ordinary session can itself change the output. Check\n        // the binding again before scheduling against that new route.\n        guard routeIsPrepared else {\n            stop()\n            return\n        }",
                 "guard start() else { return }",
                 "session activation moved private fallback PCM onto a public route"),
                ("ordinary-failure-disables-capability",
                 "guard AudioSessionUsers.retryWithoutDirectionalSpeech({ try activateSession() }) else { throw error }",
                 "guard AudioSessionUsers.retryWithoutDirectionalSpeech({ try activateSession() }) else { AudioSessionUsers.markDirectionalSpeechUnavailable(); throw error }",
                 "transient ordinary activation failure permanently disabled directional playback or leaked ownership"),
                ("ordinary-readiness-skips-activation",
                 "do { try activateSession() }\n        catch { releaseHeldSession(); throw error }",
                 "// Deliberately claim the ordinary route without activation.",
                 "ordinary preview latched directional capability off or skipped activation"),
                ("expired-fallback-skips-activation", "holdsSession && usesAutomaticFallback != wantsDirectional",
                 "usesAutomaticFallback != wantsDirectional",
                 "expired fallback skipped activation and claimed readiness after a new activation failure"),
                ("concurrent-mic-fallback-skips-activation",
                 "if !AudioSessionUsers.directionalSpeechEnabled || !Self.supportsDirectionalOutput {\n"
                 "                return try prepareOrdinaryOutput(for: requested)\n            }\n            #if os(iOS)",
                 "if !AudioSessionUsers.directionalSpeechEnabled || !Self.supportsDirectionalOutput {\n"
                 "                return bindOrdinaryOutput(for: requested)\n            }\n            #if os(iOS)",
                 "concurrent mic fallback bound speech before ordinary session activation"),
            ]
            for name, old, new, expected in controls:
                if source.count(old) != 1:
                    raise RuntimeError("Update SpeechPlayer mutation anchor: " + name)
                changed = source.replace(old, new).replace("#if os(iOS)", "#if LIVELY_AUDIO_ROUTING_TEST")
                variants.append((name, changed, ["-D", "LIVELY_AUDIO_ROUTING_TEST"], expected))
            # Coherently ignore the user's ordinary preview policy at both
            # the initial decision and the post-activation validation.
            changed = source.replace("AudioSessionUsers.directionalSpeechEnabled", "true")
            if changed == source:
                raise RuntimeError("Update ordinary-preview policy mutation")
            variants.append(("ordinary-preview-treated-as-routing-failure",
                             changed.replace("#if os(iOS)", "#if LIVELY_AUDIO_ROUTING_TEST"),
                             ["-D", "LIVELY_AUDIO_ROUTING_TEST"],
                             "ordinary private preview failed while directional speech was intentionally disabled"))
        for variant, build_source, flags, expected_failure in variants:
            if args.thread_sanitizer:
                flags = [*flags, "-sanitize=thread"]
            combined.write_text(fixture.replace(marker, build_source))
            executable = work / variant
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-module-cache-path", str(work / "modules"), "-parse-as-library", *flags,
                str(combined), "-o", str(executable),
            ], check=True, timeout=60)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
            if "WARNING: ThreadSanitizer" in result.stderr:
                raise RuntimeError(variant + "\n" + result.stderr)
            if expected_failure:
                if result.returncode == 0 or expected_failure not in result.stderr:
                    raise RuntimeError("SpeechPlayer fault control did not fail its intended assertion: "
                                       + variant + "\n" + result.stdout + result.stderr)
                print("PASS: " + variant + " detected deliberate corruption", flush=True)
            else:
                print(result.stdout, end="", flush=True)
                if result.returncode:
                    raise RuntimeError(variant + "\n" + result.stderr)
                if "ThreadSanitizer" in result.stderr:
                    raise RuntimeError(variant + "\n" + result.stderr)


if __name__ == "__main__":
    main()
