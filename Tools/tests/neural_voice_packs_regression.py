#!/usr/bin/env python3
"""Verify the real neural voice catalog and transactional download manager."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    parser.add_argument("--thread-sanitizer", action="store_true")
    args = parser.parse_args()
    catalog = (ROOT / "Lively/Model/NeuralVoiceCatalog.swift").read_text()
    manager = (ROOT / "Lively/Model/NeuralVoicePacks.swift").read_text()
    fixture = Path(__file__).with_name("NeuralVoicePacksRegression.swift").read_text()
    variants = [("packs", manager, True)]
    if args.negative_controls:
        mutations = [
            ("automatic-download", "guard !isDownloading, status != .deleting else { return }", "download(); return\n        guard !isDownloading, status != .deleting else { return }"),
            ("hash-check-removed", "guard hash.finalize().map({ String(format: \"%02x\", $0) }).joined() == file.sha256 else {", "guard true else {"),
            ("verification-generation-removed", "guard let job = verificationJob, job.id == id else { return }", "guard let job = verificationJob else { return }"),
            ("download-cancel-supersedes-delete", "guard isDownloading else { return }", "// cancellation incorrectly applies to deletion"),
            ("deletion-invalidates-after-unload", "installedDirectory = nil\n        installationRevision &+= 1\n        status = .deleting\n        do {\n            await beforeRemoving()", "do {\n            await beforeRemoving()\n            installedDirectory = nil\n            installationRevision &+= 1\n            status = .deleting"),
        ]
        for name, old, new in mutations:
            if manager.count(old) != 1:
                raise RuntimeError("Update neural pack mutation anchor: " + old)
            variants.append((name, manager.replace(old, new), False))
        # Removing one guard leaves independent task/IO cancellation intact.
        # This mutation breaks both protections to exercise the stale-result
        # assertion, rather than pretending redundant safety must fail alone.
        guards = "try Task.checkCancellation()\n        guard operation == token else { throw CancellationError() }"
        if manager.count(guards) != 1 or manager.count("worker?.cancel()") != 1:
            raise RuntimeError("Update neural cancellation mutation anchors")
        uncancelled = manager.replace(guards, "_ = token").replace("worker?.cancel()", "// cancellation deliberately removed")
        variants.append(("cancellation-and-generation-removed", uncancelled, False))
    with tempfile.TemporaryDirectory(prefix="lively-neural-voices-") as directory:
        work = Path(directory)
        for name, source, should_pass in variants:
            swift = work / (name + ".swift")
            swift.write_text(catalog + "\n" + source + "\n" + fixture)
            binary = work / name
            compiler = ["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library", "-module-cache-path", str(work / "modules")]
            if args.thread_sanitizer:
                compiler.append("-sanitize=thread")
            subprocess.run(compiler + [str(swift), "-o", str(binary)], check=True, timeout=120)
            arguments = [str(binary), str(ROOT / "Lively/Resources/kokoro-voice-manifest.json")]
            if not should_pass:
                arguments.append("--fail-fast")
            result = subprocess.run(arguments, capture_output=True, text=True, timeout=60)
            if should_pass:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or "Neural pack regression failed")
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name + "\n" + result.stderr)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
