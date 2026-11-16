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

}
