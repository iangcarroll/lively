#!/usr/bin/env python3
"""Compile the production hybrid engine against deterministic local/cloud engines."""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def run_variant(work, name, source, should_pass):
    swift = work / (name + ".swift")
    swift.write_text(source)
    binary = work / name
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        "-parse-as-library", "-module-cache-path", str(work / "modules"),
        str(ROOT / "Lively/Networking/SpeechEngine.swift"), str(swift),
        str(ROOT / "Tools/tests/HybridOfflineRegression.swift"), "-o", str(binary),
    ], check=True, timeout=90)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
    if should_pass:
        print(result.stdout, end="")
        if result.returncode:
            raise RuntimeError(result.stderr or "Production hybrid regression failed")
    elif result.returncode == 0 or "FAIL:" not in result.stdout:
        raise RuntimeError("Negative control was not detected: " + name)
    else:
        print("PASS: " + name + " detected deliberate corruption")


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError("Update hybrid regression mutation anchor: " + old)
    return source.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    source = (ROOT / "Lively/Networking/HybridSpeechEngine.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="lively-hybrid-offline-") as directory:
        work = Path(directory)
        run_variant(work, "hybrid", source, True)
        if args.negative_controls:
            mutations = [
                ("delayed-local-handoff", "if active == .cloud {\n                    switchToLocal()", "if active == .cloud {\n                    // delayed local handoff"),
                ("cloud-ready-while-offline", "guard self.networkAvailable else { return }", "// accepted stale cloud readiness"),
                ("cloud-start-while-offline", "if networkAvailable { cloud.start() }", "cloud.start()"),
            ]
            for name, old, new in mutations:
                run_variant(work, name, replace_once(source, old, new), False)


if __name__ == "__main__":
    main()
