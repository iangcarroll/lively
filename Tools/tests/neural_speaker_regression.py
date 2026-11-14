#!/usr/bin/env python3
"""Run the production neural speech queue with controlled model and route APIs."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread-sanitizer", action="store_true")
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    actual = (root / "Lively/Networking/NeuralSpeaker.swift").read_text().replace("import NeuralVoices", "")
    fixture = Path(__file__).with_name("NeuralSpeakerRegression.swift").read_text()
    variants = [("neural-speaker", actual, True)]
    if args.negative_controls:
        for name, old, new in [
            ("private-route-fallback", "if line.isPreview {\n                        if !SpeechPlayer.supportsDirectionalOutput", "if true {\n                        if !SpeechPlayer.supportsDirectionalOutput"),
            ("pcm-clamping", "if sample <= -1 { value = .min }", "if sample <= -1 { value = 0 }"),
            ("preview-drain", "while player.isAudible {", "while false {"),
            ("unload-cache-invalidation", "unloading = true\n        loadedDirectory = nil", "unloading = true"),
            ("cancelled-renderer-session", "if self?.generation == token { self?.stop() }", ""),
            ("preview-session-double-release", "if release { AudioSessionUsers.end(.speech) }", "AudioSessionUsers.end(.speech)"),
            ("cold-installation-revision", "let directory = try await packs.requireInstalledDirectory()\n        try Task.checkCancellation()\n        // First verification can publish the installed directory and advance\n        // its revision. Capture the authoritative revision after that finishes.\n        let revision = packs.installationRevision", "let revision = packs.installationRevision\n        let directory = try await packs.requireInstalledDirectory()\n        try Task.checkCancellation()\n        guard revision == packs.installationRevision else { throw CancellationError() }"),
            ("installation-invalidated-during-load", "guard await isValid() else { throw CancellationError() }", ""),
        ]:
            if old not in actual:
                raise RuntimeError("Update mutation anchor: " + name)
            variants.append((name, actual.replace(old, new), False))
    with tempfile.TemporaryDirectory(prefix="lively-neural-speaker-") as directory:
        work = Path(directory)
        for name, source, positive in variants:
            swift = work / (name + ".swift")
            swift.write_text(fixture.replace("// INSERT_ACTUAL_NEURAL_SPEAKER", source))
            binary = work / name
            flags = ["-sanitize=thread"] if args.thread_sanitizer and positive else []
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                            "-parse-as-library", "-module-cache-path", str(work / "modules"), *flags,
                            str(swift), "-o", str(binary)], check=True, timeout=90)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            if positive:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or "Neural speaker regression failed")
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
