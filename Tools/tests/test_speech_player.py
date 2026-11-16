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
                 "private func automaticFallback(for requested: Output) -> Bool {\n        output = requested",
                 "private func automaticFallback(for requested: Output) -> Bool {\n        output = .automatic",
                 "rejected private fallback scheduled PCM"),
                ("mixed-route-treated-as-private", "!ports.isEmpty && ports.allSatisfy {", "ports.contains {",
                 "ordinary private fallback accepted an empty, public, mixed, or unverified output"),
                ("fallback-bypasses-route-binding",
                 "if output == .automatic || (usesAutomaticFallback && output == .speaker) { return true }",
                 "if output == .automatic || usesAutomaticFallback { return true }",
                 "rejected private fallback scheduled PCM"),
                ("queued-private-pcm-not-muted", "mixer.outputVolume = 0", "// Deliberately omit immediate muting.",
                 "scheduled private audio was not muted before disconnect notification returned"),
                ("activation-route-not-rechecked",
                 "guard start() else { return }\n        // Activating an ordinary session can itself change the output. Check\n        // the binding again before scheduling against that new route.\n        guard routeIsPrepared else {\n            stop()\n            return\n        }",
                 "guard start() else { return }",
                 "session activation moved private fallback PCM onto a public route"),
            ]
            for name, old, new, expected in controls:
                if source.count(old) != 1:
                    raise RuntimeError("Update SpeechPlayer mutation anchor: " + name)
                changed = source.replace(old, new).replace("#if os(iOS)", "#if LIVELY_AUDIO_ROUTING_TEST")
                variants.append((name, changed, ["-D", "LIVELY_AUDIO_ROUTING_TEST"], expected))
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
