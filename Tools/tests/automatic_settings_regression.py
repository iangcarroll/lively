#!/usr/bin/env python3
"""Exercise production automatic settings with isolated Foundation persistence."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]

BOUNDARIES = r'''
// Only persistence selection and external service catalogs are substituted.
// AppSettings, its enums and the language catalog below are production source.
enum IsolatedDefaults {
    static let suiteName = ProcessInfo.processInfo.environment["LIVELY_SETTINGS_REGRESSION_SUITE"]!
    static let standard = Foundation.UserDefaults(suiteName: suiteName)!
}
typealias UserDefaults = IsolatedDefaults
struct ProviderCredential {
    let id: String
    var isOptional = false
}
struct SpeechProvider {
    let id: String
    let languages: [Language]
    var credentials: [ProviderCredential] { [] }
    func supports(_ pair: LanguagePair) -> Bool { pair.all.allSatisfy(languages.contains) }
    static let soniox = Self(id: "soniox", languages: Language.soniox)
    static let voxtralMistral = Self(id: "voxtral-mistral", languages: Language.voxtral)
    static let onDevice = Self(id: "on-device", languages: Language.appleOnDevice)
    static let fallback = soniox
    static let allCredentials: [ProviderCredential] = []
    static func with(id: String) -> Self {
        [soniox, voxtralMistral, onDevice].first { $0.id == id } ?? fallback
    }
}
enum Keychain {
    static func read(account: String) -> String? { nil }
    static func write(_ value: String?, account: String) {}
}
'''

HARNESS = r'''
@main
struct SettingsRegression {
    static var checks = 0
    static var failures = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: " + label) }
    }
    static func main() {
        let defaults = IsolatedDefaults.standard
        defer { defaults.removePersistentDomain(forName: IsolatedDefaults.suiteName) }
        defaults.removePersistentDomain(forName: IsolatedDefaults.suiteName)
        let fresh = AppSettings()
        expect(fresh.conversationMode == .automatic, "new installation defaults to automatic")
        expect(fresh.usesAutomaticLanguageDetection, "default Soniox activates automatic")
        expect(fresh.speechListenerLanguage == .english, "fresh listener uses saved leading language")
        let pair = LanguagePair(first: Language("es"), second: Language("de"))
        defaults.set(pair.first.rawValue, forKey: "firstLanguage")
        defaults.set(pair.second.rawValue, forKey: "secondLanguage")
        defaults.set("fr", forKey: "speechListenerLanguage")
        let migrated = AppSettings()
        expect(migrated.conversationMode == .automatic, "existing settings without mode migrate to automatic")
        expect(migrated.languages == pair, "migration preserves manual pair")
        expect(migrated.speechListenerLanguage == Language("fr"), "automatic listener is outside manual pair")
        migrated.speechListenerLanguage = Language("ja")
        expect(migrated.speechListenerLanguage == Language("ja"), "automatic setter accepts language outside pair")
        expect(migrated.languages == pair, "Your language setter never mutates pair")
        expect(defaults.string(forKey: "speechListenerLanguage") == "ja", "listener written to real persistent suite")
        let reloaded = AppSettings()
        expect(reloaded.speechListenerLanguage == Language("ja"), "listener survives actual settings reinstantiation")
        expect(reloaded.languages == pair, "reload keeps legacy pair independent")
        reloaded.speechListenerLanguage = Language("xx")
        expect(reloaded.speechListenerLanguage == Language("ja"), "unsupported listener setter rejected")
        reloaded.languages = .default
        reloaded.conversationMode = .pair
        expect(!reloaded.usesAutomaticLanguageDetection, "manual opt-out deactivates automatic")
        expect(defaults.string(forKey: "conversationMode") == "pair", "mode written to real persistence")
        let manual = AppSettings()
        expect(manual.conversationMode == .pair, "explicit pair opt-out survives reload")
        expect(manual.speechListenerLanguage == .english, "manual getter stays inside pair")
        manual.speechListenerLanguage = Language("fr")
        expect(manual.speechListenerLanguage == .english, "manual setter rejects outside-pair language")
        manual.conversationMode = .automatic
        expect(manual.speechListenerLanguage == Language("ja"), "manual getter did not destroy independent saved listener")
        let automaticReload = AppSettings()
        expect(automaticReload.conversationMode == .automatic, "switch back to automatic persists")
        for id in [SpeechProvider.onDevice.id, SpeechProvider.voxtralMistral.id] {
            automaticReload.providerID = id
            expect(!automaticReload.usesAutomaticLanguageDetection, "automatic inactive for provider " + id)
            expect(automaticReload.conversationMode == .automatic, "provider switch keeps chosen mode " + id)
        }
        automaticReload.providerID = SpeechProvider.soniox.id
        expect(automaticReload.usesAutomaticLanguageDetection && automaticReload.speechListenerLanguage == Language("ja"), "Soniox restores independent automatic listener")
        defaults.set("xx", forKey: "speechListenerLanguage")
        expect(AppSettings().speechListenerLanguage == .english, "invalid persisted automatic listener has supported fallback")
        defaults.set("invalid-mode", forKey: "conversationMode")
        expect(AppSettings().conversationMode == .automatic, "invalid persisted mode uses automatic default")
        print("Automatic settings regression: \(checks) checks, \(failures) failures")
        if failures > 0 {
            defaults.removePersistentDomain(forName: IsolatedDefaults.suiteName)
            exit(1)
        }
    }
}
'''


def changed(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError("Update automatic settings mutation anchor: " + old)
    return source.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    settings = (ROOT / "Lively/Model/AppSettings.swift").read_text()
    language = (ROOT / "Lively/Model/Language.swift").read_text()
    pickup = (ROOT / "Lively/Audio/NoiseGate.swift").read_text().split("/// Decides, chunk by chunk")[0]
    print("Settings source SHA256: " + hashlib.sha256(settings.encode()).hexdigest(), flush=True)
    variants = [("automatic-settings", settings, True)]
    if args.negative_controls:
        for name, old, new in [
            ("default-manual-pair", 'ConversationMode(rawValue: defaults.string(forKey: "conversationMode") ?? "") ?? .automatic',
             'ConversationMode(rawValue: defaults.string(forKey: "conversationMode") ?? "") ?? .pair'),
            ("automatic-getter-clamped-to-pair", "if usesAutomaticLanguageDetection {\n                return Language.soniox.contains(language) ? language : .english\n            }", ""),
            ("automatic-setter-clamped-to-pair", "guard usesAutomaticLanguageDetection\n                ? Language.soniox.contains(newValue) : languages.contains(newValue) else { return }",
             "guard languages.contains(newValue) else { return }"),
            ("mode-not-persisted", 'defaults.set(conversationMode.rawValue, forKey: "conversationMode")', "_ = conversationMode"),
            ("listener-not-persisted", 'defaults.set(speechListenerLanguageCode, forKey: "speechListenerLanguage")', "_ = speechListenerLanguageCode"),
            ("automatic-enabled-for-offline-and-voxtral", "conversationMode == .automatic && providerID == SpeechProvider.soniox.id", "conversationMode == .automatic"),
            ("unsupported-listener-exposed", "return Language.soniox.contains(language) ? language : .english", "return language"),
            ("listener-mutation-changes-pair", "speechListenerLanguageCode = newValue.rawValue", "speechListenerLanguageCode = newValue.rawValue\n            languages = .default"),
        ]:
            variants.append((name, changed(settings, old, new), False))
    with tempfile.TemporaryDirectory(prefix="lively-automatic-settings-") as directory:
        work = Path(directory)
        for name, actual, positive in variants:
            # The only visibility change permits recreating the real singleton type.
            actual = changed(actual, "    private init() {", "    init() {")
            source = work / (name + ".swift")
            source.write_text("import Foundation\n" + BOUNDARIES + language + pickup + actual + HARNESS)
            binary = work / name
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                            "-parse-as-library", "-module-cache-path", str(work / "modules"),
                            str(source), "-o", str(binary)], check=True, timeout=90)
            suite = "sh.ian.lively.settings-regression." + str(uuid.uuid4())
            environment = dict(os.environ, LIVELY_SETTINGS_REGRESSION_SUITE=suite)
            try:
                result = subprocess.run([str(binary)], capture_output=True, text=True,
                                        env=environment, timeout=30)
            finally:
                # Remove even the empty backing plist after each genuine suite test.
                subprocess.run(["defaults", "delete", suite], capture_output=True, check=False)
                (Path.home() / "Library/Preferences" / (suite + ".plist")).unlink(missing_ok=True)
            summary = re.search(r"Automatic settings regression: (\d+) checks, (\d+) failures", result.stdout)
            if positive:
                print(result.stdout, end="", flush=True)
                if result.returncode or not summary or int(summary[2]):
                    raise RuntimeError(result.stdout + result.stderr)
            elif result.returncode != 1 or not summary or not int(summary[2]) or "FAIL:" not in result.stdout:
                raise RuntimeError("Control did not fail by a meaningful assertion: " + name + "\n" + result.stdout + result.stderr)
            else:
                print("PASS: " + name + " detected (" + summary[2] + " failed assertions)", flush=True)
    print("Validated " + str(len(variants) - 1) + " settings corruption controls.", flush=True)


if __name__ == "__main__":
    main()
