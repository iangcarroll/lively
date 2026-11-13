import Foundation

struct Language: Equatable, Sendable {
    let rawValue: String
    var englishName: String { rawValue }
    static let english = Self(rawValue: "en")
    static let chinese = Self(rawValue: "zh")
}
enum ChineseScript: Sendable { case simplified, traditional }
struct Utterance {}
protocol TranslationService {
    func translate(_ text: String, from source: Language, to target: Language,
                   context: [Utterance], script: ChineseScript) -> AsyncThrowingStream<String, Error>
}
enum Translation {
    struct TranslationError: Error, Equatable {
        let code: Int
        static let internalError = Self(code: 1)
        static let notInstalled = Self(code: 2)
        static let unsupportedLanguagePairing = Self(code: 3)
        static func ~= (match: Self, error: Error) -> Bool { (error as? Self) == match }
    }
}
final class TranslationSession {
    struct Strategy: Equatable { static let lowLatency = Self() }
    struct Response { let targetText: String }
    static var outcomes: [Result<Response, Error>] = []
    static var calls = 0
    static var sessions = 0
    static var strategies: [Strategy?] = []
    static var directions: [(Locale.Language, Locale.Language)] = []
    init(installedSource: Locale.Language, target: Locale.Language?, preferredStrategy: Strategy? = nil) {
        Self.sessions += 1
        Self.strategies.append(preferredStrategy)
        Self.directions.append((installedSource, target!))
    }
    func translate(_ text: String) async throws -> Response {
        Self.calls += 1
        // A fourth call succeeds so a broken retry bound fails assertions
        // promptly rather than looping or relying on a runner timeout.
        return try Self.outcomes.isEmpty ? Response(targetText: "unexpected extra attempt") : Self.outcomes.removeFirst().get()
    }
    static func reset(_ outcomes: [Result<Response, Error>]) {
        Self.outcomes = outcomes
        calls = 0; sessions = 0; strategies = []; directions = []
    }
}

// INSERT_ACTUAL_TRANSLATOR

@main struct AppleTranslatorRegression {
    static var assertions = 0
    static var failures = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !value() { failures += 1; print("FAIL: " + message) }
    }
    static func consume(_ stream: AsyncThrowingStream<String, Error>) async -> Result<[String], Error> {
        do {
            var output: [String] = []
            for try await piece in stream { output.append(piece) }
            return .success(output)
        } catch { return .failure(error) }
    }
    static func translate(script: ChineseScript = .simplified) async -> Result<[String], Error> {
        await consume(AppleTranslator().translate("Hello", from: .english, to: .chinese, context: [], script: script))
    }
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 { if condition() { return }; await Task.yield() }
        check(false, "translation reached the controlled call")
    }
    static func isFailure(_ result: Result<[String], Error>) -> Bool {
        if case .failure = result { return true }; return false
    }
    static func output(_ result: Result<[String], Error>) -> [String] {
        if case .success(let output) = result { return output }; return []
    }
    static func main() async {
        let internalFailure = Result<TranslationSession.Response, Error>.failure(Translation.TranslationError.internalError)
        let missing = Result<TranslationSession.Response, Error>.failure(Translation.TranslationError.notInstalled)
        let success = Result<TranslationSession.Response, Error>.success(.init(targetText: "你好"))

        TranslationSession.reset([success])
        let initial = await translate()
        check(output(initial) == ["你好"], "installed model translates successfully")
        check(TranslationSession.calls == 1 && TranslationSession.sessions == 1,
              "successful translation does not create extra sessions")
        check(TranslationSession.strategies == [.lowLatency], "local runtime uses the downloaded low-latency model")
        check(TranslationSession.directions.first?.1 == Locale.Language(identifier: "zh-Hans"), "simplified Chinese uses the matching installed script")

        TranslationSession.reset([internalFailure, success])
        let warmed = await translate(script: .traditional)
        check(output(warmed) == ["你好"] && TranslationSession.calls == 2,
              "transient internal failure retries locally and returns one translation")
        check(TranslationSession.sessions == 2 && TranslationSession.directions.allSatisfy { $0.1 == Locale.Language(identifier: "zh-Hant") },
              "retry recreates the same installed model session without changing script")

        TranslationSession.reset([missing, success])
        let settled = await translate()
        check(output(settled) == ["你好"] && TranslationSession.calls == 2,
              "recently installed assets get a bounded local reconciliation attempt")

        TranslationSession.reset([internalFailure, internalFailure, internalFailure])
        let exhausted = await translate()
        check(isFailure(exhausted) && TranslationSession.calls == 3,
              "repeated internal failure stops after three attempts")
        if case .failure(let error) = exhausted {
            check(error.localizedDescription.contains("Settings"), "bounded failure retains actionable offline model guidance")
        }

        TranslationSession.reset([missing, missing, missing])
        let absent = await translate()
        check(isFailure(absent) && TranslationSession.calls == 3,
              "missing models are never treated as ready after retries")

        TranslationSession.reset([.failure(Translation.TranslationError.unsupportedLanguagePairing)])
        let unsupported = await translate()
        check(isFailure(unsupported) && TranslationSession.calls == 1,
              "unsupported language pairs fail without retrying")
        TranslationSession.reset([.failure(NSError(domain: "test.unrelated", code: 42))])
        let unknown = await translate()
        check(isFailure(unknown) && TranslationSession.calls == 1,
              "unknown failures are not classified as transient")

        TranslationSession.reset([internalFailure, success])
        let stream = AppleTranslator().translate("Hello", from: .english, to: .chinese, context: [], script: .simplified)
        let consumer = Task { await consume(stream) }
        await until { TranslationSession.calls == 1 }
        consumer.cancel()
        let cancelled = await consumer.value
        try? await Task.sleep(for: .milliseconds(850))
        check(TranslationSession.calls == 1, "cancellation during backoff prevents another local request")
        check(output(cancelled).isEmpty, "cancelled translation emits no successful text")
        print("Apple translator regression: \(assertions) assertions, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
