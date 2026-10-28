import XCTest

nonisolated final class SoFiUITests: XCTestCase {
    @MainActor func testConnectionAndTrailingAlertEditor() {
        let app = XCUIApplication()
        app.launchArguments = ["-sofiPreview"]
        app.launch()
        XCTAssertTrue(app.navigationBars["SoFi on this device"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Preview · example data"].exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["Review in SoFi"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "sofi-trailing-alerts"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Add trailing alert"].tap()
        XCTAssertTrue(app.navigationBars["Trailing alert"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        let field = app.textFields["Stock or full option symbol"]
        field.tap()
        field.typeText("AAPL261218C00250000")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["SoFi on this device"].waitForExistence(timeout: 5))
    }
}
