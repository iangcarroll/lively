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
 var streamCount = 0
 var isStreaming = false
 @ObservationIgnored private var streamingTask: Task<Void, Never>?
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
 func delete(_ utterance: Utterance) { utterances.removeAll { $0.id == utterance.id } }
 func populateHistory() {
  isListening = true
  status = .live
  detectedPartnerLanguage = Language("ja")
  utterances = (1...24).map { historyTurn($0) }
 }
 func appendHistory() { utterances.append(historyTurn(utterances.count + 1)) }
 // Both strings have 14 characters; wider glyphs change wrapping without an
 // ID change or a character-count change, like a live transcript revision.
 func reviseHistory() { utterances.last?.translation = "WWW WWW WWWWWW" }
 func streamHistory() {
  streamingTask?.cancel()
  guard let row = utterances.last else { return }
  streamingTask = Task { [weak self, row] in
   // Let menu dismissal finish before updates begin, so XCTest can inspect
   // actual row frames while production rendering is still changing.
   do { try await Task.sleep(for: .seconds(1)) } catch { return }
   guard let self else { return }
   row.translation = "Streaming turn "
   streamCount = 0
   isStreaming = true
   defer { isStreaming = false }
   for index in 1...480 {
    guard !Task.isCancelled else { return }
    row.translation += "word "
    streamCount = index
    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
   }
  }
 }
 func stopStreaming() { streamingTask?.cancel(); streamingTask = nil; isStreaming = false }
 private func historyTurn(_ index: Int) -> Utterance {
  let row = Utterance(automaticSource: "最新の発言 \(index)", language: Language("ja"), target: .english,
                      listenerLanguage: .english, sessionID: UUID())
  row.translation = "Latest turn \(index)"
  row.translationState = .current
  row.isFinal = true
  return row
 }
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
    @State private var text = ""
    var focused: FocusState<Bool>.Binding
    init(store: ConversationStore, languages: LanguagePair?, language: Language,
         editing: Binding<Utterance?>, focused: FocusState<Bool>.Binding,
         onClose: @escaping () -> Void) { self.focused = focused }
    var body: some View {
        TextField("Fixture text input", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused(focused)
            .onAppear { focused.wrappedValue = true }
    }
}
