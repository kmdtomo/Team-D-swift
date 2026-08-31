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
}
