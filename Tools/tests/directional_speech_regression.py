#!/usr/bin/env python3
"""Run directional speech tests: python3 Tools/tests/directional_speech_regression.py.

Compiles actual AppSettings, Language and SonioxSpeaker sources plus the real
ConversationStore speech methods with deterministic audio/network/defaults
fakes. No credentials, microphone, network requests or app preferences are used.
"""

from pathlib import Path
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
    with tempfile.TemporaryDirectory(prefix="lively-directional-regression-") as directory:
        work = Path(directory)
        source = work / "Regression.swift"
        source.write_text(fixture)
        binary = work / "regression"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                        "-module-cache-path", str(work / "modules"), "-parse-as-library", str(source),
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    main()
