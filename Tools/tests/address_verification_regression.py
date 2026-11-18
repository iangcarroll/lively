#!/usr/bin/env python3
"""Check the production address verification helper without network requests."""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def replace_method(source, signature, replacement):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[:start] + replacement + source[end:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    service = (ROOT / "Lively/Networking/MapAddressLookupService.swift").read_text()
    fixture = Path(__file__).with_name("AddressVerificationRegression.swift").read_text()
    variants = [("address-verification", service, True)]
    if args.negative_controls:
        legacy = """    private func numberParts(_ text: String) -> [String] {
        var parts: [String] = []
        var digits = ""
        for character in text {
            if let value = character.wholeNumberValue, value < 10 {
                digits += String(value)
            } else if !digits.isEmpty {
                parts.append(digits)
                digits = ""
            }
        }
        if !digits.isEmpty { parts.append(digits) }
        return parts.sorted()
    }"""
        variants += [
            ("ideographs-counted-as-address-numbers", replace_method(service,
                "    private func numberParts(_ text: String) -> [String] {", legacy), False),
            ("address-numbers-ignored", replace_method(service,
                "    private func numberParts(_ text: String) -> [String] {",
                "    private func numberParts(_ text: String) -> [String] { [] }"), False),
            ("original-street-query-removed", replace_method(service,
                "    private func geocodingQueries(for source: Candidate, language: AddressLanguage) -> [String] {",
                "    private func geocodingQueries(for source: Candidate, language: AddressLanguage) -> [String] { [source.address] }"), False),
            ("fallback-script-accepted", replace_method(service,
                "    private func supportsRequestedScript(_ text: String, language: AddressLanguage) -> Bool {",
                "    private func supportsRequestedScript(_ text: String, language: AddressLanguage) -> Bool { true }"), False),
            ("numbered-distance-bound-loosened", replace_method(service,
                "    private func isWithinLocationTolerance(_ distance: Double, sourceAddress: String) -> Bool {",
                "    private func isWithinLocationTolerance(_ distance: Double, sourceAddress: String) -> Bool { distance.isFinite && distance >= 0 && distance <= 500 }"), False),
        ]
    with tempfile.TemporaryDirectory(prefix="lively-address-verification-") as directory:
        work = Path(directory)
        for name, actual_service, positive in variants:
            source = work / (name + ".swift")
            source.write_text(actual_service + "\n" + fixture)
            binary = work / name
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                "-default-isolation", "MainActor",
                "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                "-module-cache-path", str(work / "modules"),
                str(ROOT / "Lively/Model/AddressLocation.swift"), str(source), "-o", str(binary),
            ], cwd=ROOT, check=True, timeout=120)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            if positive:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or "Production address verification failed")
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
