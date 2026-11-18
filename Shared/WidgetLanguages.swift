import Foundation

/// What the home and lock screen widgets show, and where they lead. The app
/// writes its saved language settings to an App Group the extension can read.
nonisolated struct WidgetLanguages: Codable, Equatable, Sendable {
    /// Each language's name, written in that language, e.g. "English" and "中文".
    var firstName: String
    var secondName: String
    /// Short tags, e.g. "EN" and "中文", for the smallest widgets.
    var firstTag: String
    var secondTag: String
    /// Absent in older saved pairs.
    var automatic: Bool? = nil
    var isAutomatic: Bool { automatic == true }

    static let appGroup = "group.hk.cautela.lively"
    /// The widget kind, for reloading its timelines when the pair changes.
    static let widgetKind = "LivelyWidget"

    /// Opens Lively and starts listening.
    static let listenURL = URL(string: "lively://listen")!
    /// Opens Lively with the type-to-translate bar.
    static let typeURL = URL(string: "lively://type")!

    /// Automatic discovery, until the app has written its saved preference.
    static let fallback = WidgetLanguages(firstName: "English", secondName: "Automatic", firstTag: "EN", secondTag: "Auto", automatic: true)

    private static let key = "widgetLanguages"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// The language settings the app last wrote.
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
