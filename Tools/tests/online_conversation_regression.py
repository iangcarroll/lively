#!/usr/bin/env python3
"""Compile actual store/model paths with controlled speech, translation and audio.

The service-token parser and real socket lifecycle have separate regressions.
This suite checks the resulting side, translation direction and output route,
plus cold/warm startup and stale callbacks without a phone or cloud account.
"""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def declaration(source, name):
    match = re.search(r"^    (?:private |static )?(?:func|var) " + re.escape(name)
                      + r"(?=[(: ])[^\n]*\{", source, re.M)
    if not match:
        raise RuntimeError("Missing production declaration: " + name)
    opening = source.index("{", match.start())
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end]


def load_store_fixture():
    """Read the production paths shared by store and protocol integration tests."""
    store = (ROOT / "Lively/Model/ConversationStore.swift").read_text()
    names = ["makeEngine", "startEngine", "sourceChanged", "canFallBackToOnDevice",
             "handle", "apply", "applyCatchUp", "show", "convertScript",
             "armSilenceFallback", "finalizeCurrent", "scheduleTranslation", "translate",
             "speak", "activeSpeaker", "completeSentences", "after", "usesOnDeviceServices",
             "discardPendingIfReady", "discardProvisionalTurns", "boundaryDelay",
             "invalidateTranslation", "finalizeStoppedTurn", "visibleUtterances", "retryTranslation",
             "synchronizeLanguages", "clear", "releaseEngine",
             "finishAbandonedTranslation", "failMissingSegmentTranslations", "delete", "retireNativeSegments",
             "offlineSpeakerDidChange", "speechRoutingDidChange", "isAutomaticLanguageMode", "listenerLanguage",
             "resetAutomaticConversation", "expireAutomaticContext", "applyAutomatic", "bindPendingAutomaticTurns",
             "canUseAutomaticTurn", "settleInterruptedAutomaticTurn", "setPath", "submitTyped", "edit"]
    methods = "\n".join(declaration(store, name) for name in names)
    fixture = Path(__file__).with_name("OnlineConversationRegression.swift").read_text()
    models = "\n".join((ROOT / name).read_text() for name in [
        "Lively/Model/Language.swift", "Lively/Model/Filler.swift", "Lively/Model/Utterance.swift",
        "Lively/Networking/SpeechEngine.swift", "Lively/Networking/TranslationSpeaker.swift"])
    return store, methods, models, fixture


def shared_store_harness(fixture):
    """Keep the controlled service boundaries and actual store, without test entry."""
    marker = "// END_SHARED_STORE_HARNESS"
    if fixture.count(marker) != 1:
        raise RuntimeError("Expected one shared store harness boundary")
    return fixture.split(marker, 1)[0]


def render_store_fixture(fixture, *, methods, models):
    for marker, source in [("// INSERT_ACTUAL_MODELS", models),
                           ("// INSERT_ACTUAL_STORE_METHODS", methods)]:
        if fixture.count(marker) != 1:
            raise RuntimeError("Expected one source marker: " + marker)
        fixture = fixture.replace(marker, source)
    return fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    parser.add_argument("--case", choices=["pair", "missing", "catch-up", "replay-cutoff", "filler", "engine-retirement", "native-flush", "settings-restart", "preview-retraction", "translation-only"],
                        help="Run one architecture-review scenario while developing a fix")
    args = parser.parse_args()
    if args.case and args.negative_controls:
        parser.error("negative controls require the complete suite")
    store, methods, models, fixture = load_store_fixture()
    print("Store source SHA256: " + hashlib.sha256(store.encode()).hexdigest(), flush=True)
    variants = [("online-conversation", methods, models, True)]
    if args.negative_controls:
        for name, old, new in [
            ("warm-hybrid-discarded", "!engineIsStale {", "!engineIsStale, !(engine is HybridSpeechEngine) {"),
            ("obsolete-engine-callbacks-accepted", "self.engine === engine", "true"),
            ("online-fixed-language-fallback", "isListening && !isOnline &&", "isListening &&"),
            ("source-label-ignored", "segment.language.flatMap { languages.contains($0) ? $0 : nil }", "Optional(languages.first)"),
            ("all-translations-public", "output = target == settings.speechListenerLanguage ? .headphones : .speaker", "output = .speaker"),
            ("stalled-direction-not-cancelled", "translations.removeValue(forKey: utterance.id)?.cancel()", "_ = utterance.id"),
            ("raw-pause-finalized-early", "engine?.drainsTextOnPause == true", "false"),
            ("label-correction-cancels-other-speech", "spoken.removeValue(forKey: utterance.id)", "spoken.removeValue(forKey: utterance.id)\n        speaker?.stop()"),
            ("short-segment-replay-retained", "complete || length >= 10", "length >= 10"),
            ("startup-catch-up-uses-old-position", "dropoutIndex = utterances.count", "dropoutIndex = 0"),
            ("replay-cutoff-moves-with-response", "let cutoff = pendingDiscardCutoff ?? Date().addingTimeInterval(-replayed)",
             "let cutoff = Date().addingTimeInterval(-replayed)"),
            ("replay-removal-keeps-stale-index", "self.dropoutIndex = max(0, dropoutIndex - removedBefore)",
             "self.dropoutIndex = dropoutIndex"),
            ("filler-object-detached-at-stop", "if !segmentUtterances.values.contains(where: { $0 === utterance }) {", "if true {"),
            ("retired-native-translation-never-recoverable", "finishAbandonedTranslation(older)", "_ = older"),
            ("unconfirmed-native-language-invented", "segment.language.map { languages.contains($0) } == true", "true"),
        ]:
            if old not in methods:
                raise RuntimeError("Update mutation anchor: " + old)
            variants.append((name, methods.replace(old, new), models, False))
        old = "translatedSource != trimmedSource || translatedLanguage != sourceLanguage"
        if old not in models:
            raise RuntimeError("Update translation-language mutation anchor")
        variants.append(("translation-language-ignored", methods, models.replace(old, "translatedSource != trimmedSource"), False))
        for name, method in [("onboarding-pair-not-synchronized", "synchronizeLanguages"),
                             ("reset-leaves-missing-translation-working", "failMissingSegmentTranslations"),
                             ("native-retry-has-no-text-service", "retryTranslation")]:
            actual = declaration(store, method)
            if method == "retryTranslation":
                if "utterance.isTyped = true" not in actual:
                    raise RuntimeError("Update native retry mutation anchor")
                broken = actual.replace("utterance.isTyped = true", "utterance.isTyped = false")
            else:
                broken = actual[:actual.index("{") + 1] + "}"
            variants.append((name, methods.replace(actual, broken), models, False))
        for name, method, old, new in [
            ("fresh-engine-keeps-native-ids", "makeEngine", "        retireNativeSegments()\n", ""),
            ("hard-release-keeps-native-ids", "releaseEngine", "        retireNativeSegments()\n",
             "        finalizeCurrent()\n        failMissingSegmentTranslations()\n"),
            ("retirement-keeps-catch-up-ids", "retireNativeSegments", "        catchUpUtterances.removeAll()", ""),
            ("retirement-drops-visible-history", "retireNativeSegments", "let hidden = utterances.filter { !$0.hasContent }", "let hidden = utterances"),
            ("retirement-keeps-hidden-objects", "retireNativeSegments", "let hidden = utterances.filter { !$0.hasContent }", "let hidden: [Utterance] = []"),
            ("retirement-index-stays-stale", "retireNativeSegments", "self.dropoutIndex = max(0, dropoutIndex - removedBefore)", "self.dropoutIndex = dropoutIndex"),
            ("warm-resume-retires-active-ids", "startEngine", "        synchronizeLanguages()", "        synchronizeLanguages()\n        retireNativeSegments()"),
            ("deleted-segment-update-resurrects", "delete", "        utterances.remove(at: index)",
             "        utterances.remove(at: index)\n        segmentUtterances = segmentUtterances.filter { $0.value !== utterance }\n        catchUpUtterances = catchUpUtterances.filter { $0.value !== utterance }"),
            ("native-flush-seals-future-words", "apply", ", completesTurn: false", ""),
            ("native-flush-loses-completion-policy", "speak", "complete: true, completesTurn: completesTurn", "complete: true, completesTurn: true"),
            ("raw-completion-never-seals", "speak", "spoken[utterance.id] = completesTurn ? Int.max : sent + ready.count", "spoken[utterance.id] = sent + ready.count"),
            ("settings-restart-waits-on-missing-translator", "offlineSpeakerDidChange",
             "} else { retryTranslation(utterance) }",
             "} else { translate(utterance) }"),
            ("empty-live-preview-detaches", "apply", "            if current === utterance { finalizeCurrent() } else { utterance.isFinal = true }",
             "            if current === utterance { finalizeCurrent() } else { utterance.isFinal = true }\n            if !utterance.hasContent { utterances.removeAll { $0 === utterance } }"),
            ("empty-catch-up-preview-detaches", "applyCatchUp", "        utterance.isFinal = segment.isClosed",
             "        utterance.isFinal = segment.isClosed\n        if segment.isClosed && !utterance.hasContent { utterances.removeAll { $0 === utterance } }"),
            ("retirement-only-prunes-mapped-hidden-rows", "retireNativeSegments", "let hidden = utterances.filter { !$0.hasContent }",
             "let hidden = (Array(segmentUtterances.values) + Array(catchUpUtterances.values)).filter { !$0.hasContent }"),
            ("empty-source-live-translation-rejected", "apply",
             "|| (segment.language.map { languages.contains($0) } == true\n                    && !segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)", "|| false"),
            ("empty-source-catch-up-translation-rejected", "applyCatchUp",
             "|| (segment.language.map { languages.contains($0) } == true\n                    && !segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)", "|| false"),
            ("translation-only-source-fabricated", "show", "let source = segment.source.trimmingLeadingWhitespace()",
             "let source = segment.source.isEmpty ? \"Unknown source\" : segment.source.trimmingLeadingWhitespace()"),
        ]:
            actual = declaration(store, method)
            if old not in actual:
                raise RuntimeError("Update Store mutation anchor: " + name)
            variants.append((name, methods.replace(actual, actual.replace(old, new, 1)), models, False))
        actual = declaration(models, "hasContent")
        for name, broken in [
            ("translation-only-model-hidden", "    var hasContent: Bool { !trimmedSource.isEmpty }"),
            ("translated-filler-becomes-visible", "    var hasContent: Bool { !trimmedSource.isEmpty || !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }"),
            ("raw-stale-translation-resurrects", "    var hasContent: Bool { !trimmedSource.isEmpty || (source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }"),
        ]:
            variants.append((name, methods, models.replace(actual, broken), False))
    with tempfile.TemporaryDirectory(prefix="lively-online-store-") as directory:
        work = Path(directory)
        for name, actual, source, positive in variants:
            swift = work / (name + ".swift")
            swift.write_text(render_store_fixture(fixture, models=source, methods=actual))
            binary = work / name
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                            "-parse-as-library", "-module-cache-path", str(work / "modules"),
                            str(swift), "-o", str(binary)], check=True, timeout=90)
            result = subprocess.run([str(binary)] + ([args.case] if args.case else []),
                                    capture_output=True, text=True, timeout=30)
            if positive:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or result.stdout or "Online conversation failed")
            elif result.returncode == 0 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control was not detected: " + name + "\n" + result.stdout + result.stderr)
            else:
                print("PASS: " + name + " detected deliberate corruption")


if __name__ == "__main__":
    main()
