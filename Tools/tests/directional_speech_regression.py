#!/usr/bin/env python3
"""Run directional speech tests: python3 Tools/tests/directional_speech_regression.py.

Compiles actual AppSettings, Language and SonioxSpeaker sources plus the real
ConversationStore speech methods with deterministic audio/network/defaults
fakes. No credentials, microphone, network requests or app preferences are used.
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    settings = (root / "Lively/Model/AppSettings.swift").read_text()
    if settings.count("UserDefaults.standard") != 1 or settings.count("private init()") != 1:
        raise RuntimeError("Update AppSettings test dependency/visibility substitutions")
    # Isolate storage and expose its constructor to test persistence reloads.
    settings = settings.replace("UserDefaults.standard", "TestDefaults.standard").replace("private init()", "init()")
    language = (root / "Lively/Model/Language.swift").read_text()
    speaker = (root / "Lively/Networking/SonioxSpeaker.swift").read_text()
    store = (root / "Lively/Model/ConversationStore.swift").read_text()
    speech_methods = method(store, "speak") + "\n" + method(store, "completeSentences")
    fixture = Path(__file__).with_name("DirectionalSpeechRegression.swift").read_text()
    for marker, source in [("// INSERT_ACTUAL_LANGUAGE", language),
                           ("// INSERT_ACTUAL_SETTINGS", settings),
                           ("// INSERT_ACTUAL_SPEAKER", speaker),
                           ("// INSERT_ACTUAL_TRANSLATION_SPEAKER", (root / "Lively/Networking/TranslationSpeaker.swift").read_text()),
                           ("// INSERT_ACTUAL_SPEECH_METHODS", speech_methods)]:
        if fixture.count(marker) != 1:
            raise RuntimeError("Expected one source marker: " + marker)
        fixture = fixture.replace(marker, source)
    variants = [("regression", fixture, True)]
    if args.negative_controls:
        for name, old, new in [
            ("source-default-changed", 'SpeechSource(rawValue: defaults.string(forKey: "speechSource") ?? "") ?? .original',
             'SpeechSource(rawValue: defaults.string(forKey: "speechSource") ?? "") ?? .downloaded'),
            ("source-persistence-removed", 'didSet { defaults.set(speechSource.rawValue, forKey: "speechSource") }', 'didSet {}'),
        ]:
            if fixture.count(old) != 1:
                raise RuntimeError("Update source-selection mutation anchor: " + old)
            variants.append((name, fixture.replace(old, new), False))
    with tempfile.TemporaryDirectory(prefix="lively-directional-regression-") as directory:
        work = Path(directory)
        for name, actual, should_pass in variants:
            source = work / (name + ".swift")
            source.write_text(actual)
            binary = work / name
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                            "-module-cache-path", str(work / "modules"), "-parse-as-library", str(source),
                            "-o", str(binary)], check=True, timeout=90)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            if should_pass:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or "Directional speech regression failed")
            elif result.returncode == 0 or "FAIL:" not in result.stderr:
                raise RuntimeError("Negative control was not detected: " + name)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
