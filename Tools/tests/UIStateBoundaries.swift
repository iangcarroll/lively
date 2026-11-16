// Controlled boundaries for the standalone UI test host only.
// Actual production views and Utterance are copied by the runner.
// Speech, translation, audio and unrelated controls are not exercised here.

import SwiftUI
import Observation
@Observable final class AppSettings {
 static let shared = AppSettings()
 var usesAutomaticLanguageDetection = true
 var speechListenerLanguage = Language.english
 var languages = LanguagePair.default
 var chineseScript = ChineseScript.simplified
}
@Observable final class ConversationStore {
 enum ConnectionStatus: Equatable { case idle, connecting, live, reconnecting, offline, failed(String) }
 var utterances: [Utterance] = []
 var visibleUtterances: [Utterance] { utterances.filter(\.hasContent) }
 var isAutomaticLanguageMode = true
 var listenerLanguage = Language.english
 var detectedPartnerLanguage: Language? = Language("ja")
 var isListening = true
 var status = ConnectionStatus.live
 var isUsingOnDevice = false
 var isOnline = true
 var isConnecting = false
 var level: Float = 0
 var isHearing = false
 var retryCount = 0
 init() { select("Failed") }
 func select(_ name: String) {
  retryCount = 0
  detectedPartnerLanguage = name == "Unknown" || name == "Closed unknown" ? nil : Language("ja")
  let own = name == "Known live" || name == "Unknown"
  let noSource = name == "Closed unknown"
  let source = noSource ? "unresolved source words" : own ? "Could you help me find the platform?" : "駅はどこですか？"
  let u = Utterance(automaticSource: source, language: noSource ? nil : own ? .english : Language("ja"), target: own || name == "Source only" || noSource ? nil : .english, listenerLanguage: .english, sessionID: UUID())
  u.isFinal = !own
  u.waitsForAutomaticPartner = name == "Unknown"
  switch name {
   case "Failed": u.translationState = .failed("Controlled unavailable translation")
   case "Network": u.translationState = .waitingForNetwork
   case "Known live", "Unknown", "Closed unknown": u.translationState = .awaitingPartner
   default: u.translationState = .idle
  }
  utterances = [u]
 }
 func retryTranslation(_ u: Utterance) { retryCount += 1 }
 func clear() { utterances.removeAll() }
 func toggleListening() {}
 func startListening() {}
 func stopListening() {}
}
struct StatusPill: View {
    let status: ConversationStore.ConnectionStatus
    let isListening: Bool
    var compact = false
    var onDevice = false
    var body: some View { EmptyView() }
}
struct GlassIconButton: View {
    let systemImage: String
    let label: String
    var isOn: Bool? = nil
    let action: () -> Void
    static let size: CGFloat = 40
    var body: some View { EmptyView() }
}
struct MicButton: View {
    let isListening: Bool
    let level: Float
    let isHearing: Bool
    let action: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    var body: some View { EmptyView() }
}
struct SpeakAloudToggle: View {
    let store: ConversationStore
    var body: some View { EmptyView() }
}
struct TypeToTranslateBar: View {
    init(store: ConversationStore, languages: LanguagePair?, language: Language,
         editing: Binding<Utterance?>, focused: FocusState<Bool>.Binding,
         onClose: @escaping () -> Void) {}
    var body: some View { EmptyView() }
}
