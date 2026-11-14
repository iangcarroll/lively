import SwiftUI
import Translation

struct OfflineLanguagesView: View {
    @Bindable var settings: AppSettings
    @State private var packs: OfflineLanguagePacks
    @Environment(\.scenePhase) private var scenePhase

    init(settings: AppSettings) {
        self.settings = settings
        _packs = State(initialValue: OfflineLanguagePacks(languages: settings.languages, script: settings.chineseScript))
    }

    var body: some View {
        let requestID = packs.translationRequestID
        Form {
            Section {
                ForEach(packs.components) { component in
                    LabeledContent(component.title, value: component.state.rawValue)
                }
                if packs.components.isEmpty { ProgressView("Checking this device…") }
            } header: {
                Text("\(packs.languages.first.englishName) ↔ \(packs.languages.second.englishName)")
            } footer: {
                Text("Download the full speech and translation models before you travel. These cover both directions, including typed text and text read from photos. Change the conversation languages in Settings to prepare another pair.")
            }

            Section {
                if packs.isDownloading {
                    ProgressView(packs.downloadLabel)
                    Button("Stop preparing", role: .cancel) { packs.cancel() }
                } else {
                    Button(packs.ready ? "Check downloads again" : "Download languages") {
                        if packs.ready { Task { await packs.refresh() } } else { packs.download() }
                    }
                    .disabled(!packs.canDownload)
                    Button("Refresh status") { Task { await packs.refresh() } }
                }
                if let error = packs.error { Text(error).foregroundStyle(.red) }
                Button("Use on-device translation") { settings.providerID = SpeechProvider.onDevice.id }
                    .disabled(!packs.ready || packs.isDownloading)
            } footer: {
                Text("On-device recognition and text translation run locally. For offline spoken output, install the pack in Offline Voice Library and select Downloaded voices in Speech-to-Speech. The original voice needs internet. Tap the speaker's language before speaking. System downloads already started may finish after you stop preparing or leave this screen.")
            }

            if !packs.reservedLocales.isEmpty {
                Section {
                    ForEach(packs.reservedLocales, id: \.identifier) { locale in
                        HStack {
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            Spacer()
                            Button("Release", role: .destructive) { Task { await packs.release(locale) } }
                                .disabled(packs.isDownloading)
                        }
                    }
                } header: {
                    Text("Speech language storage")
                } footer: {
                    Text("Apple limits how many speech languages an app can keep. Release an unused language to make room. The system may remove released models later; translation downloads are managed in Apple's Translate settings. Downloads are shared with the system and can change, so check readiness before going offline.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Offline Languages")
        .task { await packs.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await packs.refresh() } }
        }
        .translationTask(packs.translationConfiguration) { session in
            nonisolated(unsafe) let session = session
            await packs.prepareTranslation(session, requestID: requestID)
        }
        .onDisappear { packs.cancel() }
    }
}
