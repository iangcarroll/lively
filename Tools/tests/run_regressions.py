#!/usr/bin/env python3
"""Run audio, offline language, translation, and release regressions on macOS."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread-sanitizer", action="store_true",
                        help="check microphone lifecycle, neural voice packs/speech, and package tests for data races")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]

    suites = [
        ("test_release_script.py", []),
        ("conversation_startup_regression.py", ["--negative-controls"]),
        ("directional_speech_regression.py", ["--negative-controls"]),
        ("test_speech_player.py", []),
        ("directional_speech_adversarial.py", ["--negative-controls"]),
        ("audio_session_regression.py", ["--negative-controls"]),
        ("hybrid_offline_regression.py", ["--negative-controls"]),
        ("offline_speech_regression.py", ["--negative-controls"]),
        ("offline_packs_regression.py", ["--negative-controls"]),
        ("offline_store_regression.py", ["--negative-controls"]),
        ("apple_translator_regression.py", ["--negative-controls"]),
        ("neural_voice_packs_regression.py", ["--negative-controls"]),
        ("neural_speaker_regression.py", ["--negative-controls"]),
        ("voice_preview_lifecycle_regression.py", ["--negative-controls"]),
    ]
    for name, options in suites:
        if args.thread_sanitizer and name in {"neural_voice_packs_regression.py", "neural_speaker_regression.py", "voice_preview_lifecycle_regression.py"}:
            options = [*options, "--thread-sanitizer"]
        print(f"Running {name}", flush=True)
        subprocess.run([sys.executable, str(root / "Tools/tests" / name), *options],
                       cwd=root, check=True, timeout=180)

    with tempfile.TemporaryDirectory(prefix="lively-audio-lifecycle-") as directory:
        work = Path(directory)
        flags = ["-sanitize=thread"] if args.thread_sanitizer else []
        binary = work / "audio-lifecycle"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-D", "DEBUG",
            "-default-isolation", "MainActor",
            "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
            "-module-cache-path", str(work / "modules"), *flags,
            str(root / "Lively/Audio/MicCapture.swift"),
            str(root / "Tools/tests/AudioLifecycleRegression.swift"), "-o", str(binary),
        ], cwd=root, check=True, timeout=120)
        subprocess.run([str(binary)], cwd=root, check=True, timeout=30)
    print("Running NeuralVoices package tests", flush=True)
    package_flags = ["--sanitize=thread"] if args.thread_sanitizer else []
    subprocess.run([
        "xcrun", "swift", "test", "--package-path", str(root / "Packages/NeuralVoices"), *package_flags,
    ], cwd=root, check=True, timeout=180)
    print("All regression suites passed.")


if __name__ == "__main__":
    main()
