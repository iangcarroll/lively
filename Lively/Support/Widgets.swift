#if os(iOS)
import WidgetKit

extension WidgetLanguages {
    init(_ languages: LanguagePair) {
        self.init(
            firstName: languages.first.nativeName, secondName: languages.second.nativeName,
            firstTag: languages.first.tag, secondTag: languages.second.tag, automatic: false
        )
    }

    /// Shows this pair on the home and lock screen widgets, if it changed.
    static func publish(_ languages: LanguagePair) {
        let widgetLanguages = WidgetLanguages(languages)
        guard widgetLanguages != current else { return }
        widgetLanguages.save()
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    /// Shows the saved reader language without guessing a conversation partner.
    static func publishAutomatic(listener: Language) {
        let widgetLanguages = WidgetLanguages(
            firstName: listener.nativeName, secondName: "Automatic",
            firstTag: listener.tag, secondTag: "Auto", automatic: true
        )
        guard widgetLanguages != current else { return }
        widgetLanguages.save()
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}
#endif
