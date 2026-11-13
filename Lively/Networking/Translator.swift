import Foundation
import Translation

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

        return chatCompletionStream(request) { status, _ in TranslationError.http(status) }
    }
}

/// Streams the `content` of OpenAI-style chat completion chunks. `failure`
/// turns a non-2xx status and its body into the error to throw.
private func chatCompletionStream(
    _ request: URLRequest, session: URLSession = .shared, failure: @escaping (Int, Data) -> Error
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    var body = Data()
                    for try await byte in bytes.prefix(4096) { body.append(byte) }
                    throw failure(http.statusCode, body)
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

/// Translates through Lively's key broker (`POST /v1/translate`), which runs
/// DeepSeek and counts each line against the plan's daily allowance. The
/// broker holds the prompt; this sends the text, languages and recent turns.
struct BrokerTranslator: TranslationService {
    /// Nil when the build has no `LivelyKeyBrokerURL`.
    static let shared: BrokerTranslator? = SonioxKeyProvider.brokerURL.map {
        BrokerTranslator(endpoint: $0.appending(path: "v1/translate"))
    }

    let endpoint: URL

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    func translate(
        _ text: String, from source: Language, to target: Language, context: [Utterance], script: ChineseScript
    ) -> AsyncThrowingStream<String, Error> {
        let body: [String: Any] = [
            "text": text,
            "source": source.rawValue,
            "target": target.rawValue,
            "script": script.rawValue,
            "context": context.filter { !$0.translation.isEmpty }.map {
                ["source": $0.trimmedSource, "translation": $0.translation]
            },
        ]
        let token = Account.shared?.token
        let stream = chatCompletionStream(request(body: body, token: token), session: Self.session) { status, data in
            if status == 401, let token { return BrokerTranslationError.tokenRejected(token) }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            return message.map { TranslationError.service($0, permanent: status != 502) } ?? TranslationError.http(status)
        }
        guard token != nil else { return stream }
        // A signed-out or expired session: drop it and ask again anonymously.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        for try await piece in stream { continuation.yield(piece) }
                    } catch BrokerTranslationError.tokenRejected(let token) {
                        Account.shared?.tokenWasRejected(token)
                        for try await piece in chatCompletionStream(request(body: body, token: nil), session: Self.session, failure: { status, _ in TranslationError.http(status) }) {
                            continuation.yield(piece)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request(body: [String: Any], token: String?) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(SonioxKeyProvider.installID, forHTTPHeaderField: "Lively-Install-ID")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let subscription = Pro.shared.signedTransaction {
            request.setValue(subscription, forHTTPHeaderField: "Lively-Subscription")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

private enum BrokerTranslationError: Error {
    case tokenRejected(String)
}

/// Tries `primary`, and `fallback` if it fails before sending anything, as
/// on-device translation stands in for the broker when it's unreachable or
/// the day's allowance is used up. If both fail, the primary's error is thrown.
struct FallbackTranslator: TranslationService {
    var primary: TranslationService
    var fallback: TranslationService

    func translate(
        _ text: String, from source: Language, to target: Language, context: [Utterance], script: ChineseScript
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var started = false
                do {
                    for try await piece in primary.translate(text, from: source, to: target, context: context, script: script) {
                        started = true
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch let primaryError {
                    if started || primaryError is CancellationError || Task.isCancelled {
                        continuation.finish(throwing: primaryError)
                        return
                    }
                    do {
                        for try await piece in fallback.translate(text, from: source, to: target, context: context, script: script) {
                            continuation.yield(piece)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error is CancellationError ? error : primaryError)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Translates on device with Apple's Translation framework, for typed text
/// when no translation API key is set. The languages must be downloaded;
/// `TypeToTranslateBar` offers the download when it opens.
struct AppleTranslator: TranslationService {
    func translate(
        _ text: String, from source: Language, to target: Language, context: [Utterance], script: ChineseScript
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session: TranslationSession
                    if #available(iOS 26.4, macOS 26.4, *) {
                        session = TranslationSession(installedSource: Self.language(source, script: script), target: Self.language(target, script: script), preferredStrategy: .lowLatency)
                    } else {
                        session = TranslationSession(installedSource: Self.language(source, script: script), target: Self.language(target, script: script))
                    }
                    let response = try await session.translate(text)
                    continuation.yield(response.targetText)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: TranslationError.onDevice(languageName: target.englishName))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func language(_ language: Language, script: ChineseScript) -> Locale.Language {
        guard language == .chinese else { return Locale.Language(identifier: language.rawValue) }
        return Locale.Language(identifier: script == .traditional ? "zh-Hant" : "zh-Hans")
    }
}

enum TranslationError: LocalizedError {
    case http(Int)
    /// On-device translation failed, usually because a language isn't downloaded.
    case onDevice(languageName: String)
    /// The broker's own message, such as a used-up daily allowance.
    case service(String, permanent: Bool)

    var errorDescription: String? {
        switch self {
        case .onDevice(let name): "Offline translation into \(name) isn't ready. Download both languages in Settings → Offline Languages while connected to the internet."
        case .service(let message, _): message
        case .http(401), .http(403): "API key rejected"
        case .http(429): "Rate limited"
        case .http(let code): "Server error \(code)"
        }
    }

    /// Errors that won't fix themselves by retrying.
    var isPermanent: Bool {
        switch self {
        case .http(let code): code == 400 || code == 401 || code == 403 || code == 404
        case .onDevice: true
        case .service(_, let permanent): permanent
        }
    }
}
