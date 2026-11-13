#!/usr/bin/env python3
"""Exercise offline speech with deterministic rendering and native conversion.

No system voice synthesis, network requests, microphone, preferences, or audio
playback is used. Production OfflineSpeaker.swift is compiled unchanged.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread-sanitizer", action="store_true")
    parser.add_argument("--negative-controls", action="store_true",
                        help="verify deliberately broken temporary source fails")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="lively-offline-speaker-") as directory:
        work = Path(directory)
        flags = ["-sanitize=thread"] if args.thread_sanitizer else []
        source = root / "Lively/Networking/OfflineSpeaker.swift"
        fixture = root / "Tools/tests/OfflineSpeakerRegression.swift"

        def compile_and_run(name, path, negative=False):
            binary = work / name
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-parse-as-library", "-module-cache-path", str(work / "modules"), *flags,
                str(path), str(fixture), "-o", str(binary),
            ], check=True)
            result = subprocess.run([str(binary)], timeout=30, capture_output=negative, text=negative)
            if negative:
                if result.returncode == 0 or "FAIL:" not in result.stderr:
                    raise RuntimeError(f"{name}: tests did not detect deliberate corruption")
                print(f"PASS: {name} detected deliberate corruption")
            else:
                result.check_returncode()

        compile_and_run("regression", source)
        if args.negative_controls:
            actual = source.read_text()
            mutations = {
                "missing-headphones": (
                    "guard try await player.prepare(output: line.output) else { continue }",
                    "_ = try await player.prepare(output: line.output)"),
                "stale-generation": (
                    "        generation += 1\n        queue.removeAll()\n        worker?.cancel()",
                    "        queue.removeAll()"),
                "wrong-sample-rate": (
                    "sampleRate: 24_000,",
                    "sampleRate: 16_000,"),
                "legacy-voice-order": (
                    "            if first.isModern != second.isModern { return first.isModern }",
                    "            // Deliberate regression: identifier sorting chooses legacy voices."),
            }
            for name, (before, after) in mutations.items():
                if actual.count(before) != 1:
                    raise RuntimeError(f"{name}: expected one mutation site")
                mutated = work / f"{name}.swift"
                mutated.write_text(actual.replace(before, after))
                compile_and_run(name, mutated, negative=True)


if __name__ == "__main__":
    main()
