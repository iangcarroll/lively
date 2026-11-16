#!/usr/bin/env python3
"""Replay the production automatic parser without microphone, keys or network.

Each corruption is compiled separately. A control counts only when the complete
Swift assertion fixture finishes with failed assertions, never a compiler error
or a runtime trap. The saved one-way input is a repository-owned service capture.
"""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TESTS = Path(__file__).parent


def changed(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError("Update automatic parser mutation anchor: " + old)
    return source.replace(old, new)


def variants(source, negative_controls):
    result = [("automatic-soniox", source, True)]
    if not negative_controls:
        return result
    for name, old, new in [
        ("cached-pair-language-hints", '"enable_language_identification": true,',
         '"enable_language_identification": true,\n                    "language_hints": ["en", "zh"],'),
        ("language-identification-disabled", '"enable_language_identification": true,',
         '"enable_language_identification": false,'),
        ("one-way-replaced-with-fixed-pair", '"type": "one_way",', '"type": "two_way",'),
        ("listener-target-hardcoded-english", '"target_language": config.listenerLanguage.rawValue,',
         '"target_language": "en",'),
        ("microphone-format-mismatched", '"sample_rate": Int(MicCapture.sampleRate),', '"sample_rate": 8000,'),
        ("raw-outgoing-target-from-cached-default", 'languageIsFinal: finalLanguage, target: fallback ? config.listenerLanguage : nil,',
         'languageIsFinal: finalLanguage, target: fallback ? config.listenerLanguage : Language.chinese,'),
        ("raw-foreign-target-before-native-evidence", 'languageIsFinal: finalLanguage, target: fallback ? config.listenerLanguage : nil,',
         'languageIsFinal: finalLanguage, target: group.kind == .foreign ? config.listenerLanguage : nil,'),
        ("native-target-reversed-to-source", 'segment.target = config.listenerLanguage\n            segment.translation = native.text',
         'segment.target = native.language ?? config.listenerLanguage\n            segment.translation = native.text'),
        ("foreign-native-output-dropped", 'for native in epoch.native {', 'for native in epoch.native.prefix(0) {'),
        ("late-native-suffix-gets-new-id", 'if let last = epoch.native.indices.last, epoch.native[last].language == source {',
         'if let last = epoch.native.indices.last, epoch.native[last].language == source && false {'),
        ("wrong-native-target-accepted", 'if let target = language(token["language"]), target != config.listenerLanguage { return }', ''),
        ("identity-translation-echoes-user", 'if source == config.listenerLanguage { return }', ''),
        ("translation-without-original-provenance", 'guard epoch.source.contains(where: { meaningful($0.text) }) else { return }', ''),
        ("formatting-only-translation-starts-run", 'guard meaningful(text) else {', 'if false {'),
        ("local-close-becomes-provider-final", 'epoch.locallyClosed = true\n            render(&epoch, preview: [], closed: true, sourceFinal: false, evidence: false)',
         'epoch.locallyClosed = true\n            render(&epoch, preview: [], closed: true, sourceFinal: true, evidence: true)'),
        ("catch-up-confirms-current-partner", 'sourceFinal && evidence && !epoch.isCatchUp && finalLanguage && native.explicitLanguage',
         'sourceFinal && evidence && finalLanguage && native.explicitLanguage'),
        ("provider-endpoint-not-final", 'render(&epoch, preview: [], closed: true, sourceFinal: true, evidence: true)',
         'render(&epoch, preview: [], closed: true, sourceFinal: false, evidence: true)'),
        ("provider-boundary-keeps-old-source-epoch", 'epoch = Epoch(isCatchUp: epoch.isCatchUp)', ''),
        ("uncorroborated-source-selects-partner", '&& group.kind == .foreign && corroborated', '&& group.kind == .foreign'),
        ("provisional-native-text-made-stable", 'segment.translation += text\n            desired[id] = segment',
         'segment.translation += text\n            segment.stableTranslation += text\n            desired[id] = segment'),
        ("provisional-language-made-final", 'segment.languageIsFinal = segment.languageIsFinal && !segment.source.isEmpty',
         'segment.languageIsFinal = true'),
        ("empty-frame-withdrawal-ignored", '!tokens.isEmpty || streams[stream.id]?.hasContent == true', '!tokens.isEmpty'),
        ("withdrawn-hypothesis-ghost-retained", '            onEvent(.autoSegment(cleared))\n', ''),
        ("local-close-discards-accepted-source", '            streams[id] = epoch\n', '            streams[id] = nil\n'),
        ("embedded-name-not-folded", 'if previous.kind == following.kind,', 'if previous.kind == following.kind, false,'),
        ("foreign-sentence-language-switch-merged", '&& piece.language != coherentLanguage(previous)', '&& false'),
        ("unsupported-code-assumed-listener", 'guard let code, Language.soniox.contains(Language(code)) else { return nil }',
         'guard let code, Language.soniox.contains(Language(code)) else { return config.listenerLanguage }'),
        ("target-only-invents-foreign-source", 'let known = Set(groups(epoch.source).filter { $0.kind == .foreign }.compactMap(coherentLanguage))\n        return known.count == 1 ? known.first : nil',
         'let known = Set(groups(epoch.source).filter { $0.kind == .foreign }.compactMap(coherentLanguage))\n        return known.count == 1 ? known.first : Language.chinese'),
        ("regional-language-tag-not-normalized", 'let code = raw.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(\n            String.init)',
         'let code = Optional(raw)'),
        ("different-streams-reuse-provider-local-ids", 'var state = streams[stream.id] ?? Epoch(isCatchUp: stream.isCatchUp)',
         'if streams[stream.id] == nil { nextSegmentID = 0 }\n            var state = streams[stream.id] ?? Epoch(isCatchUp: stream.isCatchUp)'),
        ("catchup-source-language-tied-to-live-evidence", 'lang != nil && fixed.flatMap(coherentLanguage) == lang',
         'lang != nil && !epoch.isCatchUp && fixed.flatMap(coherentLanguage) == lang'),
        ("coherent-prefix-requires-provider-endpoint", 'lang != nil && fixed.flatMap(coherentLanguage) == lang',
         'sourceFinal && lang != nil && fixed.flatMap(coherentLanguage) == lang'),
        ("volatile-source-suffix-marked-final", 'lang != nil && fixed.flatMap(coherentLanguage) == lang\n                && group.pieces.count == fixed?.pieces.count', 'lang != nil && fixed.flatMap(coherentLanguage) == lang'),
        ("reset-close-pretends-provider-final", 'guard var epoch = streams[stream] else { return }\n        render(&epoch, preview: [], closed: true, sourceFinal: false, evidence: false)',
         'guard var epoch = streams[stream] else { return }\n        render(&epoch, preview: [], closed: true, sourceFinal: true, evidence: false)'),
        ("repeated-foreign-answer-grows-first-row", 'if !isMeaningful || !followedBySource || !nativeSentenceIsComplete(epoch.native[last].text) {\n                return (last, nil)\n            }',
         'return (last, nil)'),
        ("new-native-anchor-always-first", 'return (nil, candidates.count == 1 ? candidates[0].anchor : nil)',
         'return (nil, originals.first(where: { $0.kind == .foreign })?.anchor)'),
        ("unfinished-native-sentence-split-after-listener", '|| !nativeSentenceIsComplete(epoch.native[last].text)', ''),
        ("native-boundary-uses-source-punctuation", 'ConversationStore.completeSentences(in: trimmed) == trimmed', 'endsSentence(trimmed)'),
        ("native-boundary-accepts-partial-ready-prefix", 'ConversationStore.completeSentences(in: trimmed) == trimmed', '!ConversationStore.completeSentences(in: trimmed).isEmpty'),
        ("leading-native-formatting-dropped", 'sourceAnchor: anchor, text: leading + text', 'sourceAnchor: anchor, text: text'),
        ("native-boundary-skips-actual-filler-normalization", 'Filler.strip(text, in: config.listenerLanguage)', 'text'),
    ]:
        result.append((name, changed(source, old, new), False))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    automatic = (ROOT / "Lively/Networking/AutomaticSonioxTranscriber.swift").read_text()
    manual = (ROOT / "Lively/Networking/SonioxTranscriber.swift").read_text().split(
        "\nextension ProviderCredential {")[0]
    fixture = (TESTS / "AutomaticSonioxRegression.swift").read_text()
    store = (ROOT / "Lively/Model/ConversationStore.swift").read_text()
    helper_start = store.index("    static func completeSentences(")
    helper_end = store.index("\n    // MARK: - Status", helper_start)
    sentence_helper = "enum ConversationStore {\n" + store[helper_start:helper_end] + "\n}\ntypealias ActualSentenceHelper = ConversationStore\n"
    capture = TESTS / "fixtures/automatic-soniox-one-way.jsonl"
    print("Automatic parser SHA256: " + hashlib.sha256(automatic.encode()).hexdigest(), flush=True)
    print("Swift fixture SHA256: " + hashlib.sha256(fixture.encode()).hexdigest(), flush=True)
    print("Saved one-way capture SHA256: " + hashlib.sha256(capture.read_bytes()).hexdigest(), flush=True)
    for marker, text in [
        ("// INSERT_ACTUAL_LANGUAGE", (ROOT / "Lively/Model/Language.swift").read_text()),
        ("// INSERT_ACTUAL_SPEECH_ENGINE", (ROOT / "Lively/Networking/SpeechEngine.swift").read_text()),
        ("// INSERT_ACTUAL_MANUAL", manual),
        ("// INSERT_ACTUAL_SENTENCE_HELPER", sentence_helper),
        ("// INSERT_ACTUAL_FILLER", (ROOT / "Lively/Model/Filler.swift").read_text()),
    ]:
        if fixture.count(marker) != 1:
            raise RuntimeError("Update automatic parser fixture marker: " + marker)
        fixture = fixture.replace(marker, text)
    if fixture.count("// INSERT_ACTUAL_AUTOMATIC") != 1:
        raise RuntimeError("Update automatic parser source marker")
    actual_variants = variants(automatic, args.negative_controls)
    baseline_checks = None
    with tempfile.TemporaryDirectory(prefix="lively-automatic-soniox-") as directory:
        work = Path(directory)
        for name, actual, positive in actual_variants:
            source = work / (name + ".swift")
            source.write_text(fixture.replace("// INSERT_ACTUAL_AUTOMATIC", actual))
            binary = work / name
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-parse-as-library", "-module-cache-path", str(work / "modules"), str(source), "-o", str(binary),
            ], check=True, timeout=90)
            completed = subprocess.run([str(binary), str(capture)], capture_output=True, text=True, timeout=30)
            summary = re.search(r"Automatic Soniox regression: (\d+) checks, (\d+) failures", completed.stdout)
            if positive:
                print(completed.stdout, end="", flush=True)
                if completed.returncode or summary is None or int(summary[2]) != 0:
                    raise RuntimeError(completed.stderr or completed.stdout or "Automatic parser baseline failed")
                baseline_checks = int(summary[1])
            elif (completed.returncode != 1 or "FAIL:" not in completed.stdout or summary is None
                  or int(summary[1]) != baseline_checks or int(summary[2]) == 0):
                raise RuntimeError("Control did not complete with assertion failures: " + name
                                   + "\n" + completed.stdout + completed.stderr)
            else:
                print("PASS: " + name + " detected deliberate corruption (" + summary[2] + " failed assertions)", flush=True)
    if args.negative_controls:
        print("Validated " + str(len(actual_variants) - 1) + " automatic parser corruption controls.", flush=True)


if __name__ == "__main__":
    main()
