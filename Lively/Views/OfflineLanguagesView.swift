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
                Text("Prepare both languages before going offline. These downloads also cover typed text and text read from photos.")
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
                }
                if let error = packs.error { Text(error).foregroundStyle(.red) }
                Button("Use on-device translation") { settings.providerID = SpeechProvider.onDevice.id }
                    .disabled(!packs.ready || packs.isDownloading)
            } footer: {
                Text("For offline audio, download voices in the Offline Voice Library and select Downloaded voices in Speech-to-Speech. Choose the speaker's language before talking. System downloads may continue after you cancel preparation.")
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
                    Text("Apple limits how many speech languages Lively can keep. Release an unused language to make room; Apple may remove its files later. Manage translation downloads in Apple's Translate settings, and check readiness before going offline.")
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
