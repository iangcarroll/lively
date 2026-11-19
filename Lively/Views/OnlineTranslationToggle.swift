import SwiftUI

struct OnlineTranslationToggle: View {
    @Binding var isOn: Bool

    private var detail: LocalizedStringKey {
        isOn
            ? "Translate your audio and conversation text via the [Lively Cloud](\(Links.privacy.absoluteString))."
            : "Translate on this device with downloaded languages and voices."
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
