#!/usr/bin/env python3
"""Exercise production automatic conversation/model paths with controlled services.

The source, target, translated text and output expectations are declared before
running the store. No microphone, provider account, network, or app QA hooks.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

from online_conversation_regression import (
    ROOT, declaration, load_store_fixture, render_store_fixture, shared_store_harness,
)


def changed(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError("Update automatic conversation mutation anchor: " + old)
    return source.replace(old, new)


def changed_method(methods, name, old, new):
    original = declaration(methods, name)
    return changed(methods, original, changed(original, old, new))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    store, methods, models, fixture = load_store_fixture()
    harness = shared_store_harness(fixture)
    tests = Path(__file__).parent
    manual_parser = (ROOT / "Lively/Networking/SonioxTranscriber.swift").read_text().split(
        "\nextension ProviderCredential {")[0]
    automatic_parser = (ROOT / "Lively/Networking/AutomaticSonioxTranscriber.swift").read_text()
    capture = tests / "fixtures/automatic-soniox-one-way.jsonl"
    print("Store source SHA256: " + hashlib.sha256(store.encode()).hexdigest(), flush=True)
    print("Model source SHA256: " + hashlib.sha256(models.encode()).hexdigest(), flush=True)
    print("Automatic parser SHA256: " + hashlib.sha256(automatic_parser.encode()).hexdigest(), flush=True)
    print("Saved one-way capture SHA256: " + hashlib.sha256(capture.read_bytes()).hexdigest(), flush=True)
    variants = [("automatic-conversation", methods, models, True)]
    if args.negative_controls:
        for name, old, new in [
            ("unknown-target-fabricated", "if isAutomatic { return automaticTarget }",
             "if isAutomatic { return automaticTarget ?? languages.second }"),
            ("unknown-source-defaulted-to-listener", "if isAutomatic { return automaticSource }",
             "if isAutomatic { return automaticSource ?? automaticListener }"),
            ("pending-target-rebound", "guard isAutomatic, automaticTarget == nil else { return false }",
             "guard isAutomatic else { return false }"),
            ("third-language-projection-leaks", 'return lang == target ? translation : ""', "return translation"),
            ("translation-target-provenance-ignored", "(isAutomatic && translatedTarget != target)", "false"),
            ("unknown-partner-label-fabricated", "return target.flatMap { $0 != listenerLanguage ? $0 : nil }",
             "return target.flatMap { $0 != listenerLanguage ? $0 : nil } ?? languages.second"),
        ]:
            variants.append((name, methods, changed(models, old, new), False))
        for name, method, old, new in [
            ("short-typed-input-ignores-reader-side", "submitTyped",
             "Language.detect(text, among: Language.soniox) ?? hint",
             "Language.detect(text, among: Language.soniox) ?? listenerLanguage"),
            ("source-only-edit-never-binds-listener", "edit",
             "retryTranslation(utterance)",
             "utterance.isTyped = true\n        utterance.isAutomaticSourceFinal = true\n        utterance.isExplicitTranslationRequest = true\n        utterance.suppressesAutomaticSpeech = false\n        utterance.translatedSource = nil\n        translate(utterance)"),
            ("outgoing-target-from-cached-pair", "applyAutomatic",
             "let target: Language? = nativeTarget",
             "let target: Language? = nativeTarget ?? (language == listenerLanguage ? detectedPartnerLanguage ?? languages.second : nil)"),
            ("raw-foreign-target-fabricated", "applyAutomatic",
             "let target: Language? = nativeTarget",
             "let target: Language? = nativeTarget ?? (language != listenerLanguage ? listenerLanguage : nil)"),
            ("target-only-invents-source", "applyAutomatic",
             "let language = segment.language.flatMap { Language.soniox.contains($0) ? $0 : nil }",
             "let language = segment.language.flatMap { Language.soniox.contains($0) ? $0 : nil } ?? (segment.target == listenerLanguage ? languages.second : nil)"),
            ("provisional-language-selects-partner", "applyAutomatic",
             "segment.languageIsFinal, segment.isSourceFinal,\n           let language, language != listenerLanguage,",
             "segment.isSourceFinal,\n           let language, language != listenerLanguage,"),
            ("local-close-selects-partner", "applyAutomatic",
             "segment.languageIsFinal, segment.isSourceFinal,\n           let language, language != listenerLanguage,",
             "segment.languageIsFinal, segment.isClosed,\n           let language, language != listenerLanguage,"),
            ("catch-up-selects-current-partner", "applyAutomatic",
             "if !segment.isCatchUp, !invalidTarget, segment.isPartnerEvidence,",
             "if !invalidTarget, segment.isPartnerEvidence,"),
            ("contradictory-target-selects-partner", "applyAutomatic",
             "if !segment.isCatchUp, !invalidTarget, segment.isPartnerEvidence,",
             "if !segment.isCatchUp, segment.isPartnerEvidence,"),
            ("raw-snapshot-fabricates-native-target", "applyAutomatic",
             "!invalidLanguage && segment.target == listenerLanguage && language != listenerLanguage",
             "!invalidLanguage && language != listenerLanguage"),
            ("source-empty-output-selects-partner", "applyAutomatic",
             "utterance.trimmedSource.unicodeScalars.contains(where: CharacterSet.letters.contains)", "true"),
            ("shared-word-selects-partner", "applyAutomatic",
             "if (translated.isEmpty || original != translated),", "if true,"),
            ("provisional-native-translation-spoken", "applyAutomatic",
             "Filler.strip(segment.stableTranslation, in: nativeTarget)",
             "Filler.strip(segment.translation, in: nativeTarget)"),
            ("backfill-api-requests-unbounded", "bindPendingAutomaticTurns", ".suffix(3)", ".suffix(99)"),
            ("backfill-chooses-oldest-questions", "bindPendingAutomaticTurns", ".suffix(3)", ".prefix(3)"),
            ("backfill-speaks-after-answer", "bindPendingAutomaticTurns",
             "utterance.suppressesAutomaticSpeech = true", "utterance.suppressesAutomaticSpeech = false"),
            ("provider-source-finality-ignored", "translate",
             "canUseAutomaticTurn(utterance) && utterance.isAutomaticSourceFinal",
             "canUseAutomaticTurn(utterance) && utterance.isFinal"),
            ("headphone-and-speaker-routes-reversed", "speak",
             "output = target == settings.speechListenerLanguage ? .headphones : .speaker",
             "output = target == settings.speechListenerLanguage ? .speaker : .headphones"),
            ("synthesis-language-from-source", "speak",
             "speaker.speak(ready, in: target, output: output)",
             "speaker.speak(ready, in: utterance.language, output: output)"),
            ("legacy-pair-blocks-automatic-speech", "speak", "if utterance.isAutomatic {", "if false {"),
            ("expired-session-work-authorized", "canUseAutomaticTurn",
             "&& (utterance.automaticSessionID == automaticSessionID || utterance.isExplicitTranslationRequest)", "&& true"),
            ("context-never-expires", "expireAutomaticContext", "> 600", "> 60_000"),
            ("clear-keeps-learned-context", "clear", "        resetAutomaticConversation()\n", ""),
            ("retried-native-row-overwritten", "applyAutomatic",
             "guard utterances.contains(where: { $0 === existing }), !existing.isTyped else { return }",
             "guard utterances.contains(where: { $0 === existing }) else { return }"),
            ("replacement-engine-keeps-automatic-ids", "retireNativeSegments",
             "        automaticSegmentUtterances.removeAll()\n", ""),
            ("native-reset-ignores-automatic-live-rows", "failMissingSegmentTranslations",
             "+ Array(automaticSegmentUtterances.values)", ""),
            ("native-reset-ignores-automatic-catchup-rows", "failMissingSegmentTranslations",
             "+ Array(automaticCatchUpUtterances.values)", ""),
            ("native-reset-fails-inflight-text-work", "failMissingSegmentTranslations",
             "utterance.translationState == .working && !utterance.isTyped",
             "utterance.translationState == .working"),
            ("native-retirement-fails-inflight-text-work", "retireNativeSegments",
             "if utterance.translationState == .working, !utterance.isTyped {",
             "if utterance.translationState == .working {"),
            ("partner-evidence-authorization-ignored", "applyAutomatic",
             "!invalidTarget, segment.isPartnerEvidence,", "!invalidTarget,"),
            ("provisional-reply-captures-old-partner", "applyAutomatic",
             "let target: Language? = nativeTarget",
             "let target: Language? = nativeTarget ?? (language == listenerLanguage ? detectedPartnerLanguage : nil)"),
            ("incomplete-reply-binds-current-partner", "applyAutomatic",
             "if resolvedLanguage == listenerLanguage, segment.isSourceFinal,\n               segment.languageIsFinal, let partner = detectedPartnerLanguage {",
             "if resolvedLanguage == listenerLanguage, segment.languageIsFinal, let partner = detectedPartnerLanguage {"),
            ("post-discovery-reply-silenced-as-backfill", "bindPendingAutomaticTurns",
             "&& (preceding.contains($0.id) || $0.isAutomaticSourceFinal)", ""),
            ("one-conflicting-row-switches-partner", "applyAutomatic",
             "pendingPartnerConfirmations >= 2", "pendingPartnerConfirmations >= 1"),
            ("repeated-final-counts-as-new-language-evidence", "applyAutomatic",
             "automaticLanguageEvidence.insert(utterance.id).inserted", "true"),
            ("current-partner-does-not-reset-corroboration", "applyAutomatic",
             "if language == detectedPartnerLanguage {\n                    pendingPartnerLanguage = nil\n                    pendingPartnerConfirmations = 0",
             "if language == detectedPartnerLanguage {\n                    _ = language"),
            ("offline-flap-activates-idle-backlog", "setPath",
             "active.contains(utterance.id) && utterance.needsTranslation", "utterance.needsTranslation"),
            ("automatic-network-loss-uses-classic-bulk-retry", "setPath",
             "if isAutomaticLanguageMode {", "if false {"),
            ("automatic-mode-selects-offline-text-service", "usesOnDeviceServices",
             "!isAutomaticLanguageMode && ", ""),
            ("voice-change-retries-silent-backlog", "offlineSpeakerDidChange",
             "if utterance.isAutomatic {", "if false {"),
            ("late-backlog-final-starts-new-request", "applyAutomatic",
             "if utterance.wasAwaitingPartner && !utterance.isExplicitTranslationRequest {", "if false {"),
            ("unfinished-backlog-loses-silent-classification", "bindPendingAutomaticTurns",
             "utterance.wasAwaitingPartner = true", "utterance.wasAwaitingPartner = false"),
            ("interrupted-source-not-offered-retry", "settleInterruptedAutomaticTurn",
             "guard utterance.isAutomatic, !utterance.isTyped, !utterance.isAutomaticSourceFinal,",
             "guard false, utterance.isAutomatic, !utterance.isTyped, !utterance.isAutomaticSourceFinal,"),
            ("interrupted-foreign-retry-loses-listener-target", "settleInterruptedAutomaticTurn",
             "if source != utterance.listenerLanguage { utterance.bindAutomaticTarget(utterance.listenerLanguage) }",
             "if source != utterance.listenerLanguage { _ = source }"),
            ("native-preview-retraction-ignored", "applyAutomatic",
             "if !hasNativeTranslation, !utterance.translation.isEmpty, !utterance.isTyped {",
             "if false, !hasNativeTranslation, !utterance.translation.isEmpty, !utterance.isTyped {"),
            ("revised-language-inherits-prior-completion", "applyAutomatic",
             "utterance.isAutomaticSourceFinal = false", "utterance.isAutomaticSourceFinal = true"),
            ("unsupported-downloaded-target-disables-speech", "speak",
             "NeuralVoicePacks.shared.selectedVoice(for: target.rawValue)?.languageCode != target.rawValue { return }",
             "NeuralVoicePacks.shared.selectedVoice(for: target.rawValue)?.languageCode != target.rawValue { settings.speaksTranslations = false; return }"),
            ("unsupported-downloaded-target-forwarded-to-synthesis", "speak",
             "NeuralVoicePacks.shared.selectedVoice(for: target.rawValue)?.languageCode != target.rawValue { return }",
             "NeuralVoicePacks.shared.selectedVoice(for: target.rawValue)?.languageCode != target.rawValue { _ = target }"),
            ("volatile-tail-not-offered-explicit-retry", "settleInterruptedAutomaticTurn",
             "guard utterance.isAutomatic, !utterance.isTyped, !utterance.isAutomaticSourceFinal,",
             "guard utterance.hasFinalAutomaticLanguage, utterance.isAutomatic, !utterance.isTyped, !utterance.isAutomaticSourceFinal,"),
            ("cancelled-backfill-left-working", "offlineSpeakerDidChange",
             "for utterance in interruptedBackfill {", "for utterance in interruptedBackfill where false {"),
            ("cancelled-partial-backfill-claims-completion", "offlineSpeakerDidChange",
             ': .failed("Translation interrupted. Tap to retry.")', ': .current'),
            ("completed-typed-after-open-foreign-never-bound", "bindPendingAutomaticTurns",
             "&& (preceding.contains($0.id) || $0.isAutomaticSourceFinal)", "&& preceding.contains($0.id)"),
            ("deleted-active-row-keeps-silence-deadline", "delete",
             "            silenceTimer?.cancel()\n", ""),
        ]:
            variants.append((name, changed_method(methods, method, old, new), models, False))
        old = """engine.onEvent = { [weak self, weak engine] event in
            guard let self, let engine, self.engine === engine else { return }
            self.handle(event)"""
        new = """engine.onEvent = { [weak self, weak engine] event in
            guard let self, let engine else { return }
            _ = engine
            self.handle(event)"""
        variants.append(("obsolete-engine-events-accepted", changed_method(methods, "makeEngine", old, new), models, False))
    with tempfile.TemporaryDirectory(prefix="lively-automatic-conversation-") as directory:
        work = Path(directory)
        manual_file = work / "Soniox.swift"
        manual_file.write_text(manual_parser)
        automatic_file = work / "AutomaticSoniox.swift"
        automatic_file.write_text(automatic_parser)
        for name, actual_store, actual_models, positive in variants:
            source = work / (name + ".swift")
            source.write_text(render_store_fixture(harness, methods=actual_store, models=actual_models))
            binary = work / name
            subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-parse-as-library", "-module-cache-path", str(work / "modules"),
                str(source), str(manual_file), str(automatic_file),
                str(tests / "OnlineProtocolTransport.swift"),
                str(tests / "AutomaticConversationRegression.swift"), "-o", str(binary),
            ], check=True, timeout=90)
            result = subprocess.run([str(binary), str(capture)], capture_output=True, text=True, timeout=30)
            if positive:
                print(result.stdout, end="")
                if result.returncode:
                    raise RuntimeError(result.stderr or result.stdout or "Automatic conversation failed")
            elif result.returncode != 1 or "FAIL:" not in result.stdout:
                raise RuntimeError("Negative control failed without a meaningful assertion: " + name
                                   + "\n" + result.stdout + result.stderr)
            else:
                print("PASS: " + name + " detected deliberate corruption", flush=True)
    if args.negative_controls:
        print("Validated " + str(len(variants) - 1) + " automatic conversation corruption controls.", flush=True)


if __name__ == "__main__":
    main()
