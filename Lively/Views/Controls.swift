import SwiftUI

/// The one big button: start and stop listening. A ring breathes with the mic level.
struct MicButton: View {
    let isListening: Bool
    let level: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isListening {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 3)
                        .scaleEffect(1 + CGFloat(level) * 0.35)
                        .animation(.easeOut(duration: 0.12), value: level)
                }
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(isListening ? .white : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 76, height: 76)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isListening ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
            in: .circle
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: isListening)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(isListening ? "Stop listening" : "Start listening")
    }
}

struct StatusPill: View {
    let status: ConversationStore.ConnectionStatus
    let isListening: Bool
    /// Dot only, for tight spaces; the label is still read by VoiceOver.
    var compact = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .phaseAnimator([1.0, 0.35], trigger: pulsing) { dot, phase in
                    dot.opacity(pulsing ? phase : 1)
                }
            if !compact || status != .live {
                Text(compact ? shortLabel : label)
                    .font(.footnote.weight(.medium))
                    .contentTransition(.opacity)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact && status == .live ? 9 : 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy, value: label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var pulsing: Bool {
        switch status {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    private var label: String {
        switch status {
        case .idle: "Ready"
        case .connecting: "Connecting…"
        case .live: "Listening"
        case .reconnecting: "Reconnecting…"
        case .offline: isListening ? "Offline · holding audio" : "Offline"
        case .failed: "Needs attention"
        }
    }

    private var shortLabel: String {
        switch status {
        case .offline: "Offline"
        case .reconnecting: "Reconnecting"
        case .connecting: "Connecting"
        default: label
        }
    }

    private var color: Color {
        switch status {
        case .idle: .secondary
        case .connecting, .reconnecting: .orange
        case .live: .green
        case .offline, .failed: .red
        }
    }
}

struct GlassIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .help(label)
    }
}
