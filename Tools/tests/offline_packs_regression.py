#!/usr/bin/env python3
"""Exercise production download orchestration against controlled system asset APIs."""

import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    source = (ROOT / "Lively/Model/OfflineLanguagePacks.swift").read_text()
    source = source.replace("import Speech\n", "").replace("import Translation\n", "")
    fixture = Path(__file__).with_name("OfflinePacksRegression.swift").read_text()
    variants = [("packs", source, True)]
    if args.negative_controls:
        mutations = [
            ("already-reserved-failure", "try await AssetInventory.reserve(locale: locale)",
             "guard try await AssetInventory.reserve(locale: locale) else { throw PackError.incomplete }"),
            ("one-direction-ready", "components.allSatisfy { $0.state == .ready }",
             "components.prefix(3).allSatisfy { $0.state == .ready }"),
            ("stale-request-accepted", "guard isDownloading, requestID == translationRequestID else { return }",
             "guard isDownloading else { return }"),
            ("reservation-cancellation-ignored", "try await AssetInventory.reserve(locale: locale)\n                    try check(token)",
             "try await AssetInventory.reserve(locale: locale)"),
            ("request-cancellation-ignored", "if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {\n                        try check(token)",
             "if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {"),
        ]
        for name, old, new in mutations:
            if source.count(old) != 1:
                raise RuntimeError("Update pack mutation anchor: " + old)
            variants.append((name, source.replace(old, new), False))
        guard = "guard direction == expectedDirection, requestID == translationRequestID else { return }"
        if source.count(guard) != 2:
            raise RuntimeError("Update duplicate callback mutation anchor")
        position = source.rindex(guard)
        variants.append(("duplicate-direction-accepted", source[:position] + source[position:].replace(guard, "", 1), False))
    with tempfile.TemporaryDirectory(prefix="lively-offline-packs-") as directory:
        work = Path(directory)
        for name, production, should_pass in variants:
            swift = work / (name + ".swift")
            swift.write_text(fixture.replace("// INSERT_ACTUAL_PACKS", production))
            binary = work / name
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                            "-parse-as-library", "-module-cache-path", str(work / "modules"), str(swift),
                            "-o", str(binary)], check=True, timeout=90)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            if should_pass:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or "Offline pack regressions failed")
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
