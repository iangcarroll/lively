#!/usr/bin/env python3
"""Check actual Face/empty-transcript guidance against speech connection state."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

from listening_prompt_regression import declaration, replace_once

ROOT = Path(__file__).resolve().parents[2]

FIXTURE = r'''
import Foundation
final class AppSettings {
    static let shared = AppSettings()
    var chineseScript = ChineseScript.simplified
    var languages = LanguagePair.default
}
struct GuidanceStore {
    enum Status: Equatable { case idle, connecting, live, reconnecting, offline, failed(String) }
    var status = Status.live
    var isListening = true
    var isAutomaticLanguageMode = false
    var isOnline = true
    var isUsingOnDevice = false
    var listenerLanguage = Language.english
    var isConnecting: Bool { status == .connecting || status == .reconnecting }
}
struct FaceGuidance {
    let store: GuidanceStore
    let language: Language?
    // INSERT_FACE
}
struct EmptyGuidance {
    let store: GuidanceStore
    var isConnecting: Bool { store.isConnecting }
    var isListening: Bool { store.isListening }
    // INSERT_EMPTY
    // INSERT_EXPLANATION
}
@main struct ListeningGuidanceRegression {
    static var assertions = 0
    static var failures = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { failures += 1; print("FAIL: \(message)") }
    }
    static func both(_ store: GuidanceStore, _ language: Language, _ expected: String, _ context: String) {
        check(FaceGuidance(store: store, language: language).emptyPrompt == expected, "Face \(language.id): \(context)")
        check(EmptyGuidance(store: store).prompt(in: language) == expected, "Empty transcript \(language.id): \(context)")
    }
    static func main() {
        for code in ["en", "ja", "zh", "es", "fr", "und"] {
            let language = Language(code)
            var store = GuidanceStore()
            both(store, language, language.phrases.listening, "live online capture says listening")
            for phase in [GuidanceStore.Status.connecting, .reconnecting] {
                store.status = phase
                both(store, language, language.phrases.connecting, "a pending connection does not claim live capture")
            }
            store.status = .offline
            store.isOnline = false
            both(store, language, language.phrases.waitingForConnection, "buffered cloud audio waits for connection")
            for phase in [GuidanceStore.Status.idle, .offline, .live] {
                store.status = phase
                store.isListening = false
                both(store, language, language.phrases.tapToStart, "stopped guidance remains an invitation to start")
            }
            store.isListening = true
            store.isUsingOnDevice = true
            store.status = .live
            both(store, language, language.phrases.listening, "live local capture remains listening without internet")
            store.isUsingOnDevice = false
            store.isOnline = true
            store.isAutomaticLanguageMode = true
            both(store, language, language.phrases.listening, "automatic live capture retains localized listening")
            store.isOnline = false
            store.status = .offline
            check(FaceGuidance(store: store, language: language).emptyPrompt == "Automatic detection needs internet",
                  "automatic Face guidance retains its explicit internet requirement")
            check(EmptyGuidance(store: store).explanation.contains("Automatic detection needs internet"),
                  "automatic empty transcript retains its internet explanation")
        }
        var automatic = GuidanceStore()
        automatic.isAutomaticLanguageMode = true
        check(FaceGuidance(store: automatic, language: nil).emptyPrompt == "Listening for another language", "unknown live partner remains automatic")
        automatic.isListening = false
        check(FaceGuidance(store: automatic, language: nil).emptyPrompt == "Automatic", "unknown stopped partner remains neutral")
        automatic.isOnline = false
        check(FaceGuidance(store: automatic, language: nil).emptyPrompt == "Automatic detection needs internet", "internet guidance precedes unknown-partner fallback")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(assertions) actual listening-guidance getter assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    paths = [ROOT / "Lively/Views/FaceToFaceScreen.swift", ROOT / "Lively/Views/Transcripts.swift"]
    hashes = [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths]
    face = declaration(paths[0].read_text(), "private var emptyPrompt: String").replace("private var", "var", 1)
    empty = declaration(paths[1].read_text(), "private func prompt(in language: Language)").replace("private func", "func", 1)
    explanation = declaration(paths[1].read_text(), "private var explanation: String").replace("private var", "var", 1)
    variants = [("production", face, empty, True)]
    if args.negative_controls:
        for target, source, guard in [("face", face, "store.isListening"), ("empty", empty, "isListening")]:
            old = f"        if {guard} && store.status == .offline {{ return language.phrases.waitingForConnection }}"
            for name, new in [
                ("offline-claims-listening", ""),
                ("stopped-claims-buffering", "        if store.status == .offline { return language.phrases.waitingForConnection }"),
                ("local-live-claims-buffering", f"        if {guard} && !store.isOnline {{ return language.phrases.waitingForConnection }}"),
            ]:
                changed = replace_once(source, old, new)
                variants.append((target + "-" + name, changed if target == "face" else face,
                                 changed if target == "empty" else empty, False))
    with tempfile.TemporaryDirectory(prefix="lively-listening-guidance-") as directory:
        work = Path(directory)
        for name, actual_face, actual_empty, positive in variants:
            swift = work / (name + ".swift")
            swift.write_text(FIXTURE.replace("// INSERT_FACE", actual_face).replace("// INSERT_EMPTY", actual_empty)
                             .replace("// INSERT_EXPLANATION", explanation))
            binary = work / name
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                            "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                            "-module-cache-path", str(work / "modules"),
                            str(ROOT / "Lively/Model/Language.swift"), str(ROOT / "Lively/Model/Phrases.swift"),
                            str(swift), "-o", str(binary)], cwd=ROOT, check=True, timeout=90)
            result = subprocess.run([str(binary)], cwd=ROOT, capture_output=True, text=True, timeout=15)
            if positive:
                print(result.stdout, end="", flush=True)
                if result.returncode: raise RuntimeError(result.stderr or "Guidance getter regression failed")
            elif result.returncode != 1 or "FAIL:" not in result.stdout:
                raise RuntimeError("Fault control must fail a behavioral assertion, not compile or crash: " + name)
            else:
                print("PASS: " + name + " detected deliberate corruption", flush=True)
    if [hashlib.sha256(p.read_bytes()).hexdigest() for p in paths] != hashes:
        raise RuntimeError("Guidance source changed during the run; re-run on the frozen source")
    print("PASS: actual guidance sources remained unchanged", flush=True)


if __name__ == "__main__":
    main()
