import XCTest

@MainActor
final class TeamDUITests: XCTestCase {
    func testColdLaunchEntersCameraFlowWithoutHomeOrTabs() {
        let app = XCUIApplication()
        app.launch()

        let frontCapture = app.staticTexts["capture-front-1-of-4"]
        XCTAssertTrue(frontCapture.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["fixture-mode-badge"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["ホーム"].exists)
        XCTAssertFalse(app.staticTexts["一覧"].exists)
    }

    func testDeniedCameraKeepsCaptureFlowAndOffersSettingsAndImageFallback() {
        let app = XCUIApplication()
        app.launchArguments += ["-TeamDUICameraAuthorization", "denied"]
        app.launch()

        XCTAssertTrue(app.otherElements["capture-recovery"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["capture-recovery-instruction"].exists)
        XCTAssertTrue(app.buttons["capture-recovery-open-settings"].exists)
        XCTAssertTrue(app.buttons["capture-recovery-photo-picker"].exists)
        XCTAssertTrue(app.buttons["capture-recovery-file-importer"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["ホーム"].exists)
        XCTAssertFalse(app.staticTexts["一覧"].exists)
    }
}
