#if DEBUG
import Foundation

/// A scripted conversation for screenshots, previews and trying the UI
/// without an API key. Launch with `-LivelyDemo YES`.
///
/// It feeds the same events Voxtral sends through the real pipeline, so turn
/// handling and translation behave as they do live.
final class DemoConversation {
    static let script: [(String, String)] = [
        ("Hi! Is this the right place for the bus to the airport?", "你好！这里是去机场的公交车站吗？"),
        ("是的，就在这里。不过下一班车大概二十分钟以后才到。", "Yes, it's right here. But the next bus won't come for about twenty minutes."),
        ("Twenty minutes is fine. Do I pay on the bus or buy a ticket first?", "二十分钟没问题。我是在车上付钱，还是要先买票？"),
        ("可以直接上车刷卡，也可以用微信或者支付宝扫码。", "You can tap a card when you get on, or scan the code with WeChat or Alipay."),
        ("Perfect, thank you so much for your help.", "太好了，非常感谢你的帮助。"),
    ]

    private var task: Task<Void, Never>?

    func play(into store: ConversationStore) {
        task?.cancel()
        task = Task { [weak store] in
            for (index, line) in Self.script.enumerated() {
                guard let store, !Task.isCancelled else { return }
                if index > 0 { try? await Task.sleep(for: .milliseconds(900)) }
                store.handle(.turnStarted)
                for piece in Self.pieces(of: line.0) {
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 70...140)))
                    guard !Task.isCancelled else { return }
                    store.handle(.text(piece))
                }
                try? await Task.sleep(for: .milliseconds(250))
                store.handle(.turnEagerEnded)
                try? await Task.sleep(for: .milliseconds(300))
                store.handle(.turnEnded)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    /// Splits English into words and Chinese into 1-3 character chunks,
    /// roughly how realtime transcription streams them.
    private static func pieces(of text: String) -> [String] {
        if Language.detect(text, in: .default) == .english {
            return text.split(separator: " ").enumerated().map { $0.offset == 0 ? String($0.element) : " " + $0.element }
        }
        var result: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let n = min(rest.count, Int.random(in: 1...3))
            result.append(String(rest.prefix(n)))
            rest = rest.dropFirst(n)
        }
        return result
    }
}

/// Returns canned translations from the demo script, streamed in pieces.
struct DemoTranslator: TranslationService {
    func translate(
        _ text: String, from source: Language, to target: Language, context: [Utterance], script: ChineseScript
    ) -> AsyncThrowingStream<String, Error> {
        let full = DemoConversation.script.first { $0.0.hasPrefix(text) }
        // Partial transcripts get a proportional slice of the final translation.
        let ratio = full.map { Double(text.count) / Double($0.0.count) } ?? 1
        let target = full?.1 ?? text
        let output = String(target.prefix(Int((Double(target.count) * ratio).rounded(.up))))
        return AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .milliseconds(180))
                var rest = Substring(output)
                while !rest.isEmpty, !Task.isCancelled {
                    let n = min(rest.count, 4)
                    continuation.yield(String(rest.prefix(n)))
                    rest = rest.dropFirst(n)
                    try? await Task.sleep(for: .milliseconds(25))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
