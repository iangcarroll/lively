#!/usr/bin/env python3
"""Check native ownership through production hybrid transitions and store tasks.

Recognition events, text responses, and playback are controlled. No microphone,
network, credentials, application hooks, or reconstructed store logic are used.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

from online_conversation_regression import (
    ROOT, load_store_fixture, render_store_fixture, shared_store_harness,
)


def replace(source, old, new, count=1):
    if source.count(old) != count:
        raise RuntimeError("Update native ownership mutation anchor: " + old)
    return source.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    _, methods, models, fixture = load_store_fixture()
    harness = shared_store_harness(fixture)
    harness, count = re.subn(r"final class HybridSpeechEngine: TestEngine \{.*?\n\}", "", harness, flags=re.S)
    if count != 1:
        raise RuntimeError("Expected exactly one controlled hybrid to replace")
    harness = harness.replace("HybridSpeechEngine()", "HybridSpeechEngine(local: TestEngine(), cloud: TestEngine())")
    hybrid = (ROOT / "Lively/Networking/HybridSpeechEngine.swift").read_text()
    variants = [("native-ownership", methods, True)]
    if args.negative_controls:
        guard = "guard !utterance.usesNativeTranslation || utterance.isTyped else { return }"
        retry = "        utterance.isTyped = true\n        utterance.translatedSource = nil\n        utterance.translatedLanguage = nil\n        translate(utterance)"
        for name, old, new, count in [
            ("native-owner-not-recorded", "utterance.usesNativeTranslation = true", "utterance.usesNativeTranslation = false", 1),
            ("implicit-native-text-request", guard, "", 1),
            ("explicit-native-retry-blocked", guard, "guard !utterance.usesNativeTranslation else { return }", 1),
            ("raw-spoken-fallback-blocked", guard, "guard utterance.isTyped else { return }", 1),
            ("live-retry-binding-detached", retry, retry.replace("        utterance.translatedSource", "        segmentUtterances = segmentUtterances.filter { $0.value !== utterance }\n        utterance.translatedSource"), 1),
            ("catch-up-retry-binding-detached", retry, retry.replace("        utterance.translatedSource", "        catchUpUtterances = catchUpUtterances.filter { $0.value !== utterance }\n        utterance.translatedSource"), 1),
            ("typed-native-update-accepted", "guard utterances.contains(where: { $0 === existing }), !existing.isTyped else { return }", "guard utterances.contains(where: { $0 === existing }) else { return }", 3),
            ("explicit-native-binding-pruned", "$0.key == last || $0.value.isTyped", "$0.key == last", 2),
        ]:
            variants.append((name, replace(methods, old, new, count), False))
    with tempfile.TemporaryDirectory(prefix="lively-native-ownership-") as directory:
        work = Path(directory)
        for name, actual, positive in variants:
            source = work / (name + ".swift")
            source.write_text(render_store_fixture(harness, methods=actual, models=models) + "\n" + hybrid)
            binary = work / name
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                            "-parse-as-library", "-module-cache-path", str(work / "modules"),
                            str(source), str(Path(__file__).with_name("NativeTranslationOwnershipRegression.swift")),
                            "-o", str(binary)], check=True, timeout=90)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            if positive:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stdout + result.stderr)
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name + "\n" + result.stdout + result.stderr)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
