import SwiftUI

struct OnlineTranslationToggle: View {
    @Binding var isOn: Bool

    private var detail: LocalizedStringKey {
        isOn
            ? "Translate your audio and text via the [Lively Cloud](\(Links.privacy.absoluteString)). Offline translation is usually slower and less accurate."
            : "Use downloaded languages and voices. Offline translation is usually slower and less accurate than online."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Online translation", isOn: $isOn)
                .font(.headline)
                .accessibilityIdentifier("onlineTranslationToggle")
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
