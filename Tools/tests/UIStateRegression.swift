import XCTest

@MainActor
final class UIStateRegression: XCTestCase {
    private func save(_ app: XCUIApplication, _ name: String) {
        // Capture settled layout rather than an intermediate opacity/size frame.
        Thread.sleep(forTimeInterval: 0.4)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func fixtureApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "__UI_STATE_BUNDLE_ID__")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Failed"].waitForExistence(timeout: 8))
        return app
    }
    private func fixtureCase(_ app: XCUIApplication, _ name: String) {
        let button = app.buttons[name]
        if !button.isHittable { app.scrollViews.firstMatch.swipeLeft() }
        button.tap()
    }
    private func gone(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
    func testControlledFaceFailureAndNetwork() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        let retry = app.buttons["Translation failed · Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["翻訳に失敗しました · 再試行"].exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Retries: 1"].waitForExistence(timeout: 5))
        fixtureCase(app, "Network")
        XCTAssertTrue(app.staticTexts["Waiting for connection"].waitForExistence(timeout: 5))
        gone(retry)
        save(app, "Controlled translated-half failure and network status")
    }
    func testControlledKnownPartnerLiveAndUnknown() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        fixtureCase(app, "Known live")
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        gone(app.staticTexts["Waiting for other language"])
        XCTAssertFalse(app.buttons["Translate"].exists)
        fixtureCase(app, "Unknown")
        XCTAssertTrue(app.staticTexts["Waiting for other language"].waitForExistence(timeout: 5))
        gone(app.staticTexts["Listening"])
        save(app, "Controlled genuine unknown partner waits")
    }
    func testControlledSourceOnlyAndClosedUnknown() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        fixtureCase(app, "Source only")
        XCTAssertTrue(app.staticTexts["駅はどこですか？"].waitForExistence(timeout: 5))
        gone(app.buttons["Translation failed · Retry"])
        gone(app.staticTexts["Waiting for other language"])
        XCTAssertFalse(app.buttons["Translate"].exists)
        fixtureCase(app, "Closed unknown")
        XCTAssertTrue(app.staticTexts["Language not identified"].firstMatch.waitForExistence(timeout: 5))
        gone(app.staticTexts["Identifying language"].firstMatch)
        save(app, "Controlled final unknown source stays neutral")
    }

    func testListeningReminderFadesAndStoppedGuidanceRemains() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        fixtureCase(app, "Known live")
        app.buttons["Start reminder"].tap()
        let prompt = app.staticTexts["Listening. Go ahead and talk."]
        XCTAssertTrue(prompt.waitForExistence(timeout: 2))
        save(app, "Listening reminder visible in both reader halves")
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: prompt)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 7), .completed)
        XCTAssertTrue(app.staticTexts["Could you help me find the platform?"].exists)
        save(app, "Listening reminder fades without hiding the transcript")
        app.buttons["Dark"].tap()
        app.buttons["Large text"].tap()
        app.buttons["Start reminder"].tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 2))
        XCTAssertTrue(prompt.isHittable)
        save(app, "Dark accessibility listening reminder")
        let reader = app.scrollViews.element(boundBy: 2)
        XCTAssertTrue(reader.exists)
        XCTAssertLessThanOrEqual(reader.frame.maxY, prompt.frame.minY + 2,
                                 "the transcript viewport must end before the reminder")
        app.buttons["Stop reminder"].tap()
        let stopped = app.staticTexts["Tap the mic to start"]
        XCTAssertTrue(stopped.waitForExistence(timeout: 2))
        let stillVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stopped)
        XCTAssertEqual(XCTWaiter.wait(for: [stillVisible], timeout: 6), .timedOut)
        save(app, "Stopped guidance remains in dark accessibility layout")
    }

    func testPopulatedFaceKeepsNewestAboveGuidance() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        fixtureMenu(app, "Load history")
        app.buttons["Stop reminder"].tap()
        assertFaceLatest(app)
        save(app, "Populated face stopped guidance reserves both reader viewports")
        app.buttons["Start reminder"].tap()
        assertFaceLatest(app)
        gone(app.staticTexts["Listening. Go ahead and talk."])
        assertFaceLatest(app)
        app.buttons["Dark"].tap()
        app.buttons["Large text"].tap()
        app.buttons["Stop reminder"].tap()
        assertFaceLatest(app)
        save(app, "Populated face dark accessibility guidance keeps newest turns readable")
        app.buttons["Start reminder"].tap()
        assertFaceLatest(app)
        fixtureMenu(app, "Append turn")
        assertFaceLatest(app, 25)
        fixtureMenu(app, "Revise latest")
        assertFaceLatest(app, 25, englishLabel: "WWW WWW WWWWWW")
        save(app, "New face turn remains visible while the reminder returns")
    }

    func testPopulatedChatKeepsNewestAboveGuidance() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        fixtureMenu(app, "Chat layout")
        fixtureMenu(app, "Load history")
        assertTranscriptLatest(app)
        gone(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Listening. Go ahead and talk.")).firstMatch)
        assertTranscriptLatest(app)
        app.buttons["Stop reminder"].tap()
        assertTranscriptLatest(app)
        save(app, "Populated chat scrolls newest translation clear of stopped footer")
        app.buttons["Dark"].tap()
        app.buttons["Large text"].tap()
        assertTranscriptLatest(app)
        app.buttons["Start reminder"].tap()
        assertTranscriptLatest(app)
        fixtureMenu(app, "Append turn")
        assertTranscriptLatest(app, 25)
        fixtureMenu(app, "Revise latest")
        assertTranscriptLatest(app, 25, englishLabel: "WWW WWW WWWWWW")
        save(app, "Populated chat dark accessibility reminder and newest translation")
        app.buttons["Large text"].tap()
        app.buttons["Stop reminder"].tap()
        fixtureMenu(app, "Keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        assertTranscriptLatest(app, 25, englishLabel: "WWW WWW WWWWWW")
        save(app, "Chat keyboard and guidance reserve space above the newest translation")
    }

    func testPopulatedParallelKeepsNewestAboveGuidance() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        fixtureMenu(app, "Parallel layout")
        fixtureMenu(app, "Load history")
        assertTranscriptLatest(app)
        gone(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Listening. Go ahead and talk.")).firstMatch)
        assertTranscriptLatest(app)
        app.buttons["Stop reminder"].tap()
        assertTranscriptLatest(app)
        save(app, "Populated parallel transcript stays above stopped guidance")
        app.buttons["Dark"].tap()
        app.buttons["Large text"].tap()
        assertTranscriptLatest(app)
        app.buttons["Start reminder"].tap()
        assertTranscriptLatest(app)
        fixtureMenu(app, "Append turn")
        assertTranscriptLatest(app, 25)
        save(app, "Parallel dark accessibility reminder preserves newest row")
        app.buttons["Large text"].tap()
        assertTranscriptLatest(app, 25)
        fixtureMenu(app, "Revise latest")
        assertTranscriptLatest(app, 25, englishLabel: "WWW WWW WWWWWW")
        save(app, "Parallel same-length translation revision remains readable")
    }

    private func fixtureMenu(_ app: XCUIApplication, _ name: String) {
        app.buttons["Fixture"].tap()
        let item = app.buttons[name]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }

    func testManualHistoryPositionSurvivesGuidanceAndRevision() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        fixtureMenu(app, "Chat layout")
        fixtureMenu(app, "Load history")
        app.buttons["Stop reminder"].tap()
        assertTranscriptLatest(app)
        let viewport = listViewport(app)
        viewport.swipeDown()
        viewport.swipeDown()
        let last = latest(app)
        XCTAssertTrue(!last.exists || !last.isHittable, "the gesture must actually move away from the newest turn")
        let visible = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Latest turn "))
            .allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(visible.isEmpty, "an older readable row must anchor the history check")
        let anchor = visible[visible.count / 2]
        let anchorLabel = anchor.label
        app.buttons["Start reminder"].tap()
        let reminder = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Listening. Go ahead and talk.")).firstMatch
        let faded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: reminder)
        XCTAssertEqual(XCTWaiter.wait(for: [faded], timeout: 7), .completed)
        XCTAssertTrue(app.staticTexts[anchorLabel].isHittable, "reminder fade must preserve the row being read")
        staysOffscreen(last)
        app.buttons["Stop reminder"].tap()
        staysOffscreen(last)
        XCTAssertTrue(app.staticTexts[anchorLabel].isHittable, "stopped guidance must preserve manual history")
        fixtureMenu(app, "Revise latest")
        let revised = app.staticTexts["WWW WWW WWWWWW"]
        staysOffscreen(revised)
        XCTAssertTrue(app.staticTexts[anchorLabel].isHittable)
        save(app, "Manual history remains readable across guidance and offscreen revision")
    }

    func testContinuousSameRowUpdatesKeepNewestBottomVisible() throws {
        continueAfterFailure = false
        let app = fixtureApp()
        fixtureMenu(app, "Chat layout")
        fixtureMenu(app, "Load history")
        app.buttons["Stop reminder"].tap()
        assertTranscriptLatest(app)
        fixtureMenu(app, "Stream latest")
        let progress = app.staticTexts["Fixture streaming progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3), "streaming must start after the fixture menu dismisses")
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Streaming turn ")).firstMatch
        let viewport = listViewport(app)
        let footer = app.descendants(matching: .any)["Fixture transcript footer"].firstMatch
        for _ in 0..<3 {
            let aligned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard progress.exists, row.exists, row.isHittable else { return false }
                let text = row.frame, scroll = viewport.frame
                return text.maxY <= scroll.maxY + 2 && text.maxY <= footer.frame.minY + 2
                    && scroll.maxY - text.maxY <= 72
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 2), .completed,
                           "newest text bottom must stay in view during \(progress.label); text=\(row.frame), viewport=\(viewport.frame), footer=\(footer.frame)")
            let before = progress.label
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertTrue(progress.exists, "the assertion must run before streaming ends")
            XCTAssertNotEqual(progress.label, before, "text must still be updating during the viewport check")
        }
        save(app, "Continuous same-row translation updates remain aligned before streaming pauses")
    }

    private func latest(_ app: XCUIApplication, _ index: Int = 24) -> XCUIElement {
        app.staticTexts["Latest turn \(index)"].firstMatch
    }

    private func staysOffscreen(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let jumped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [jumped], timeout: 1), .timedOut,
                       "deferred layout work must not jump away from manually selected history", file: file, line: line)
    }

    private func listViewport(_ app: XCUIApplication) -> XCUIElement {
        if app.collectionViews.firstMatch.exists { return app.collectionViews.firstMatch }
        return app.tables.firstMatch
    }

    private func assertReadable(_ row: XCUIElement, viewport: XCUIElement,
                                footer: XCUIElement? = nil, inverted: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(viewport.exists, "actual scroll viewport must exist", file: file, line: line)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard row.exists, viewport.exists, row.isHittable else { return false }
            let text = row.frame, scroll = viewport.frame
            guard text.height > 0, scroll.height > 0,
                  text.minY >= scroll.minY - 2, text.maxY <= scroll.maxY + 2 else { return false }
            if let footer, footer.exists {
                if inverted && text.minY < footer.frame.maxY - 2 { return false }
                if !inverted && text.maxY > footer.frame.minY + 2 { return false }
            }
            let gap = inverted ? text.minY - scroll.minY : scroll.maxY - text.maxY
            // A full-screen scroll view includes the home-indicator safe area
            // as well as the production transcript's bottom content padding.
            return gap <= 72
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                       "newest text must be readable at its viewport edge; text=\(row.frame), viewport=\(viewport.frame), footer=\(footer?.frame ?? .zero)",
                       file: file, line: line)
    }

    private func assertFaceLatest(_ app: XCUIApplication, _ index: Int = 24,
                                  englishLabel: String? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let readers = app.scrollViews
        let nearPrompt = app.staticTexts["Tap the mic to start"].firstMatch
        let farPrompt = app.staticTexts["マイクをタップして開始"].firstMatch
        assertReadable(englishLabel.map { app.staticTexts[$0].firstMatch } ?? latest(app, index), viewport: readers.element(boundBy: 2),
                       footer: nearPrompt.exists ? nearPrompt : nil, file: file, line: line)
        assertReadable(app.staticTexts["最新の発言 \(index)"].firstMatch, viewport: readers.element(boundBy: 1),
                       footer: farPrompt.exists ? farPrompt : nil, inverted: true, file: file, line: line)
    }

    private func assertTranscriptLatest(_ app: XCUIApplication, _ index: Int = 24,
                                        englishLabel: String? = nil,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let footer = app.descendants(matching: .any)["Fixture transcript footer"].firstMatch
        XCTAssertTrue(footer.exists, file: file, line: line)
        assertReadable(englishLabel.map { app.staticTexts[$0].firstMatch } ?? latest(app, index), viewport: listViewport(app), footer: footer, file: file, line: line)
    }
}
