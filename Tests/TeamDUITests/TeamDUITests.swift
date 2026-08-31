import XCTest

@MainActor
final class TeamDUITests: XCTestCase {
    func testLaunchesCameraFlowScaffold() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["camera-flow-scaffold"].waitForExistence(timeout: 2))
    }
}
