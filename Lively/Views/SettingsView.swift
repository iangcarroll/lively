import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onClear: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// Unsaved key edits by `ProviderCredential.id`.
    @State private var keyDrafts: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Engine", selection: $settings.providerID) {
                        ForEach(SpeechProvider.all) { Text($0.name).tag($0.id) }
                    }
                } footer: {
                    Text(provider.summary)
                }

                Section {
                    languagePicker("First language", selection: \.first)
                    languagePicker("Second language", selection: \.second)
                    if settings.languages.contains(.chinese) {
                        Picker("Chinese script", selection: $settings.chineseScript) {
                            ForEach(ChineseScript.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } header: {
                    Text("Languages")
                } footer: {
                    Text("Lively listens for both languages and translates each into the other. \(provider.name) supports \(provider.languages.count) languages.")
                }

                Section {
                    ForEach(provider.credentials) { credential in
                        SecureField(credential.name, text: draft(for: credential))
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .onSubmit(saveKeys)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                } header: {
                    Text(provider.name)
                } footer: {
                    Text((["Stored in the Keychain on this device."] + provider.credentials.map(\.help)).joined(separator: " "))
                }

                if !provider.options.isEmpty {
                    Section {
                        if provider.options.contains(.speed) {
                            Picker("Speed", selection: $settings.latency) {
                                ForEach(Latency.allCases) { latency in
                                    Text("\(latency.label) · \(latency.milliseconds) ms").tag(latency)
                                }
                            }
                        }
                        if provider.options.contains(.translationModel) {
                            TextField("Translation model", text: $settings.translationModel)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                    } header: {
                        Text("Translation")
                    } footer: {
                        Text(provider.options.contains(.speed)
                            ? "Faster speed shows words sooner; Accurate waits a little longer for better transcripts. Changes apply the next time you start listening."
                            : "Changes apply the next time you start listening.")
                    }
                }

                if let account = Account.shared {
                    Section {
                        NavigationLink {
                            AccountView(account: account)
                        } label: {
                            LabeledContent("Account", value: account.email ?? "Sign In")
                        }
                    }
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
                        saveKeys()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            for credential in SpeechProvider.allCredentials {
                keyDrafts[credential.id] = settings.credential(credential)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private var provider: SpeechProvider { settings.provider }

    /// Picks one side of the pair. Choosing the other side's language swaps them.
    private func languagePicker(_ title: String, selection side: WritableKeyPath<LanguagePair, Language>) -> some View {
        let binding = Binding<Language>(
            get: { settings.languages[keyPath: side] },
            set: { language in
                var pair = settings.languages
                if pair.other(than: pair[keyPath: side]) == language {
                    pair = LanguagePair(first: pair.second, second: pair.first)
                } else {
                    pair[keyPath: side] = language
                }
                settings.languages = pair
            }
        )
        return Picker(title, selection: binding) {
            ForEach(provider.languages.sorted { $0.englishName < $1.englishName }) { language in
                Text(language.pickerName).tag(language)
            }
        }
    }

    private func draft(for credential: ProviderCredential) -> Binding<String> {
        Binding(
            get: { keyDrafts[credential.id] ?? "" },
            set: { keyDrafts[credential.id] = $0 }
        )
    }

    private func saveKeys() {
        for credential in SpeechProvider.allCredentials {
            guard let draft = keyDrafts[credential.id] else { continue }
            settings.setCredential(draft.trimmingCharacters(in: .whitespacesAndNewlines), for: credential)
        }
        if settings.translationModel.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.translationModel = AppSettings.defaultTranslationModel
        }
    }
}
