import XCTest

final class ChartInteractionTests: XCTestCase {
    @MainActor func testHoldShowsEarningsContext() throws {
        let app = XCUIApplication(bundleIdentifier: "com.brycecole.newswire.beta")
        app.launchArguments = ["-quote", "AAPL", "-chartRange", "3M", "-chartKeepSelection"]
        app.launch()
        let chart = app.descendants(matching: .any)["stock-price-chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["3M"].waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "label CONTAINS 'Hold and slide for events'")
        XCTAssertTrue(app.staticTexts.containing(ready).firstMatch.waitForExistence(timeout: 20))
        let earnings = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Earnings ·'")).firstMatch
        for step in [19, 18, 20, 21, 17] {
            chart.coordinate(withNormalizedOffset: CGVector(dx: Double(step) / 100, dy: 0.5)).press(forDuration: 0.25)
            if earnings.exists { break }
        }
        XCTAssertTrue(earnings.exists, "Expected an earnings report in Apple's three-month history")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'EPS '")).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "stock-earnings-held"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
