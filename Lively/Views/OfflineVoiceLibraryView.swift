import SwiftUI
import NeuralVoices

struct OfflineVoiceLibraryView: View {
    @Bindable var packs: NeuralVoicePacks
    var onSelectVoice: @MainActor (NeuralVoice) -> Void
    var onPreview: @MainActor (NeuralVoice) async throws -> Void
    var onStopPreview: @MainActor () -> Void
    var onBeforeDelete: @MainActor () async -> Void
    @State private var query = ""
    @State private var selectedLanguage = "all"
    @State private var confirmsDeletion = false
    @State private var previewingID: String?
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewOperation = UUID()
    @Environment(\.scenePhase) private var scenePhase

    init(packs: NeuralVoicePacks = .shared,
         onSelectVoice: @escaping @MainActor (NeuralVoice) -> Void = { _ in },
         onPreview: @escaping @MainActor (NeuralVoice) async throws -> Void,
         onStopPreview: @escaping @MainActor () -> Void = {},
         onBeforeDelete: @escaping @MainActor () async -> Void = {}) {
        self.packs = packs
        self.onSelectVoice = onSelectVoice
        self.onPreview = onPreview
        self.onStopPreview = onStopPreview
        self.onBeforeDelete = onBeforeDelete
    }

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $selectedLanguage) {
                    Text("All languages").tag("all")
                    ForEach(NeuralVoiceCatalog.languages) { language in
                        Text(language.name == language.nativeName ? language.name : "\(language.name) · \(language.nativeName)").tag(language.id)
                    }
                }
                LabeledContent("Download", value: packs.statusText)
                if packs.isDownloading {
                    ProgressView(value: packs.progress) {
                        Text("\(bytes(packs.downloadedBytes)) of \(bytes(packs.totalBytes))")
                    }
                    Button("Cancel download", role: .cancel) { packs.cancel() }
                } else if packs.status == .checking || packs.status == .deleting {
                    ProgressView(packs.statusText)
                } else if !packs.isReady || packs.status == .failed {
                    Button(packs.status == .failed ? "Retry voice download" : "Download voice pack") { packs.download() }
                        .disabled(!packs.canDownload)
                }
                if let error = packs.error { Text(error).foregroundStyle(.red) }
                if let previewError { Text(previewError).foregroundStyle(.red) }
                if packs.isReady {
                    Button("Remove download", role: .destructive) {
                        confirmsDeletion = true
                    }
                    .disabled(packs.isBusy)
                }
            } header: {
                Text("54 voices · 8 languages")
            } footer: {
                Text("One download (\(bytes(packs.totalBytes))) includes all 54 voices for offline speech. Choose your conversation languages separately in Settings.")
            }

            ForEach(filteredLanguages) { language in
                Section {
                    ForEach(filteredVoices(language)) { voice in voiceRow(voice) }
                } header: {
                    Text(language.name == language.nativeName ? language.name : "\(language.name) · \(language.nativeName)")
                }
            }
            if filteredLanguages.isEmpty {
                Section { Text("No voices match your search.").foregroundStyle(.secondary) }
            }
            Section {
                NavigationLink("Voice licenses") {
                    ScrollView {
                        Text(NeuralVoiceEngine.licenseNotices)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("Voice Licenses")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Offline Voices")
        .searchable(text: $query, prompt: "Search voices or languages")
        .confirmationDialog("Remove all downloaded voices?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) {
                stopPreview()
                Task { await packs.delete(beforeRemoving: onBeforeDelete) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your voice selections stay saved. Download the voice pack again to hear them offline.")
        }
        .task { await packs.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await packs.refresh() } }
            else { stopPreview() }
        }
        .onDisappear { stopPreview() }
    }

    private func voiceRow(_ voice: NeuralVoice) -> some View {
        HStack(spacing: 14) {
            Button {
                stopPreview()
                packs.select(voice)
                onSelectVoice(voice)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(voice.name).foregroundStyle(.primary)
                        if let accent = voice.accent { Text(accent).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if packs.selectedVoice(for: voice.languageCode)?.id == voice.id {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(voice.name), \(voice.languageName)")
            .accessibilityAddTraits(packs.selectedVoice(for: voice.languageCode)?.id == voice.id ? .isSelected : [])

            Button { preview(voice) } label: {
                Image(systemName: previewingID == voice.id ? "stop.fill" : "play.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(!packs.isReady || packs.isBusy)
            .accessibilityLabel(previewingID == voice.id ? "Stop preview" : "Preview \(voice.name) in \(voice.languageName)")
        }
    }

    private var filteredLanguages: [NeuralVoiceLanguage] {
        NeuralVoiceCatalog.languages.filter { (selectedLanguage == "all" || $0.id == selectedLanguage) && !filteredVoices($0).isEmpty }
    }
    private func filteredVoices(_ language: NeuralVoiceLanguage) -> [NeuralVoice] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty || language.name.localizedStandardContains(query) || language.nativeName.localizedStandardContains(query) {
            return language.voices
        }
        return language.voices.filter {
            $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query)
                || ($0.accent?.localizedStandardContains(query) ?? false)
        }
    }

    private func preview(_ voice: NeuralVoice) {
        let wasPlaying = previewingID == voice.id
        stopPreview()
        guard !wasPlaying else { return }
        previewError = nil
        previewingID = voice.id
        let token = UUID()
        previewOperation = token
        previewTask = Task {
            guard !Task.isCancelled, previewOperation == token else { return }
            defer {
                if previewOperation == token { previewingID = nil; previewTask = nil }
            }
            do { try await onPreview(voice) }
            catch {
                guard !Task.isCancelled, previewOperation == token else { return }
                previewError = error.localizedDescription
            }
        }
    }
    private func stopPreview() {
        previewOperation = UUID()
        previewTask?.cancel()
        previewTask = nil
        previewingID = nil
        onStopPreview()
    }
    private func bytes(_ count: Int64) -> String {
        count > 0 ? ByteCountFormatter.string(fromByteCount: count, countStyle: .file) : "about 92 MB"
    }
}
