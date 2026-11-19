import SwiftUI

struct OnlineTranslationToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Online translation", isOn: $isOn)
                .font(.headline)
                .accessibilityIdentifier("onlineTranslationToggle")
            Text(isOn
                 ? "Soniox translates audio and reads translations aloud. DeepSeek translates conversation text via Cloudflare."
                 : "Use downloaded languages and voices. Turning this on shares audio with Soniox and conversation text with DeepSeek via Cloudflare.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
