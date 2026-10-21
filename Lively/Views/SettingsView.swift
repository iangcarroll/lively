import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onClear: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Mistral API key", text: $keyDraft)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .onSubmit(saveKey)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Mistral")
                } footer: {
                    Text("Stored in the Keychain on this device. Create a key at console.mistral.ai.")
                }

                Section {
                    Picker("Speed", selection: $settings.latency) {
                        ForEach(Latency.allCases) { latency in
                            Text("\(latency.label) · \(latency.milliseconds) ms").tag(latency)
                        }
                    }
                    Picker("Chinese", selection: $settings.chineseScript) {
                        ForEach(ChineseScript.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Translation model", text: $settings.translationModel)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Translation")
                } footer: {
                    Text("Faster speed shows words sooner; Accurate waits a little longer for better transcripts. Changes apply the next time you start listening.")
                }

                Section {
                    Button("Clear Conversation", role: .destructive) {
                        onClear()
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveKey()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { keyDraft = settings.apiKey }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private func saveKey() {
        settings.apiKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.translationModel.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.translationModel = AppSettings.defaultTranslationModel
        }
    }
}
