import XCTest

nonisolated final class PortfolioCostUITests: XCTestCase {
    @MainActor func testUnsupportedPlanFundCanSetCostWithoutChart() {
        let app = XCUIApplication()
        app.launchArguments = ["-portfolioPreview", "-portfolioCostPreview"]
        app.launch()
        let fund = app.staticTexts["SP.500.INDEX.PL.CL.D"]
        XCTAssertTrue(fund.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Unrealized unavailable"].firstMatch.exists)
        capture(app, "fund-cost-holdings")
        fund.tap()
        app.buttons.containing(.staticText, identifier: "Shares").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Position & cost"].waitForExistence(timeout: 5))
        capture(app, "fund-cost-missing")
        app.buttons["Set cost"].tap()
        let alert = app.alerts["Average cost per share"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("100")
        alert.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Using your verified cost override"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "+$200.00")).firstMatch.exists)
        capture(app, "fund-cost-override")
        app.buttons["Edit cost"].tap()
        app.alerts.buttons["Use Brokerage Cost"].tap()
        XCTAssertTrue(app.staticTexts["Cost basis unavailable from brokerage and reconciled trade history. Unrealized gain is unavailable, not zero."].waitForExistence(timeout: 5))
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
