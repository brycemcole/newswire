import XCTest

nonisolated final class TopicSwitchUITests: XCTestCase {
    @MainActor func testTopicsShowLoadedHeadlinesWithoutNetwork() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let categories = ["markets", "technology", "economy", "politics", "world", "science", "general"]
        let stories: [[String: Any]] = (0..<84).map { index in
            let category = categories[index % categories.count]
            return ["id": "topic-\(index)", "externalId": "topic-\(index)",
                    "title": "[TEST] \(category.capitalized) headline \(index)",
                    "summary": "Synthetic news for checking topic switching while offline.", "body": "",
                    "source": "Topic QA", "url": "https://example.com/topic-\(index)",
                    "publishedAt": Date.now.timeIntervalSinceReferenceDate - Double(index * 60),
                    "receivedAt": Date.now.timeIntervalSinceReferenceDate,
                    "category": category, "priority": "normal", "tickers": [], "tags": [],
                    "agent": "preview"]
        }
        let page: [String: Any] = ["stories": stories, "fetchedAt": Date.now.timeIntervalSinceReferenceDate]
        app.launchEnvironment["NEWSWIRE_TEST_URL"] = "https://topic-switch.invalid"
        app.launchEnvironment["NEWSWIRE_TEST_FEED"] = String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self)
        app.launch()
        let markets = app.buttons["news-topic-markets"]
        for _ in 0..<6 {
            if markets.isHittable && markets.frame.midY < app.frame.height * 0.65 { break }
            app.swipeUp()
        }
        XCTAssertTrue(markets.isHittable)
        capture(app, "topics-all")
        for category in ["Markets", "Technology", "Markets", "General", "All", "Technology"] {
            let start = Date.now
            let button = app.buttons["news-topic-\(category.lowercased())"]
            button.tap()
            XCTAssertTrue(button.isSelected)
            let title = category == "All" ? "[TEST] Markets headline 0" : category == "General" ? "[TEST] General headline 6" : category == "Markets" ? "[TEST] Markets headline 0" : "[TEST] Technology headline 1"
            let visible = app.staticTexts[title].firstMatch.waitForExistence(timeout: 3)
            print("TOPIC_LATENCY \(category) \(Date.now.timeIntervalSince(start)) visible=\(visible)")
            capture(app, "topics-\(category.lowercased())")
            XCTAssertTrue(visible, "Already-loaded headlines should appear without a network response")
        }
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
