import Foundation

protocol TranslationService {
    /// Streams the translation of `text` token by token.
    func translate(
        _ text: String, from source: Language, to target: Language, context: [Utterance], script: ChineseScript
    ) -> AsyncThrowingStream<String, Error>
}

/// Translates with a Mistral chat model over streaming chat completions.
struct MistralTranslator: TranslationService {
    var apiKey: String
    var model: String

    private static let endpoint = URL(string: "https://api.mistral.ai/v1/chat/completions")!

    func translate(
        _ text: String, from source: Language, to target: Language, context: [Utterance], script: ChineseScript
    ) -> AsyncThrowingStream<String, Error> {
        func name(_ language: Language) -> String { language == .chinese ? script.promptName : language.englishName }
        let system = """
        You are a live interpreter between \(name(source)) and \(name(target)) in a spoken, face-to-face \
        conversation. Translate the user's message into \(name(target)). The text is a speech transcript and \
        may be unpunctuated or end mid-sentence; translate it naturally, as a person would say it, and \
        don't complete unfinished thoughts. Keep names, numbers and units exact. Reply with the \
        translation only: no quotes, notes or romanization.
        """

        var messages: [[String: String]] = [["role": "system", "content": system]]
        // Recent turns help with pronouns, names and topic.
        for turn in context where !turn.translation.isEmpty {
            messages.append(["role": "user", "content": turn.trimmedSource])
            messages.append(["role": "assistant", "content": turn.translation])
        }
        messages.append(["role": "user", "content": text])

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "stream": true,
            "temperature": 0.2,
            "max_tokens": 400,
        ] as [String: Any])

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw TranslationError.http(http.statusCode)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String, !content.isEmpty
                        else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum TranslationError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): "API key rejected"
        case .http(429): "Rate limited"
        case .http(let code): "Server error \(code)"
        }
    }

    /// Errors that won't fix themselves by retrying.
    var isPermanent: Bool {
        if case .http(let code) = self { return code == 400 || code == 401 || code == 403 || code == 404 }
        return false
    }
}
