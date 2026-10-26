import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onClear: () -> Void
    var onShowWelcome: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    /// Unsaved key edits by `ProviderCredential.id`.
    @State private var keyDrafts: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                if let account = Account.shared {
                    Section {
                        NavigationLink {
                            AccountView(account: account)
                        } label: {
                            AccountRow(email: account.email)
                        }
                    }
                }

                if SonioxKeyProvider.shared != nil {
                    Section {
                        NavigationLink {
                            ProView()
                        } label: {
                            LabeledContent {
                                Text(proStatus)
                            } label: {
                                Label { Text("Lively Pro") } icon: { SettingsIcon(systemImage: "star.fill", color: .orange) }
                            }
                        }
                    } footer: {
                        if !Pro.shared.isPro {
                            Text("Up to 10 hours of translation a day with the Soniox engine.")
                        }
                    }
                }

                Section {
                    languageLink("First language", side: .first)
                    languageLink("Second language", side: .second)
                    if settings.languages.contains(.chinese) {
                        Picker(selection: $settings.chineseScript) {
                            ForEach(ChineseScript.allCases) { Text($0.label).tag($0) }
                        } label: {
                            Label { Text("Chinese script") } icon: { SettingsIcon(systemImage: "character.zh", color: .teal) }
                        }
                    }
                } header: {
                    Text("Languages")
                } footer: {
                    Text("Lively listens for both languages and translates each into the other.")
                }

                Section {
                    Picker(selection: $settings.pickupRange) {
                        ForEach(PickupRange.allCases) { Text($0.label).tag($0) }
                    } label: {
                        Label { Text("Pickup range") } icon: { SettingsIcon(systemImage: "ear.fill", color: .green) }
                    }
                } header: {
                    Text("Microphone")
                } footer: {
                    Text(settings.pickupRange.summary)
                }

                Section {
                    Toggle(isOn: $settings.speaksTranslations) {
                        Label { Text("Speak translations aloud") } icon: { SettingsIcon(systemImage: "speaker.wave.2.fill", color: .blue) }
                    }
                    .disabled(SonioxSpeaker.credential(settings) == nil)
                } header: {
                    Text("Speech-to-Speech")
                } footer: {
                    Text(speechFooter)
                }

                Section {
                    Picker(selection: $settings.providerID) {
                        ForEach(SpeechProvider.all) { Text($0.name).tag($0.id) }
                    } label: {
                        Label { Text("Engine") } icon: { SettingsIcon(systemImage: "waveform", color: .purple) }
                    }
                    ForEach(provider.credentials) { credential in
                        Label {
                            SecureField(credential.name, text: draft(for: credential))
                                .textContentType(.password)
                                .autocorrectionDisabled()
                                .onSubmit(saveKeys)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        } icon: {
                            SettingsIcon(systemImage: "key.horizontal.fill", color: .gray)
                        }
                    }
                    if provider.options.contains(.speed) {
                        Picker(selection: $settings.latency) {
                            ForEach(Latency.allCases) { latency in
                                Text("\(latency.label) · \(latency.milliseconds) ms").tag(latency)
                            }
                        } label: {
                            Label { Text("Speed") } icon: { SettingsIcon(systemImage: "gauge.with.needle.fill", color: .orange) }
                        }
                    }
                    if provider.options.contains(.translationModel) {
                        LabeledContent {
                            TextField("Model", text: $settings.translationModel, prompt: Text(AppSettings.defaultTranslationModel))
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        } label: {
                            Label { Text("Model") } icon: { SettingsIcon(systemImage: "cpu", color: .indigo) }
                        }
                    }
                } header: {
                    Text("Speech Engine")
                } footer: {
                    Text(engineFooter)
                }

                Section {
                    Button {
                        dismiss()
                        onShowWelcome()
                    } label: {
                        Label { Text("Welcome Tour") } icon: { SettingsIcon(systemImage: "sparkles", color: .pink) }
                    }
                    .tint(.primary)
                    Button(role: .destructive) {
                        onClear()
                        dismiss()
                    } label: {
                        Label { Text("Clear Conversation").foregroundStyle(.red) } icon: { SettingsIcon(systemImage: "trash.fill", color: .red) }
                    }
                } footer: {
                    Text(versionLine)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
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
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private var provider: SpeechProvider { settings.provider }

    private var proStatus: String {
        if Pro.shared.isSubscribed { return "Active" }
        if Account.shared?.hasFreePro == true { return "Included" }
        return "Upgrade"
    }

    private var engineFooter: String {
        var lines = [provider.summary]
        lines += provider.credentials.map(\.help)
        lines.append("Keys are stored in the Keychain on this device.")
        if provider.options.contains(.speed) {
            lines.append("Faster speed shows words sooner; Accurate waits a little longer for better transcripts.")
        }
        return lines.joined(separator: " ")
    }

    private var speechFooter: String {
        guard SonioxSpeaker.credential(settings) != nil else {
            return "Speaking translations aloud needs a Soniox API key."
        }
        return "Translations into \(settings.languages.second.englishName) are read aloud through the speaker as they arrive. "
            + "Lively doesn't listen while it speaks, so it won't translate itself, unless you're using headphones. "
            + "The speaker button on the conversation screen turns it on and off."
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "Lively \(version) (\(build))"
    }

    private func languageLink(_ title: String, side: LanguageSide) -> some View {
        let language = settings.languages[keyPath: side.keyPath]
        return NavigationLink {
            LanguageList(settings: settings, side: side)
        } label: {
            LabeledContent {
                Text(language.nativeName)
            } label: {
                Label { Text(title) } icon: { LanguageIcon(language: language) }
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

/// The signed-in person at the top of Settings, or an invitation to sign in.
private struct AccountRow: View {
    let email: String?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(
                    colors: [Color(.firstLanguageInk), Color(.secondLanguageInk)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                if let initial = email?.first {
                    Text(String(initial).uppercased())
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: "person.fill").font(.system(size: 24))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(email ?? "Sign in to Lively")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(email == nil ? "More translation time every day" : "Account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A Settings-style rounded square with a white symbol.
struct SettingsIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color.gradient, in: .rect(cornerRadius: 8, style: .continuous))
    }
}

/// A Settings icon showing the language's short tag in its ink.
private struct LanguageIcon: View {
    let language: Language

    var body: some View {
        Text(language.tag)
            .font(.system(size: language.tag.count > 2 || language == .chinese ? 11 : 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(language.ink.gradient, in: .rect(cornerRadius: 8, style: .continuous))
    }
}

/// Every language the engine supports, searchable by English or native
/// name. Picking the other side's language swaps the pair.
struct LanguageList: View {
    @Bindable var settings: AppSettings
    let side: LanguageSide
    var title: String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List {
            if query.isEmpty {
                Section("This Conversation") {
                    ForEach(settings.languages.all) { button($0) }
                }
                Section("All Languages") {
                    ForEach(languages) { button($0) }
                }
            } else {
                ForEach(languages) { button($0) }
            }
        }
        .searchable(text: $query, prompt: "Search languages")
        .navigationTitle(title ?? (side == .first ? "First Language" : "Second Language"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if languages.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private func button(_ language: Language) -> some View {
        Button {
            settings.setLanguage(language, for: side.keyPath)
            dismiss()
        } label: {
            row(language)
        }
        .buttonStyle(.plain)
    }

    private var current: Language { settings.languages[keyPath: side.keyPath] }
    private var other: Language { settings.languages.other(than: current) }

    private var languages: [Language] {
        let all = settings.provider.languages.sorted { $0.englishName < $1.englishName }
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.englishName.localizedStandardContains(query) || $0.nativeName.localizedStandardContains(query) || $0.rawValue == query.lowercased()
        }
    }

    private func row(_ language: Language) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.nativeName)
                    .font(.body)
                    .environment(\.locale, language.locale)
                if language.englishName != language.nativeName {
                    Text(language.englishName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if language == current {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            } else if language == other {
                Text("Swap")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(language.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(language.ink.opacity(0.12), in: .capsule)
            }
        }
        .contentShape(.rect)
        .accessibilityAddTraits(language == current ? .isSelected : [])
    }
}
