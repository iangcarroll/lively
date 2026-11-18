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
                ("offline-settings-captured-before-outage", "if let makeLocal { local = makeLocal() }", ""),
                ("raw-tail-capability-hidden", "var drainsTextOnPause: Bool { active == .cloud ? cloud.drainsTextOnPause : local.drainsTextOnPause }", "var drainsTextOnPause: Bool { false }"),
                ("raw-tail-capability-wrong-source", "var drainsTextOnPause: Bool { active == .cloud ? cloud.drainsTextOnPause : local.drainsTextOnPause }", "var drainsTextOnPause: Bool { cloud.drainsTextOnPause }"),
                ("online-starts-fixed-locale", "let source: Source = pathAvailable ? .cloud : .local", "let source: Source = .local"),
                ("offline-starts-cloud", "let source: Source = pathAvailable ? .cloud : .local", "let source: Source = .cloud"),
                ("retained-cloud-session-rebuilt", "if cloudOwned, cloudStarted {", "if false {"),
                ("paused-cloud-final-ignored", "cloud.onEvent = { [weak self] event in\n            guard let self, self.cloudSession == session, self.active == .cloud,\n                  self.phase != .stopped else { return }", "cloud.onEvent = { [weak self] event in\n            guard let self, self.cloudSession == session, self.active == .cloud,\n                  self.phase == .listening else { return }"),
                ("paused-pcm-uploaded", "guard phase == .listening, !chunk.isEmpty else { return }", "guard phase != .stopped, !chunk.isEmpty else { return }"),
                ("paused-reconnect-started", "case .paused, .prewarmed:\n", "case .paused, .prewarmed:\n                if newValue { cloud.start() }\n"),
                ("old-cloud-callback-accepted", "guard let self, self.cloudSession == session, self.active == .cloud,\n                  self.phase != .stopped else { return }\n            self.onEvent(event)", "guard let self, self.active == .cloud,\n                  self.phase != .stopped else { return }\n            self.onEvent(event)"),
                ("old-local-callback-accepted", "guard let self, self.localSession == session, self.active == .local,\n                  self.phase != .stopped else { return }\n            self.onEvent(event)", "guard let self, self.active == .local,\n                  self.phase != .stopped else { return }\n            self.onEvent(event)"),
                ("old-cloud-failure-accepted", "guard let self, self.cloudSession == session, self.phase != .stopped else { return }", "guard let self, self.phase != .stopped else { return }"),
                ("old-local-failure-accepted", "local.onStatus = { [weak self] status in\n            guard let self, self.localSession == session, self.active == .local,", "local.onStatus = { [weak self] status in\n            guard let self, self.active == .local,"),
                ("failed-cloud-replay-continues", "case .failed:\n                self.tearDown()", "case .failed:\n                self.stopCloud()"),
                ("path-loss-discards-cloud-audio", "if source != active {\n            if active == .local", "if source != active {\n            if active == .cloud { stopCloud() }\n            if active == .local"),
                ("unpaused-cloud-resume-clears-backlog", "if cloudPaused {", "if true {"),
                ("local-assets-failure-ends-online-turn", "if self.phase == .listening, !self.pathAvailable, self.cloudOwned {", "if false {"),
                ("paused-retry-discards-accepted-audio", "switch status {\n            case .failed:", "switch status {\n            case .reconnecting where self.phase != .listening:\n                self.stopCloud()\n                self.onStatus(.idle)\n            case .failed:"),
                ("failed-local-gets-pending-input", "seconds: &bufferedSeconds)\n                if localStarted { local.send(chunk) }", "seconds: &bufferedSeconds)\n                local.send(chunk)"),
                ("retained-cloud-idle-ignored", "if status == .idle { self.cloudStarted = false }", ""),
                ("suspension-correction-dropped", "self.phase != .stopped else { return }\n            self.onEvent(event)\n        }\n        cloud.onStatus", "self.phase != .stopped, self.pathAvailable else { return }\n            self.onEvent(event)\n        }\n        cloud.onStatus"),
                ("suspension-hard-stop-restarts-local", "let token = generation\n                    cloud.networkAvailable = false\n                    guard generation == token, phase == .listening, !pathAvailable else { return }", "cloud.networkAvailable = false"),
                ("offline-replay-reordered", "for chunk in replay {", "for chunk in replay.reversed() {"),
                ("translator-source-not-published", "onSourceChange?(source, replayed)", ""),
                ("paused-offline-replay-retained", "buffer.removeAll()\n        bufferedSeconds = 0\n        // Keep this callback epoch:", "// Keep this callback epoch:"),
                ("online-failure-starts-local", "case .failed:\n                self.tearDown()", "case .failed:\n                self.local.start()\n                self.tearDown()"),
                ("offline-replay-unbounded", "while seconds > maxBufferSeconds, !chunks.isEmpty {", "while false, !chunks.isEmpty {"),
                ("used-idle-cloud-not-cleaned", "guard cloudOwned else { return }", "guard cloudStarted else { return }"),
            ]
            for name, old, new in mutations:
                run_variant(work, name, replace_once(source, old, new), False)


if __name__ == "__main__":
    main()
