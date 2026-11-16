import Foundation

// Appended to the production service in a temporary file so its private helper
// can be checked without exposing a testing API or making any Maps requests.
extension MapAddressLookupService {
    @MainActor
    static func runVerificationRegressions() -> (checks: Int, failures: Int) {
        let service = MapAddressLookupService()
        var checks = 0
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition {
                failures += 1
                print("FAIL: \(message)")
            }
        }

        for name in ["Roppongi", "六本木", "三軒茶屋", "二子玉川", "四谷", "日本橋", "Hotel Ⅳ", "Tower Ⅵ", "Café ²", "Shop ①"] {
            expect(service.numberParts(name).isEmpty, "\(name) must not supply a postal number")
        }

        let ordinary = service.numberParts("6-10-1")
        expect(ordinary == ["1", "10", "6"], "decimal address components are retained")
        for address in ["６丁目１０−１", "٦-١٠-١", "۶-۱۰-۱", "६-१०-१"] {
            expect(service.numberParts(address) == ordinary, "decimal numeral normalization: \(address)")
        }
        expect(service.numberParts("六本木6-10-1") == ordinary, "Kanji place name does not duplicate house number6")
        expect(service.numberParts("三軒茶屋2-16-1") == service.numberParts("Sangenjaya2-16-1"), "translated neighborhood name preserves its decimal address")
        expect(service.numberParts("Tower Ⅵ, 6-10-1") == ordinary, "Roman-numeral proper name does not duplicate house number6")

        let japanese = "〒100-0005 東京都千代田区丸の内1丁目9-1"
        let english = "9-1, Marunouchi 1-Chōme, Chiyoda, Tokyo 100-0005"
        expect(service.numberParts(japanese) == service.numberParts(english), "address order can change without changing number components")
        expect(service.numberParts("〒100-0005") == ["0005", "100"], "postal leading zeros are preserved")
        expect(service.numberParts("5") != service.numberParts("0005"), "leading zeros cannot silently disappear")
        expect(service.numberParts("12 Main St") != service.numberParts("21 Main St"), "street numbers cannot be permuted")
        expect(service.numberParts("1-2 Main St") != service.numberParts("12 Main St"), "number boundaries are not erased")
        expect(service.numberParts("6-10-1") != service.numberParts("6-10-2"), "changed house number is rejected")
        expect(service.numberParts("1 Main St Apt 23") != service.numberParts("1 Main St"), "dropped unit number is rejected")
        expect(service.numberParts("1 Main St") != service.numberParts("1 Main St Apt 23"), "added unit number is rejected")
        expect(service.numberParts("Tokyo") != service.numberParts("Tokyo 2-8-1"), "a broad place cannot gain a fabricated street number")
        expect(service.numberParts("Main St 2 2") != service.numberParts("Main St 2"), "repeated components are retained")
        expect(service.numberParts("1 Apple Park Way, Cupertino CA95014") == service.numberParts("1 Apple Park Way, クパティーノ CA95014"), "proper names may localize while street and ZIP numbers stay fixed")

        func candidate(address: String, query: String) -> Candidate {
            let item = MKMapItem(location: CLLocation(latitude: 35.6806366, longitude: 139.7655154),
                                 address: MKAddress(fullAddress: address, shortAddress: nil))
            let place = AddressPlace(id: "fixture", name: "Chosen address", subtitle: address,
                                     latitude: 35.6806366, longitude: 139.7655154, countryCode: "JP")
            return Candidate(item: item, place: place, address: address, query: query)
        }
        let formatted = "9-1, Marunouchi 1-Chōme\nChiyoda, Tokyo\nJapan 100-0005"
        let original = "1-9-1 Marunouchi, Chiyoda, Tokyo, Japan"
        let englishLanguage = AddressLanguage(code: "en")
        let japaneseLanguage = AddressLanguage(code: "ja")
        expect(service.geocodingQueries(for: candidate(address: formatted, query: original), language: englishLanguage) == [formatted, original],
               "original street query remains available when Maps drops address detail from its formatted string")
        expect(service.geocodingQueries(for: candidate(address: original, query: original), language: englishLanguage) == [original],
               "identical geocoding queries are not repeated")
        expect(service.geocodingQueries(for: candidate(address: "Tokyo\nJapan", query: "Tokyo Japan"), language: englishLanguage) == ["Tokyo\nJapan", "Tokyo Japan"],
               "line-break parsing alternatives are preserved")
        let localizedQueries = service.geocodingQueries(for: candidate(address: formatted, query: original), language: japaneseLanguage)
        expect(localizedQueries == [formatted.replacingOccurrences(of: "Japan", with: "日本"), original.replacingOccurrences(of: "Japan", with: "日本"), formatted, original],
               "target-language country component provides a localization alternative without rewriting the street")
        expect(service.geocodingQueries(for: candidate(address: "Japan Hotel, Tokyo, Japan", query: "Japan Hotel, Tokyo, Japan"), language: japaneseLanguage).first == "Japan Hotel, Tokyo, 日本",
               "country localization cannot rename a venue containing the country name")
        expect(service.geocodingQueries(for: candidate(address: "Japan Hotel, Tokyo", query: "Japan Hotel, Tokyo"), language: japaneseLanguage) == ["Japan Hotel, Tokyo"],
               "a country word in a venue name is not treated as a country component")
        let japaneseLocale = service.geocodingLocale(for: AddressLanguage(code: "ja"), countryCode: "JP")
        expect(japaneseLocale.language.languageCode?.identifier == "ja" && japaneseLocale.region?.identifier == "JP",
               "geocoder uses the requested language and selected country")
        let englishJapan = service.geocodingLocale(for: AddressLanguage(code: "en"), countryCode: "JP")
        expect(englishJapan.language.languageCode?.identifier == "en" && englishJapan.region?.identifier == "JP",
               "country context cannot replace the chosen language")
        expect(service.geocodingLocale(for: AddressLanguage(code: "zh-Hant"), countryCode: "TW").identifier.contains("Hant"),
               "Chinese script preference survives country qualification")
        expect(service.geocodingLocale(for: AddressLanguage(code: "fr"), countryCode: nil).language.languageCode?.identifier == "fr",
               "missing country retains the requested language")

        func accepts(_ text: String, _ code: String) -> Bool {
            service.supportsRequestedScript(text, language: AddressLanguage(code: code))
        }
        expect(accepts("東京都千代田区丸の内1丁目9-1", "ja"), "Japanese address script is accepted")
        expect(accepts("1 Apple Park Way クパティーノ アメリカ合衆国", "ja"), "Japanese address can retain a Latin street name")
        expect(!accepts("9-1 Marunouchi Chiyoda Tokyo Japan 100-0005", "ja"), "English fallback is not presented as Japanese")
        expect(!accepts("１２３４５", "ja"), "numbers alone cannot prove Japanese text")
        expect(accepts("北京市东城区", "zh-Hans"), "Han characters are accepted for Simplified Chinese")
        expect(accepts("臺北市中正區", "zh-Hant"), "Han characters are accepted for Traditional Chinese")
        expect(accepts("서울특별시", "ko"), "Korean address script is accepted")
        expect(!accepts("Seoul South Korea", "ko"), "English fallback is not presented as Korean")
        expect(accepts("القاهرة مصر", "ar"), "Arabic address letters are accepted")
        expect(!accepts("Cairo Egypt ١٢٣", "ar"), "Arabic digits do not disguise an English fallback")
        expect(accepts("Москва Россия", "ru"), "Cyrillic address letters are accepted")
        expect(!accepts("Moscow Russia", "ru"), "English fallback is not presented as Russian")
        expect(accepts("1 Apple Park Way", "en"), "Latin-script address names are preserved")
        expect(!accepts("東京都千代田区丸の内1丁目9-1", "en"), "all-Han fallback is not presented as English")
        expect(!accepts("１２３４５", "en"), "numbers alone cannot prove an English address")

        let street = "9-1, Marunouchi 1-Chōme, Tokyo 100-0005"
        let area = "Marunouchi, Chiyoda, Tokyo, Japan"
        expect(service.isWithinLocationTolerance(0, sourceAddress: street), "numbered address accepts the original point")
        expect(service.isWithinLocationTolerance(49.99, sourceAddress: street), "numbered address accepts nearby formatting adjustment")
        expect(service.isWithinLocationTolerance(50, sourceAddress: street), "numbered address includes the 50m boundary")
        expect(!service.isWithinLocationTolerance(50.01, sourceAddress: street), "numbered address rejects beyond 50m")
        expect(!service.isWithinLocationTolerance(499, sourceAddress: street), "numbered address cannot use the broad-area tolerance")
        expect(service.isWithinLocationTolerance(235.5, sourceAddress: area), "partial station neighborhood retains its observed displacement")
        expect(service.isWithinLocationTolerance(500, sourceAddress: area), "unnumbered area includes the 500m boundary")
        expect(!service.isWithinLocationTolerance(500.01, sourceAddress: area), "unnumbered area rejects beyond 500m")
        expect(!service.isWithinLocationTolerance(51, sourceAddress: "〒100-0005 東京都千代田区丸の内1丁目9-1"), "Japanese decimal address uses the tight bound")
        expect(!service.isWithinLocationTolerance(51, sourceAddress: "６−１０−１"), "fullwidth address numbers use the tight bound")
        expect(!service.isWithinLocationTolerance(51, sourceAddress: "٦-١٠-١"), "Arabic-Indic address numbers use the tight bound")
        expect(service.isWithinLocationTolerance(235.5, sourceAddress: "六本木"), "Kanji proper name remains an unnumbered area")
        expect(!service.isWithinLocationTolerance(-1, sourceAddress: street), "negative distance is invalid")
        expect(!service.isWithinLocationTolerance(.nan, sourceAddress: street), "NaN distance is invalid")
        expect(!service.isWithinLocationTolerance(.infinity, sourceAddress: area), "infinite distance is invalid")
        return (checks, failures)
    }
}

@main
struct AddressVerificationRegression {
    @MainActor
    static func main() {
        let result = MapAddressLookupService.runVerificationRegressions()
        if result.failures > 0 { exit(1) }
        print("Address verification regressions: \(result.checks) checks passed.")
    }
}
