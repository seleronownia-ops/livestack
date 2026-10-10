import XCTest

/// A smoke test of the tab shell. It runs without Photos access and only checks that the screens exist.
final class LiveStackUITests: XCTestCase {
    func testTabsExist() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Loops"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Loops"].tap()
        XCTAssertTrue(app.staticTexts["No loops yet"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Reel"].tap()
        XCTAssertTrue(app.staticTexts["Your reel preview"].waitForExistence(timeout: 3))
    }
}
