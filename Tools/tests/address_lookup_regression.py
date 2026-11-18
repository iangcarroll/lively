#!/usr/bin/env python3
"""Exercise production address lookup state with controlled, out-of-order replies."""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    models = (ROOT / "Lively/Model/AddressLocation.swift").read_text()
    store = (ROOT / "Lively/Model/AddressLookupStore.swift").read_text()
    fixture = Path(__file__).with_name("AddressLookupRegression.swift").read_text()
    variants = [("address-lookup", store, True)]
    if args.negative_controls:
        guard = "guard isCurrent(token) else { return }"
        if store.count(guard) != 4:
            raise RuntimeError("Update address stale-response mutation anchors")
        # Cancellation and generation checks are independent defenses. Removing
        # their shared completion guard must expose ignored-cancellation replies.
        variants.append(("stale-response-guards-removed", store.replace(guard, "// Deliberately accept obsolete completions."), False))
        guard = "guard matches.contains(place) else { return }"
        if store.count(guard) != 1:
            raise RuntimeError("Update address selection mutation anchor")
        variants.append(("candidate-membership-removed", store.replace(guard, "// Deliberately accept forged and expired candidates."), False))
    with tempfile.TemporaryDirectory(prefix="lively-address-lookup-") as directory:
        work = Path(directory)
        for name, production, should_pass in variants:
            source = work / (name + ".swift")
            source.write_text(models + "\n" + production + "\n" + fixture)
            binary = work / name
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-parse-as-library", "-module-cache-path", str(work / "modules"),
                str(source), "-o", str(binary),
            ], check=True, timeout=120)
            command = [str(binary)] + ([] if should_pass else ["--fail-fast"])
            result = subprocess.run(command, capture_output=True, text=True, timeout=45)
            if should_pass:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or "Address lookup regressions failed")
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name + "\n" + result.stderr)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
