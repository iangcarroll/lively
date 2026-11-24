import SwiftUI

struct OnlineTranslationToggle: View {
    @Binding var isOn: Bool

    private var detail: LocalizedStringKey {
        isOn
            ? "Translate your audio and text via the [Lively Cloud](\(Links.privacy.absoluteString))."
            : "Use downloaded languages and voices."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn) {
                Text("Online translation")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("onlineTranslationToggle")
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OfflineTranslationNotice: View {
    var body: some View {
        Label {
            Text("Offline translation is usually slower and less accurate than online.")
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 16))
        .accessibilityIdentifier("offlineTranslationNotice")
    }
}
