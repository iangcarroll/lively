#!/usr/bin/env python3
"""Run audio, address, offline language, and translation regressions on macOS."""

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
        ("address_lookup_regression.py", ["--negative-controls"]),
        ("address_verification_regression.py", ["--negative-controls"]),
        ("conversation_startup_regression.py", ["--negative-controls"]),
        ("listening_prompt_regression.py", ["--negative-controls"]),
        ("listening_guidance_regression.py", ["--negative-controls"]),
        ("automatic_settings_regression.py", ["--negative-controls"]),
        ("online_conversation_regression.py", ["--negative-controls"]),
        ("soniox_language_regression.py", ["--negative-controls"]),
        ("automatic_soniox_regression.py", ["--negative-controls"]),
        ("automatic_conversation_regression.py", ["--negative-controls"]),
        ("online_protocol_regression.py", ["--negative-controls"]),
        ("socket_lifecycle_regression.py", ["--negative-controls"]),
        ("socket_replay_regression.py", ["--negative-controls"]),
        ("directional_speech_regression.py", ["--negative-controls"]),
        ("test_speech_player.py", ["--negative-controls"]),
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
        if args.thread_sanitizer and name in {"test_speech_player.py", "audio_session_regression.py", "neural_voice_packs_regression.py", "neural_speaker_regression.py", "voice_preview_lifecycle_regression.py"}:
            options = [*options, "--thread-sanitizer"]
        print(f"Running {name}", flush=True)
        # Speech fault controls exercise real drain and playback deadlines.
        timed_suites = {"socket_lifecycle_regression.py", "socket_replay_regression.py", "online_conversation_regression.py",
                        "online_protocol_regression.py", "automatic_conversation_regression.py"}
        suite_timeout = 420 if name in timed_suites else 180
        subprocess.run([sys.executable, str(root / "Tools/tests" / name), *options],
                       cwd=root, check=True, timeout=suite_timeout)

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
