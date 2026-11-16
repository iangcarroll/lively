// Standalone test app; never included in the Lively target.
import SwiftUI
@main struct StateFixtureApp: App {
 var body: some Scene { WindowGroup { StateFixtureView() } }
}
struct StateFixtureView: View {
 @State private var store = ConversationStore()
 @State private var near = Language.english
 @State private var listenerNear = true
 @State private var editing: Utterance?
 @State private var prompt = ListeningPromptVisibility()
 @State private var largeText = false
 @State private var dark = false
 @State private var layout = "Face"
 @State private var showsTextInput = false
 @FocusState private var focused: Bool
 var body: some View {
  VStack(spacing: 0) {
   ScrollView(.horizontal) {
    HStack { ForEach(["Failed", "Network", "Known live", "Unknown", "Source only", "Closed unknown"], id: \.self) { name in Button(name) { store.select(name) } } }.padding(8)
   }.frame(height: 44)
   HStack {
    Text("Retries: \(store.retryCount)").font(.caption)
    if store.isStreaming {
     Text("Streaming \(store.streamCount)").font(.caption)
      .accessibilityIdentifier("Fixture streaming progress")
    }
    Spacer()
    Menu("Fixture") {
     Button("Load history") { store.populateHistory(); prompt.setActive(false); prompt.setActive(true) }
     Button("Append turn") { store.appendHistory() }
     Button("Revise latest") { store.reviseHistory() }
     Button("Stream latest") { store.streamHistory() }
     ForEach(["Face", "Chat", "Parallel"], id: \.self) { name in
      Button(name + " layout") { layout = name }
     }
     Button("Keyboard") { showsTextInput.toggle(); if !showsTextInput { focused = false } }
    }.font(.caption)
   }.padding(.horizontal, 8)
   HStack {
    Button("Start reminder") { store.isListening = true; prompt.setActive(false); prompt.setActive(true) }
    Button("Stop reminder") { store.isListening = false; prompt.setActive(false) }
    Button("Large text") { largeText.toggle() }
    Button("Dark") { dark.toggle() }
   }.font(.caption).buttonStyle(.bordered)
   conversation
    .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
  }.background(Color(.canvas))
   .preferredColorScheme(dark ? .dark : .light)
   .onAppear { prompt.setActive(true) }
   .onDisappear { prompt.setActive(false); store.stopStreaming() }
 }
 @ViewBuilder private var conversation: some View {
  if layout == "Face" {
   FaceToFaceScreen(store: store, languages: nil, nearLanguage: $near, listenerNear: $listenerNear, showsTextInput: showsTextInput, textInputFocused: $focused, onSetTextInput: { showsTextInput = $0 }, editing: $editing, onEdit: { _ in }, onShowTranscript: {}, onShowSettings: {}, onShowAddress: {}, showsListeningPrompt: !store.isListening || prompt.isVisible)
  } else {
   ConversationTranscriptLayout {
    Text(layout + " transcript").font(.headline).padding(8)
   } transcript: {
    if layout == "Chat" { ChatTranscript(store: store) }
    else { ParallelTranscript(store: store) }
   } footer: {
    ProductionTranscriptFooter(store: store, showsTextInput: $showsTextInput,
        editing: $editing, showsListeningPrompt: !store.isListening || prompt.isVisible)
     .accessibilityElement(children: .contain)
     .accessibilityIdentifier("Fixture transcript footer")
   }
  }
 }
}
