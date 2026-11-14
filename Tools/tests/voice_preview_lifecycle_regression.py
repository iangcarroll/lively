#!/usr/bin/env python3
"""Exercise production Settings/library preview methods with controlled callbacks."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def closing_brace(source, opening):
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return end


def methods(source, names):
    actual = []
    for name in names:
        match = re.search(r"^    private func " + name + r"\([^\n]*\) [^\n]*\{", source, re.M)
        if not match:
            raise RuntimeError("Missing production preview method: " + name)
        opening = source.index("{", match.start())
        actual.append(source[match.start():closing_brace(source, opening)])
    return "\n".join(actual)


def scene_method(source):
    match = re.search(r"\.onChange\(of: scenePhase\) \{ _, phase in\n", source)
    if not match:
        raise RuntimeError("Missing production scene-phase callback")
    opening = source.index("{", match.start())
    end = closing_brace(source, opening)
    body = source[match.end():end - 1]
    return "    func sceneChanged(_ phase: ScenePhase) {\n" + body + "    }"


def conversation_pause(source):
    match = re.search(r"onPauseForVoicePreview:\s*\{", source)
    if not match:
        raise RuntimeError("Missing conversation preview pause callback")
    opening = source.index("{", match.start())
    body = source[opening + 1:closing_brace(source, opening) - 1]
    return "    func pauseForPreview() {\n" + body + "    }"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    parser.add_argument("--thread-sanitizer", action="store_true")
    args = parser.parse_args()
    settings_source = (ROOT / "Lively/Views/SettingsView.swift").read_text()
    library_source = (ROOT / "Lively/Views/OfflineVoiceLibraryView.swift").read_text()
    settings = methods(settings_source, ["previewVoice", "closeVoicePreview", "stopVoicePreview"])
    library = methods(library_source, ["preview", "stopPreview"])
    pause = conversation_pause((ROOT / "Lively/Views/ConversationScreen.swift").read_text())
    fixture = Path(__file__).with_name("VoicePreviewLifecycleRegression.swift").read_text()
    fixture = fixture.replace("// INSERT_SETTINGS_SCENE", scene_method(settings_source))
    fixture = fixture.replace("// INSERT_LIBRARY_SCENE", scene_method(library_source))
    variants = [("preview-lifecycle", settings, library, pause, True)]
    if args.negative_controls:
        for name, target, old, new in [
            ("settings-entry-cancellation", "settings", "        try Task.checkCancellation()\n        onPauseForVoicePreview()", "        onPauseForVoicePreview()"),
            ("library-precallback-guard", "library", "            guard !Task.isCancelled, previewOperation == token else { return }\n            defer", "            defer"),
            ("library-stale-error", "library", "            catch {\n                guard !Task.isCancelled, previewOperation == token else { return }\n", "            catch {\n"),
            ("settings-stale-status", "settings", "if let preview, voicePreview === preview, voicePreviewOperation == token", "if preview != nil"),
            ("settings-close-invalidates", "settings", "        voicePreviewOperation = UUID()", ""),
        ]:
            actual = settings if target == "settings" else library
            if actual.count(old) != 1:
                raise RuntimeError("Update lifecycle mutation anchor: " + name)
            changed = actual.replace(old, new)
            variants.append((name, changed if target == "settings" else settings,
                             changed if target == "library" else library, pause, False))
        old = "store.speechRoutingDidChange()"
        if pause.count(old) != 1:
            raise RuntimeError("Update conversation pause mutation anchor")
        variants.append(("conversation-tts-not-cancelled", settings, library, pause.replace(old, ""), False))
    with tempfile.TemporaryDirectory(prefix="lively-voice-preview-ui-") as directory:
        work = Path(directory)
        for name, actual_settings, actual_library, actual_pause, positive in variants:
            swift = work / (name + ".swift")
            swift.write_text(fixture.replace("// INSERT_SETTINGS_METHODS", actual_settings)
                             .replace("// INSERT_LIBRARY_METHODS", actual_library)
                             .replace("// INSERT_CONVERSATION_PAUSE", actual_pause))
            binary = work / name
            flags = ["-sanitize=thread"] if args.thread_sanitizer and positive else []
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                            "-parse-as-library", "-module-cache-path", str(work / "modules"), *flags,
                            str(swift), "-o", str(binary)], check=True, timeout=90)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            if positive:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or "Preview lifecycle regression failed")
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
