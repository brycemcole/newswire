import XCTest

nonisolated final class MarketSessionUITests: XCTestCase {
    @MainActor func testSessionsExpandAndAlertControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-marketSessionPreview"]
        app.launch()
        XCTAssertTrue(app.buttons["Market session details"].waitForExistence(timeout: 10))
        capture(app, "session-premarket")
        app.buttons["Market session details"].tap()
        XCTAssertTrue(app.buttons["Set a market alert"].waitForExistence(timeout: 3))
        capture(app, "session-expanded")
        app.buttons["Market alerts"].tap()
        XCTAssertTrue(app.navigationBars["Market alerts"].waitForExistence(timeout: 3))
        capture(app, "session-alerts")
        app.buttons["When, Before the open"].tap()
        app.buttons["Futures move"].tap()
        XCTAssertTrue(app.buttons["Direction, Either direction"].waitForExistence(timeout: 3))
        capture(app, "session-alert-move")
        app.buttons["Done"].tap()
        app.buttons["Open"].tap()
        XCTAssertTrue(app.staticTexts["Closing bell"].waitForExistence(timeout: 3))
        capture(app, "session-open")
        app.buttons["Closed"].tap()
        XCTAssertTrue(app.buttons["Market session details"].waitForExistence(timeout: 3))
        app.buttons["Market session details"].tap()
        capture(app, "session-closed")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
