#!/usr/bin/env python3
"""Run with: python3 Tools/tests/test_speech_player.py (macOS with Xcode).

Compiles the current SpeechPlayer.swift with deterministic audio mocks; no
device, credentials, network, or Xcode project changes are needed. The audio
imports are replaced by API-shaped mocks. A second build enables the current
iOS code through a test compile condition, so the production routing, failure
handling, and lifecycle behavior run on the host without a copied implementation.
"""

from pathlib import Path
import subprocess
import tempfile


def main():
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
        for variant in ("macos", "ios-routing"):
            build_source = source
            flags = []
            if variant == "ios-routing":
                build_source = source.replace("#if os(iOS)", "#if LIVELY_AUDIO_ROUTING_TEST")
                flags = ["-D", "LIVELY_AUDIO_ROUTING_TEST"]
            combined.write_text(fixture.replace(marker, build_source))
            executable = work / variant
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-module-cache-path", str(work / "modules"), "-parse-as-library", *flags,
                str(combined), "-o", str(executable),
            ], check=True, timeout=60)
            subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
