import XCTest

@MainActor final class MarketDockUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments = ["-storyURL", "https://example.com/dock-fixture", "[TEST] Dock dismissal"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["[TEST] Dock dismissal"].waitForExistence(timeout: 15))
    }

    private var handle: XCUIElement { app.buttons["market-dock-handle"] }

    private func expectDetent(_ value: String) {
        let predicate = NSPredicate { element, _ in (element as? XCUIElement)?.value as? String == value }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: handle)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func beginSearch(_ query: String) {
        let field = app.textFields["Search markets"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != "Search markets" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(query)
    }

    private func ticker(_ symbol: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(symbol),")).firstMatch
    }

    func testStoryDockSearchQuoteBackPreservesArticleAndRepeatedSelectionWorks() {
        launch(["-marketSearch", "-marketSearchFixture", "retry"])
        XCTAssertTrue(app.staticTexts["[TEST] Dock dismissal"].waitForExistence(timeout: 5))
        beginSearch("Apple")
        let retry = app.buttons["Try again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(ticker("AAPL").waitForExistence(timeout: 5))
        capture("story-search-results")
        ticker("AAPL").tap()
        XCTAssertTrue(app.navigationBars.containing(.staticText, identifier: "AAPL").firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["[TEST] Dock dismissal"].waitForExistence(timeout: 10))
        capture("article-restored-after-quote")

        beginSearch("Microsoft")
        XCTAssertTrue(ticker("MSFT").waitForExistence(timeout: 5))
        ticker("MSFT").tap()
        XCTAssertTrue(app.navigationBars.containing(.staticText, identifier: "MSFT").firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["[TEST] Dock dismissal"].waitForExistence(timeout: 10))
        beginSearch("Apple")
        XCTAssertTrue(ticker("AAPL").waitForExistence(timeout: 5))
        ticker("AAPL").tap()
        XCTAssertTrue(app.navigationBars.containing(.staticText, identifier: "AAPL").firstMatch.waitForExistence(timeout: 10))
        capture("repeated-ticker-selection")
    }

    func testSearchRetryRecoversFromFixtureFailure() {
        launch(["-marketSearch", "-searchQuery", "Apple", "-marketSearchFixture", "retry"])
        let retry = app.buttons["Try again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        capture("search-failure-retry")
        retry.tap()
        XCTAssertTrue(ticker("AAPL").waitForExistence(timeout: 10))
        capture("search-retry-success")
    }

    func testSettingsDoneAndConnectionCancelSave() {
        launch()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        capture("settings-before-done")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))

        app.buttons["Settings"].tap()
        app.cells.containing(.staticText, identifier: "Server URL").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Connection"].waitForExistence(timeout: 5))
        let field = app.textFields["https://your-server"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://cancel.example.com")
        capture("connection-cancel-edit")
        app.buttons["Cancel"].tap()
        app.cells.containing(.staticText, identifier: "Server URL").firstMatch.tap()
        XCTAssertFalse(app.textFields["https://your-server"].value as? String == "https://cancel.example.com")
        let urlField = app.textFields["https://your-server"]
        urlField.tap()
        if let current = urlField.value as? String {
            urlField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        urlField.typeText("https://save.example.com")
        capture("connection-save-edit")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testBackgroundBackButtonCollapsesAndStillNavigates() {
        launch()
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
        launch()
        handle.tap()
        expectDetent("Expanded")
        app.buttons["Losers"].tap()
        expectDetent("Expanded")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10)))
        expectDetent("Collapsed")
        capture("dock-dismissed-after-background-scroll")
    }
    func testSavedWireAndBrainStoriesPersistAndCanBeRemoved() {
        app.launchArguments = ["-savedStoriesPreview"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Saved Stories Preview"].waitForExistence(timeout: 10))
        while app.buttons["Remove saved story"].firstMatch.exists { app.buttons["Remove saved story"].firstMatch.tap() }
        app.buttons["Save story"].firstMatch.tap()
        app.buttons["Save story"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Saved (2)"].waitForExistence(timeout: 5))
        capture("wire-and-brain-saved")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Saved (2)"].waitForExistence(timeout: 10))
        let ordinary = app.staticTexts.matching(identifier: "Fixture: Federal Reserve holds rates").allElementsBoundByIndex.last!
        ordinary.tap()
        XCTAssertTrue(app.buttons["Remove saved story"].waitForExistence(timeout: 5))
        capture("saved-ordinary-offline-reader")
        app.buttons["Remove saved story"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Saved (1)"].waitForExistence(timeout: 5))
        app.staticTexts.matching(identifier: "Fixture: Brain market signal").allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(app.buttons["Remove saved story"].waitForExistence(timeout: 5))
        capture("saved-brain-reader")
    }

    func testAskRetryAndJumpToLatestAreDiscoverable() {
        app.launchArguments = ["-askMarkets", "-askFailure"]
        app.launch()
        XCTAssertTrue(app.buttons["Retry answer"].waitForExistence(timeout: 15))
        capture("ask-failed-answer-recovery")
        app.terminate()
        app.launchArguments = ["-askMarkets", "-askLongThread"]
        app.launch()
        XCTAssertTrue(app.buttons["Jump to latest"].waitForExistence(timeout: 15))
        capture("ask-reading-history")
        app.buttons["Jump to latest"].tap()
        XCTAssertTrue(app.staticTexts["Question 24: What changed in markets?"].waitForExistence(timeout: 5))
        capture("ask-latest-answer")
    }

    func testExploreGroupsAndSearch() {
        app.launchArguments = ["-exploreDataTools"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Data Tools"].waitForExistence(timeout: 15))
        capture("explore-grouped-tools")
    }

    func testDockOpensDataToolsAndToolsOpenFromThere() {
        app.launchArguments = ["-marketSearch"]
        app.launch()
        let explore = app.buttons["explore-data-tools"]
        XCTAssertTrue(explore.waitForExistence(timeout: 15))
        explore.tap()
        XCTAssertTrue(app.navigationBars["Data Tools"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Search markets"].exists)
        let search = app.searchFields["Search data tools"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("House")
        let tool = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "House trades")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        tool.tap()
        XCTAssertTrue(app.navigationBars["House Trades"].waitForExistence(timeout: 5))
        capture("house-trades-from-data-tools")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Data Tools"].waitForExistence(timeout: 5))
    }

}
