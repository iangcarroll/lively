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
 @FocusState private var focused: Bool
 var body: some View {
  VStack(spacing: 0) {
   ScrollView(.horizontal) {
    HStack { ForEach(["Failed", "Network", "Known live", "Unknown", "Source only", "Closed unknown"], id: \.self) { name in Button(name) { store.select(name) } } }.padding(8)
   }.frame(height: 44)
   Text("Retries: \(store.retryCount)").font(.caption)
   HStack {
    Button("Start reminder") { store.isListening = true; prompt.setActive(false); prompt.setActive(true) }
    Button("Stop reminder") { store.isListening = false; prompt.setActive(false) }
    Button("Large text") { largeText.toggle() }
    Button("Dark") { dark.toggle() }
   }.font(.caption).buttonStyle(.bordered)
   FaceToFaceScreen(store: store, languages: nil, nearLanguage: $near, listenerNear: $listenerNear, showsTextInput: false, textInputFocused: $focused, onSetTextInput: { _ in }, editing: $editing, onEdit: { _ in }, onShowTranscript: {}, onShowSettings: {}, onShowAddress: {}, showsListeningPrompt: !store.isListening || prompt.isVisible)
    .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
  }.background(Color(.canvas))
   .preferredColorScheme(dark ? .dark : .light)
   .onAppear { prompt.setActive(true) }
   .onDisappear { prompt.setActive(false) }
 }
}
