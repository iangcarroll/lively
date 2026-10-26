#if os(iOS)
import WidgetKit

extension WidgetLanguages {
    init(_ languages: LanguagePair) {
        self.init(
            firstName: languages.first.nativeName, secondName: languages.second.nativeName,
            firstTag: languages.first.tag, secondTag: languages.second.tag
        )
    }

    /// Shows this pair on the home and lock screen widgets, if it changed.
    static func publish(_ languages: LanguagePair) {
        let widgetLanguages = WidgetLanguages(languages)
        guard widgetLanguages != current else { return }
        widgetLanguages.save()
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}
#endif
