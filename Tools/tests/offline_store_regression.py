#!/usr/bin/env python3
"""Exercise actual store translation/voice selection with cloud-call tripwires."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def block(source, declaration):
    match = re.search(r"^    " + declaration + r"[^\n]*\{", source, re.M)
    if not match:
        raise RuntimeError("Missing production declaration: " + declaration)
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
    store = (ROOT / "Lively/Model/ConversationStore.swift").read_text()
    methods = "\n".join(block(store, declaration) for declaration in [
        r"private var textTranslator:", r"private var usesOnDeviceServices:",
        r"var translatesTypedTextOnDevice:",
        r"var canSpeakTranslations:", r"func speechRoutingDidChange\(",
        r"func submitTyped\(", r"private func translate\(", r"private func activeSpeaker\(",
        r"private func setPath\(",
    ])
    fixture = Path(__file__).with_name("OfflineStoreRegression.swift").read_text()
    for marker, path in [
        ("// INSERT_ACTUAL_LANGUAGE", "Lively/Model/Language.swift"),
        ("// INSERT_ACTUAL_UTTERANCE", "Lively/Model/Utterance.swift"),
        ("// INSERT_ACTUAL_SPEAKER_PROTOCOL", "Lively/Networking/TranslationSpeaker.swift"),
    ]:
        fixture = fixture.replace(marker, (ROOT / path).read_text())
    variants = [("offline-store", methods, True)]
    if args.negative_controls:
        mutations = [
            ("typed-local-selection-removed", "if usesOnDeviceServices { return AppleTranslator() }", ""),
            ("spoken-local-selection-removed", "self?.demo == nil && self?.usesOnDeviceServices == true ? AppleTranslator() : translator", "translator"),
            ("offline-original-network-guard-removed", "guard isOnline else {", "guard true else {"),
            ("routing-switch-not-cancelled", "func speechRoutingDidChange() {\n        speaker?.stop()", "func speechRoutingDidChange() {"),
            ("cloud-voice-not-cancelled", "speaker?.stop()\n        speaker = nil\n        engine?.networkAvailable = online", "speaker = nil\n        engine?.networkAvailable = online"),
        ]
        for name, old, new in mutations:
            if methods.count(old) != 1:
                raise RuntimeError("Update store mutation anchor: " + old)
            variants.append((name, methods.replace(old, new), False))
    with tempfile.TemporaryDirectory(prefix="lively-offline-store-") as directory:
        work = Path(directory)
        for name, actual, should_pass in variants:
            swift = work / (name + ".swift")
            swift.write_text(fixture.replace("// INSERT_ACTUAL_STORE", actual))
            binary = work / name
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                            "-parse-as-library", "-module-cache-path", str(work / "modules"), str(swift),
                            "-o", str(binary)], check=True, timeout=90)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            if should_pass:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or "Offline store regression failed")
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
