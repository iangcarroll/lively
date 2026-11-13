#!/usr/bin/env python3
"""Exercise the actual iOS AudioSessionUsers policy on macOS with stateful API fakes.

This checks policy, synchronization, and channel selection with native conversion.
It does not verify iOS route availability, physical devices, or acoustic leakage.
Run: python3 Tools/tests/audio_session_regression.py
Add --negative-controls to prove assertions detect broken reference counting,
missing input validation, and a removed map; mutations use only a temp directory.
"""

from pathlib import Path
import argparse
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    mic_source = (root / "Lively/Audio/MicCapture.swift").read_text()
    input_start = mic_source.index("        if #available(iOS 26.2, *), AVAudioSession.sharedInstance().mode == .dualRoute {")
    input_end = mic_source.index("        #endif", input_start)
    input_mapping = mic_source[input_start:input_end]
    start = mic_source.index("nonisolated enum AudioSessionUsers {")
    source = mic_source[start:]
    if source.count("#if os(iOS)") != 4:
        raise RuntimeError("Review the extracted iOS audio-session compile branches")
    source = source.replace("#if os(iOS)", "#if LIVELY_IOS_SESSION_TEST")
    fixture = Path(__file__).with_name("AudioSessionRegression.swift").read_text()
    marker = "// INSERT_ACTUAL_AUDIO_SESSION_USERS"
    if fixture.count(marker) != 1:
        raise RuntimeError("Expected exactly one production-source marker")
    if fixture.count("// INSERT_ACTUAL_INPUT_MAPPING") != 1:
        raise RuntimeError("Expected exactly one production-input marker")
    jobs = [("ios26", source, input_mapping, False), ("legacy-ios", source, input_mapping, False)]
    if args.negative_controls:
        old = "else { users[user] = count - 1 }"
        if source.count(old) != 1:
            raise RuntimeError("Review the reference-count mutation for the updated production source")
        jobs.append(("broken-count", source.replace(old, "else { users.removeValue(forKey: user) }"), input_mapping, True))
        old = "converter.channelMap = [NSNumber(value: builtInChannel)]"
        if input_mapping.count(old) != 1:
            raise RuntimeError("Review the input-map mutation for the updated production source")
        jobs.append(("missing-input-map", source, input_mapping.replace(old, "_ = builtInChannel"), True))
        metadata_checks = (
            "inputs.allSatisfy({ $0.channels?.isEmpty == false })",
            "inputs.reduce(0, { $0 + ($1.channels?.count ?? 0) }) == Int(inputFormat.channelCount)",
        )
        unchecked_mapping = input_mapping
        for check in metadata_checks:
            if unchecked_mapping.count(check) != 1:
                raise RuntimeError("Review the input-metadata mutation for the updated production source")
            unchecked_mapping = unchecked_mapping.replace(check, "true")
        jobs.append(("missing-input-validation", source, unchecked_mapping, True))
    status = 0
    with tempfile.TemporaryDirectory(prefix="lively-audio-session-") as directory:
        work = Path(directory)
        for variant, build_source, variant_mapping, negative_control in jobs:
            if variant == "legacy-ios":
                build_source = build_source.replace("#available(iOS 26.2, *)", "#available(macOS 99.0, *)")
            combined = work / "Regression.swift"
            if variant == "legacy-ios":
                variant_mapping = variant_mapping.replace("#available(iOS 26.2, *)", "#available(macOS 99.0, *)")
            combined.write_text(fixture.replace(marker, build_source).replace("// INSERT_ACTUAL_INPUT_MAPPING", variant_mapping))
            executable = work / variant
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-D", "LIVELY_IOS_SESSION_TEST", "-module-cache-path", str(work / "modules"),
                "-parse-as-library", str(combined), "-o", str(executable),
            ], check=True, timeout=60)
            result = subprocess.run(
                [str(executable), "legacy-ios" if variant == "legacy-ios" else "ios26"],
                timeout=20, capture_output=negative_control, text=negative_control,
            )
            if negative_control:
                detected = result.returncode == 1 and "FAIL " in result.stdout
                print(f"{'ok  ' if detected else 'FAIL'} negative control {variant}: assertions {'detected' if detected else 'missed'} mutation")
                if not detected:
                    print(result.stdout)
                    print(result.stderr)
                status = max(status, int(not detected))
            else:
                status = max(status, int(result.returncode != 0))
    raise SystemExit(status)


if __name__ == "__main__":
    main()
