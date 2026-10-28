import XCTest

nonisolated final class PriceWatchUITests: XCTestCase {
    @MainActor func testChooseAlertTypeAndReviewDelivery() {
        let app = XCUIApplication()
        app.launchArguments = ["-priceWatchPreview"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Live prices and alerts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Target price"].exists)
        app.buttons["Alert, Target price"].tap()
        app.buttons["Percentage move"].tap()
        XCTAssertTrue(app.buttons["Daily move, 1%"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Target price"].exists)
        capture(app, "percentage-move-setup")
        app.buttons["Alert, Percentage move"].tap()
        app.buttons["Live Activity only"].tap()
        XCTAssertTrue(app.buttons["Add live price"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Frequent Live Activity updates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open notification and Live Activity settings"].exists)
        capture(app, "price-alert-delivery-setup")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
