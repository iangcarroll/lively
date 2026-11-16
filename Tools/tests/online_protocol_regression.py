#!/usr/bin/env python3
"""Check actual Soniox frames through the store, models, and directional output.

Uses controlled translation/speech boundaries and a dedicated inert transport.
No network, microphone, credentials, app QA hooks, or temporary external fixtures.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

from online_conversation_regression import (
    ROOT, load_store_fixture, render_store_fixture, shared_store_harness,
)


def changed(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError("Update protocol integration mutation anchor: " + old)
    return source.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    store, methods, models, fixture = load_store_fixture()
    parser_source = (ROOT / "Lively/Networking/SonioxTranscriber.swift").read_text()
    soniox = parser_source.split("\nextension ProviderCredential {")[0]
    harness = shared_store_harness(fixture)
    tests = Path(__file__).parent
    print("Store source SHA256: " + hashlib.sha256(store.encode()).hexdigest(), flush=True)
    print("Parser source SHA256: " + hashlib.sha256(parser_source.encode()).hexdigest(), flush=True)
    variants = [("online-protocol", soniox, methods, True)]
    if args.negative_controls:
        variants.extend([
            ("producer-drops-opposite-reply", changed(
                soniox, "if let current = segment.translationSource, current != source {",
                "if let current = segment.translationSource, current != source {\n                    continue"), methods, False),
            ("consumer-reverses-language-and-route", soniox, changed(
                changed(methods,
                        "output = target == settings.speechListenerLanguage ? .headphones : .speaker",
                        "output = utterance.language == settings.speechListenerLanguage ? .headphones : .speaker"),
                "speaker.speak(ready, in: target, output: output)",
                "speaker.speak(ready, in: utterance.language, output: output)"), False),
            ("live-replies-withheld-until-endpoint", changed(
                soniox, "private func emit(_ segment: Segment, isCatchUp: Bool, stableTranslation: String? = nil) -> Bool {",
                "private func emit(_ segment: Segment, isCatchUp: Bool, stableTranslation: String? = nil) -> Bool {\n        if !segment.isClosed { return false }"), methods, False),
            ("consumer-drops-translation-only", soniox, changed(
                methods, "utterance.isTranslationOnly = segment.language.map { languages.contains($0) } == true",
                "utterance.isTranslationOnly = false"), False),
        ])
    with tempfile.TemporaryDirectory(prefix="lively-online-protocol-") as directory:
        work = Path(directory)
        for name, actual_parser, actual_store, positive in variants:
            store_file = work / "StoreHarness.swift"
            store_file.write_text(render_store_fixture(harness, methods=actual_store, models=models))
            parser_file = work / "Soniox.swift"
            parser_file.write_text(actual_parser)
            binary = work / name
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-parse-as-library", "-module-cache-path", str(work / "modules"),
                str(store_file), str(parser_file), str(tests / "OnlineProtocolTransport.swift"),
                str(tests / "OnlineProtocolRegression.swift"), "-o", str(binary),
            ], check=True, timeout=90)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=90)
            if positive:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or result.stdout or "Protocol integration failed")
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name + "\n"
                                   + result.stdout + result.stderr)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
