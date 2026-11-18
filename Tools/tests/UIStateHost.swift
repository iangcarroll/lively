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
 @State private var fullScreen = false
 @FocusState private var focused: Bool
 var body: some View {
  VStack(spacing: 0) {
   if !fullScreen {
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
    fixtureMenu
   }.padding(.horizontal, 8)
   HStack {
    Button("Start reminder") { store.isListening = true; store.status = .live; prompt.setActive(false); prompt.setActive(true) }
    Button("Stop reminder") { store.isListening = false; store.status = .idle; prompt.setActive(false) }
    Button("Large text") { largeText.toggle() }
    Button("Dark") { dark.toggle() }
   }.font(.caption).buttonStyle(.bordered)
   }
   conversation
    .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
  }.background(Color(.canvas))
   .overlay(alignment: layout == "Face" ? .trailing : .topTrailing) {
    if fullScreen {
     HStack(spacing: 8) {
      if store.isStreaming {
       Text("Streaming \(store.streamCount)").font(.caption)
        .accessibilityIdentifier("Fixture streaming progress")
      }
      fixtureMenu
     }
     .padding(8)
     .background(.thinMaterial, in: .capsule)
     // The host menu covers an unrelated product control, never conversation
     // text: the middle strip in Face, or the actual top toolbar in transcripts.
     .padding(.trailing, 8)
     .padding(.top, layout == "Face" ? 0 : 8)
    }
   }
   .preferredColorScheme(dark ? .dark : .light)
   .onAppear { prompt.setActive(true) }
   .onDisappear { prompt.setActive(false); store.stopStreaming() }
 }
 private var fixtureMenu: some View {
  Menu("Fixture") {
   Button("Full-screen fixture") { fullScreen = true }
   Button("Load history") { store.populateHistory(); prompt.setActive(false); prompt.setActive(true) }
   Button("Append turn") { store.appendHistory() }
   Button("Revise latest") { store.reviseHistory() }
   Button("Stream latest") { store.streamHistory() }
   Menu("Guidance") {
    Button("Start reminder") { store.isListening = true; store.status = .live; prompt.setActive(false); prompt.setActive(true) }
    Button("Stop reminder") { store.isListening = false; store.status = .idle; prompt.setActive(false) }
    Button("Large text") { largeText.toggle() }
    Button("Dark") { dark.toggle() }
   }
   Menu("Layout") {
    ForEach(["Face", "Chat", "Parallel"], id: \.self) { name in
     Button(name + " layout") { layout = name }
    }
   }
   Button("Keyboard") { showsTextInput.toggle(); if !showsTextInput { focused = false } }
  }.font(.caption)
 }
 @ViewBuilder private var conversation: some View {
  if layout == "Face" {
   FaceToFaceScreen(store: store, languages: nil, nearLanguage: $near, listenerNear: $listenerNear, showsTextInput: showsTextInput, textInputFocused: $focused, onSetTextInput: { showsTextInput = $0 }, editing: $editing, onEdit: { _ in }, onShowTranscript: {}, onShowSettings: {}, onShowAddress: {}, showsListeningPrompt: !store.isListening || prompt.isVisible)
  } else {
   ConversationTranscriptLayout {
    ProductionTranscriptHeader(store: store, wide: layout == "Parallel")
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
