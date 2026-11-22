import UIKit
import XCTest

nonisolated final class LocalizedOnboardingTests: XCTestCase {
    @MainActor func testJapanese() throws { try tour("ja") }
    @MainActor func testSimplifiedChinese() throws { try tour("zh-Hans") }
    @MainActor func testTraditionalChinese() throws { try tour("zh-Hant") }
    @MainActor func testGerman() throws { try tour("de") }
    @MainActor func testArabic() throws { try tour("ar") }

    @MainActor private func tour(_ language: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language,
                               "-LivelyOnboarding", "YES", "-conversationMode", "automatic"]
        if language == "de" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.extraExtraExtraLarge.rawValue]
        }
        app.launch()
        let next = app.buttons["onboardingNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        XCTAssertNotEqual(next.label, "Get Started")
        try checkLayout(app, action: next, name: "Welcome")

        next.tap()
        let toggle = app.switches["onlineTranslationToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let thumb = toggle.coordinate(withNormalizedOffset: CGVector(dx: language == "ar" ? 0.08 : 0.92, dy: 0.5))
        if toggle.value as? String == "1" { thumb.tap() }
        try checkLayout(app, action: next, name: "On-device translation")
        let offlineAction = next.label
        thumb.tap()
        XCTAssertNotEqual(next.label, offlineAction)
        next.tap()

        XCTAssertTrue(toggle.waitForNonExistence(timeout: 5))
        try checkLayout(app, action: next, name: "Languages")
        next.tap()
        let skip = app.buttons["onboardingSkip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        try checkLayout(app, action: skip, name: "Account")
        skip.tap()
        XCTAssertTrue(skip.waitForNonExistence(timeout: 5))
        let menu = app.buttons["conversationMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let settings = app.buttons["conversationSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertNotEqual(settings.label, "Settings")
        settings.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor private func checkLayout(_ app: XCUIApplication, action: XCUIElement, name: String) throws {
        XCTAssertTrue(action.isHittable)
        XCTAssertTrue(app.frame.contains(action.frame))
        // Measure the actual rendered text frames. The tour can scroll vertically on short displays.
        // Static demo transcripts inside the animated phone use the two speakers' languages.
        let title = app.staticTexts["tourTitle"]
        let body = app.staticTexts["tourBody"]
        if name != "Account" {
            XCTAssertTrue(title.exists && body.exists)
            XCTAssertLessThanOrEqual(title.frame.maxY, body.frame.minY + 1)
            for element in [title, body] {
                XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX - 1)
                XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX + 1)
                XCTAssertGreaterThan(element.frame.height, 0)
            }
            let category: UIContentSizeCategory = app.launchArguments.contains(UIContentSizeCategory.extraExtraExtraLarge.rawValue)
                ? .extraExtraExtraLarge : .large
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            let measured = (body.label as NSString).boundingRect(
                with: CGSize(width: body.frame.width + 1, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
            )
            XCTAssertGreaterThanOrEqual(body.frame.height + 2, measured.height, body.label)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
