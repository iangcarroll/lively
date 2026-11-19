import SwiftUI

struct OnlineProcessingChoice: View {
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("How should Lively translate?")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("With online translation, Soniox receives microphone audio for live translation and translated text for its spoken voice. Lively can send speech transcripts, typed or scanned text, and recent conversation turns to DeepSeek through Cloudflare. If you select Mistral, it receives audio and text using your API key.")
                Text("You can keep conversations on this device using downloaded languages and voices. You can change this choice in Settings.")
                Link("Privacy Policy", destination: Links.privacy)
                Button("Allow Online Processing") { choose(true) }
                    .buttonStyle(.borderedProminent)
                Button("Use On-Device Only") { choose(false) }
                    .buttonStyle(.bordered)
            }
            .font(.body)
            .frame(maxWidth: 460, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    private func choose(_ allowed: Bool) {
        let revisiting = settings.onlineProcessing != nil
        settings.chooseOnlineProcessing(allowed)
        if revisiting { dismiss() }
    }
}
