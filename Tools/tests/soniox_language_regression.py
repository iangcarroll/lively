#!/usr/bin/env python3
"""Check actual Soniox token handling without microphone, keys, or network."""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile


def mutated(source, old, new):
    expected = 1
    if source.count(old) != expected:
        raise RuntimeError("Update mutation anchor: " + old)
    return source.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    production = (root / "Lively/Networking/SonioxTranscriber.swift").read_text()
    soniox = production.split("\nextension ProviderCredential {")[0]
    fixture = Path(__file__).with_name("SonioxLanguageRegression.swift").read_text()
    print("Parser source SHA256: " + hashlib.sha256(production.encode()).hexdigest(), flush=True)
    print("Swift fixture SHA256: " + hashlib.sha256(fixture.encode()).hexdigest(), flush=True)
    for marker, source in [
        ("// INSERT_ACTUAL_LANGUAGE", (root / "Lively/Model/Language.swift").read_text()),
        ("// INSERT_ACTUAL_SPEECH_ENGINE", (root / "Lively/Networking/SpeechEngine.swift").read_text()),
    ]:
        fixture = fixture.replace(marker, source)
    variants = [("soniox-language", soniox, True)]
    if args.negative_controls:
        for name, old, new in [
            ("provider-endpoint-ignored", "                closeOpenSegment(&state, providerBoundary: true)\n", ""),
            ("punctuation-relabels-source", 'meaningful(text) ? configuredLanguage(token["language"] as? String) : nil',
             'configuredLanguage(token["language"] as? String)'),
            ("translation-metadata-ignored", "segment.language = source", "_ = source"),
            ("provisional-translation-spoken",
             'let stable = translationSource == language ? (stableTranslation ?? translation) : ""',
             "let stable = translation"),
            ("unknown-source-exposed", "guard segment.language != nil else { return false }", ""),
            ("foreign-source-deleted", "            } else {\n                openSegmentIfNeeded(&state)",
             '            } else {\n                guard configuredLanguage(token["language"] as? String) != nil else { continue }\n                openSegmentIfNeeded(&state)'),
            ("foreign-translation-target-accepted",
             "if let targetCode, !targetCode.isEmpty, target == nil { return nil }", ""),
            ("same-language-translation-accepted", "return source != target ? source : nil", "return source"),
            ("local-timeout-discards-provider-turn", "            state.open = segment\n            streams[id] = state",
             "            state.open = nil\n            streams[id] = state"),
            ("mixed-tags-pick-first-language", "languages.count == 1 ? languages.first : nil", "languages.first"),
            ("stable-speech-direction-changed",
             "segment.language = segment.translationSource ?? sourceLanguage(segment.sourceLanguages)",
             "segment.language = sourceLanguage(segment.sourceLanguages)"),
            ("empty-token-withdrawal-ignored", "!tokens.isEmpty || streams[stream.id]?.open != nil", "!tokens.isEmpty"),
            ("preview-language-forgotten", "state.open?.lastShownLanguage = segment.language", "_ = segment.language"),
            ("preview-overlay-forgotten",
             "state.open?.hasProvisionalOverlay = !pendingSource.isEmpty || pendingTranslationSource != nil",
             "state.open?.hasProvisionalOverlay = false"),
            ("remembered-side-classifies-unknown-source", 'confirmed.source = ""', ""),
            ("preview-close-skipped", "if notify { emitConfirmedOrRetract(segment, isCatchUp: state.isCatchUp) }",
             "if notify { emit(segment, isCatchUp: state.isCatchUp) }"),
            ("local-preview-close-skipped", "emitConfirmedOrRetract(segment, isCatchUp: false)",
             "emit(segment, isCatchUp: false)"),
            ("confirmed-correction-language-forgotten",
             "state.open?.lastShownLanguage = confirmed.language ?? confirmed.lastShownLanguage",
             "_ = confirmed.language"),
            ("opposite-final-direction-dropped", "if let current = segment.translationSource, current != source {",
             "if let current = segment.translationSource, current != source {\n                    continue"),
            ("clean-deferred-originals-dropped", "let reply = segment.deferredSource", "let reply: [SourcePiece] = []"),
            ("first-delayed-direction-not-partitioned", "if segment.translationSource == nil { deferTrailingSource(&segment, for: source) }", ""),
            ("new-direction-reuses-old-id", "segment = Segment(id: nextSegmentID)", "segment = Segment(id: segment.id)"),
            ("endpoint-drops-embedded-name", "        foldDeferredSource(&segment)\n        segment.isClosed = true",
             "        segment.isClosed = true"),
            ("source-continuation-drops-name", "                foldDeferredSource(&segment)\n            } else if",
             "            } else if"),
            ("real-fold-provenance-forgotten", "if foldedName, segment.unreceiptedFoldStart == nil {",
             "if foldedName && false, segment.unreceiptedFoldStart == nil {"),
            ("ordinary-continuation-marked-as-fold", "if foldedName, segment.unreceiptedFoldStart == nil {",
             "if foldedName || true, segment.unreceiptedFoldStart == nil {"),
            ("clean-reply-withheld-until-end", "if segment.unreceiptedFoldStart != nil || !matchingDeferred {",
             "if true {"),
            ("folded-original-provenance-rejected", "guard meaningful(caption.source) else { return }",
             "guard segment.deferredSource.contains(where: { meaningful($0.text) }) else { return }"),
            ("orphan-translation-creates-source-free-epoch", "guard var segment = state.open, !segment.source.isEmpty,",
             "guard var segment = Optional(state.open ?? Segment(id: nextSegmentID)),"),
            ("unknown-translation-source-accepted", "if let sourceCode, !sourceCode.isEmpty, source == nil { return nil }", ""),
            ("ambiguous-source-ledger-disabled", "let ambiguous = containsReturn && last >= 0 && sentenceStart != firstOpposite", "let ambiguous = false"),
            ("ambiguous-partition-guessed", "guard matches.count == 1 else {", "guard !matches.isEmpty else {"),
            ("formatting-confirms-direction", "meaningful(text) || source == segment.pendingTranslations.last?.source\n                        || source == segment.translationSource", "true"),
            ("translation-only-directions-dropped", "for translation in segment.pendingTranslations {",
             "for translation in segment.pendingTranslations.prefix(0) {"),
            ("translation-only-speech-stability-lost", "translated.translationSource = translation.source",
             "translated.translationSource = nil"),
            ("translation-only-output-reversed", "translated.language = translation.source",
             "translated.language = config.languages.other(than: translation.source)"),
        ]:
            variants.append((name, mutated(soniox, old, new), False))
    with tempfile.TemporaryDirectory(prefix="lively-soniox-language-") as directory:
        work = Path(directory)
        for name, actual, positive in variants:
            source = work / (name + ".swift")
            source.write_text(fixture.replace("// INSERT_ACTUAL_SONIOX", actual))
            binary = work / name
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-parse-as-library", "-module-cache-path", str(work / "modules"),
                str(source), "-o", str(binary),
            ], check=True, timeout=90)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            summary = re.search(r"Soniox language regressions: (\d+) checks, (\d+) failures", result.stdout)
            if positive:
                print(result.stdout, end="")
                if result.returncode or summary is None or int(summary[2]) != 0:
                    raise RuntimeError(result.stderr or result.stdout or "Soniox language regression failed")
            elif result.returncode != 1 or "FAIL:" not in result.stdout or summary is None or int(summary[2]) == 0:
                raise RuntimeError("Negative control was not detected: " + name + "\n"
                                   + result.stdout + result.stderr)
            else:
                print("PASS: " + name + " detected deliberate corruption (" + summary[2] + " failed assertions)", flush=True)
    print("Validated " + str(len(variants) - 1) + " corruption controls.", flush=True)


if __name__ == '__main__':
    main()
