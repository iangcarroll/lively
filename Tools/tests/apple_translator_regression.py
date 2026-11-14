#!/usr/bin/env python3
"""Check production local-only translation retries with controlled framework errors."""

import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    whole = (ROOT / "Lively/Networking/Translator.swift").read_text()
    source = whole[whole.index("struct AppleTranslator:"):]
    fixture = Path(__file__).with_name("AppleTranslatorRegression.swift").read_text()
    variants = [("apple-translator", source, True)]
    if args.negative_controls:
        mutations = [
            ("retry-bound-removed", "guard retry < 2,", "guard retry < 3,"),
            ("internal-retry-removed", "case Translation.TranslationError.internalError:\n            return true",
             "case Translation.TranslationError.internalError:\n            return false"),
            ("unsupported-retried", "default:\n            return false", "default:\n            return true"),
        ]
        for name, old, new in mutations:
            if source.count(old) != 1:
                raise RuntimeError("Update Apple translation mutation anchor: " + old)
            variants.append((name, source.replace(old, new), False))
        cancellation = source.replace("try Task.checkCancellation()", "")
        cancellation = cancellation.replace("try await Task.sleep(for: .milliseconds(250 * retry))",
                                            "try? await Task.sleep(for: .milliseconds(250 * retry))")
        variants.append(("cancelled-retry-continued", cancellation, False))
    with tempfile.TemporaryDirectory(prefix="lively-apple-translator-") as directory:
        work = Path(directory)
        for name, actual, should_pass in variants:
            swift = work / (name + ".swift")
            swift.write_text(fixture.replace("// INSERT_ACTUAL_TRANSLATOR", actual))
            binary = work / name
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                            "-parse-as-library", "-module-cache-path", str(work / "modules"), str(swift),
                            "-o", str(binary)], check=True, timeout=90)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            if should_pass:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or "Apple translator regression failed")
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
