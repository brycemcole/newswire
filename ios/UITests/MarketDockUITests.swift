import XCTest

final class MarketDockUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-storyURL", "https://example.com/dock-fixture", "[TEST] Dock dismissal"]
        app.launch()
        XCTAssertTrue(app.staticTexts["[TEST] Dock dismissal"].waitForExistence(timeout: 15))
    }

    private var handle: XCUIElement { app.buttons["market-dock-handle"] }

    private func expectDetent(_ value: String) {
        let predicate = NSPredicate { element, _ in
            (element as? XCUIElement)?.value as? String == value
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: handle)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBackgroundBackButtonCollapsesAndStillNavigates() {
        handle.tap()
        expectDetent("Expanded")
        capture("dock-half-open")

        app.navigationBars.buttons.element(boundBy: 0).tap()

        expectDetent("Collapsed")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        capture("dock-dismissed-after-back")

        handle.tap()
        expectDetent("Expanded")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture("settings-opens-on-first-tap")
    }

    func testDockInteriorDoesNotCollapseButBackgroundScrollDoes() {
        handle.tap()
        expectDetent("Expanded")
        app.buttons["Losers"].tap()
        expectDetent("Expanded")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10)))

        expectDetent("Collapsed")
        capture("dock-dismissed-after-background-scroll")
    }
}
