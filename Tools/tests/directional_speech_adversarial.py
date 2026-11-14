#!/usr/bin/env python3
"""Exercise route bursts, settings changes, and capture ownership.

Runs on a macOS host with deterministic audio mocks, without credentials or
audio hardware. Routing/settings reuse the shared API fakes. Capture uses real
AVFoundation and skips only engine startup. Current production methods are
compiled in each build; no routing or ownership implementation is copied.
"""

from pathlib import Path
import argparse
import re
import subprocess
import tempfile


def method(source, name):
    match = re.search(r"^    (?:private |static )?func " + name + r"\([^\n]*\)[^\n]*\{", source, re.M)
    if not match:
        raise RuntimeError("Missing production method: " + name)
    opening = source.index("{", match.start())
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end]


def settings_source(root, disable_routing_change=False):
    shared = Path(__file__).with_name("DirectionalSpeechRegression.swift").read_text()
    mocks = shared.split("final class Utterance", 1)[0]
    settings = (root / "Lively/Model/AppSettings.swift").read_text()
    settings = settings.replace("UserDefaults.standard", "TestDefaults.standard").replace("private init()", "init()")
    for marker, source in [
        ("// INSERT_ACTUAL_LANGUAGE", (root / "Lively/Model/Language.swift").read_text()),
        ("// INSERT_ACTUAL_SETTINGS", settings),
        ("// INSERT_ACTUAL_SPEAKER", (root / "Lively/Networking/SonioxSpeaker.swift").read_text()),
        ("// INSERT_ACTUAL_TRANSLATION_SPEAKER", (root / "Lively/Networking/TranslationSpeaker.swift").read_text()),
    ]:
        if mocks.count(marker) != 1:
            raise RuntimeError("Expected one source marker: " + marker)
        mocks = mocks.replace(marker, source)
    store = (root / "Lively/Model/ConversationStore.swift").read_text()
    methods = "\n".join(method(store, name) for name in [
        "setSpeaksTranslations", "speechSettingChanged", "speechRoutingDidChange",
        "speak", "activeSpeaker", "completeSentences",
    ])
    if disable_routing_change:
        methods = methods.replace(method(store, "speechRoutingDidChange"), "    func speechRoutingDidChange() {}")
    tests = Path(__file__).with_name("DirectionalSpeechAdversarialSettings.swift").read_text()
    return mocks + tests.replace("// INSERT_ACTUAL_SPEECH_METHODS", methods)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true",
                        help="also verify that missing route invalidation, settings cancellation, and mic cleanup are detected")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    production = (root / "Lively/Audio/SpeechPlayer.swift").read_text()
    production = production.replace("@preconcurrency import AVFoundation", "")
    production = production.replace("import AudioToolbox", "")
    production = production.replace("#if os(iOS)", "#if LIVELY_AUDIO_ROUTING_TEST")
    shared = Path(__file__).with_name("SpeechPlayerRegression.swift").read_text()
    mocks = shared.split("@main struct SpeechPlayerRegression", 1)[0]
    marker = "// INSERT_ACTUAL_SPEECH_PLAYER_SOURCE"
    if mocks.count(marker) != 1:
        raise RuntimeError("Expected one source marker in shared API mocks")
    tests = Path(__file__).with_name("DirectionalSpeechAdversarial.swift").read_text()
    mic = (root / "Lively/Audio/MicCapture.swift").read_text()
    if mic.count("        try startEngine(token)") != 1:
        raise RuntimeError("Update the microphone hardware dependency substitution")
    mic = mic.replace("        try startEngine(token)", "        // Hardware engine startup is disabled in this host lifecycle test.")
    mic_tests = Path(__file__).with_name("DirectionalSpeechAdversarialMic.swift").read_text()
    builds = [
        ("routing", mocks.replace(marker, production) + tests, ["-D", "LIVELY_AUDIO_ROUTING_TEST"], False),
        ("settings", settings_source(root), [], False),
        ("mic-deinit", mic + mic_tests, [], False),
    ]
    if args.negative_controls:
        if production.count("expected = nil") != 1:
            raise RuntimeError("Update the route-invalidation negative control")
        mic_cleanup = "            if holdsSession { AudioSessionUsers.end(.mic) }"
        if mic.count(mic_cleanup) != 1:
            raise RuntimeError("Update the microphone destructor negative control")
        invalidation_removed = production.replace("expected = nil", "// Invalidation deliberately disabled for the negative control.")
        mic_cleanup_removed = mic.replace(mic_cleanup, "            // Destructor release deliberately disabled for the negative control.")
        builds += [
            ("negative-routing", mocks.replace(marker, invalidation_removed) + tests,
             ["-D", "LIVELY_AUDIO_ROUTING_TEST"], True),
            ("negative-settings", settings_source(root, disable_routing_change=True), [], True),
            ("negative-mic-deinit", mic_cleanup_removed + mic_tests, [], True),
        ]
    with tempfile.TemporaryDirectory(prefix="lively-directional-adversarial-") as directory:
        work = Path(directory)
        for name, source, flags, expect_failure in builds:
            combined = work / (name + ".swift")
            combined.write_text(source)
            executable = work / name
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-module-cache-path", str(work / "modules"), "-parse-as-library", *flags,
                str(combined), "-o", str(executable),
            ], check=True, timeout=60)
            if expect_failure:
                result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
                detected = result.stdout.count("FAIL:")
                if result.returncode == 0 or detected == 0:
                    raise RuntimeError("Negative control was not caught by assertions: " + name + "\n" + result.stdout + result.stderr)
                print(f"PASS: {name} detected deliberate corruption ({detected} failed assertions)")
            else:
                subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
