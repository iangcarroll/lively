import Foundation

/// What the home and lock screen widgets show, and where they lead. The app
/// writes the language pair to an App Group the widget extension can read.
nonisolated struct WidgetLanguages: Codable, Equatable, Sendable {
    /// Each language's name, written in that language, e.g. "English" and "中文".
    var firstName: String
    var secondName: String
    /// Short tags, e.g. "EN" and "中文", for the smallest widgets.
    var firstTag: String
    var secondTag: String

    static let appGroup = configuredValue("LivelyAppGroup", fallback: "group.sh.ian.lively")
    static let urlScheme = configuredValue("LivelyURLScheme", fallback: "lively")
    /// The widget kind, for reloading its timelines when the pair changes.
    static let widgetKind = "LivelyWidget"

    /// Opens Lively and starts listening.
    static let listenURL = URL(string: "\(urlScheme)://listen")!
    /// Opens Lively with the type-to-translate bar.
    static let typeURL = URL(string: "\(urlScheme)://type")!

    /// Older builds and test bundles may not have the shared configuration keys.
    private static func configuredValue(_ key: String, fallback: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(") else { return fallback }
        return value
    }

    /// Lively's default pair, until the app has written one.
    static let fallback = WidgetLanguages(firstName: "English", secondName: "中文", firstTag: "EN", secondTag: "中文")

    private static let key = "widgetLanguages"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// The pair the app last wrote.
    static var current: WidgetLanguages {
        guard let data = defaults?.data(forKey: key),
              let languages = try? JSONDecoder().decode(WidgetLanguages.self, from: data) else { return fallback }
        return languages
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults?.set(data, forKey: Self.key)
    }
}
