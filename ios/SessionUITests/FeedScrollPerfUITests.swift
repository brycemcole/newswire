import XCTest

nonisolated final class FeedScrollPerfUITests: XCTestCase {
    private let framesPath = "/tmp/newswire-frames.json"

    private func readFrames() -> [String: Double] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: framesPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
        return json
    }

    @MainActor private func fling(_ app: XCUIApplication, up: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.62 : 0.2))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.2 : 0.62))
        from.press(forDuration: 0.02, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    @MainActor private func launchSyntheticFeed() throws -> XCUIApplication {
        let app = XCUIApplication()
        let symbols = ["AAPL", "MSFT", "NVDA", "TSLA", "AMZN", "META", "GOOGL", "AMD", "INTC", "MU", "NU", "JPM", "BAC", "XOM", "CVX", "DIS", "NFLX", "PYPL", "UBER", "SHOP"]
        let stories: [[String: Any]] = (0..<120).map { index in
            let tickers = index % 5 == 4 ? [] : (0..<(1 + index % 3)).map { symbols[(index * 3 + $0 * 7) % symbols.count] }
            return ["id": "perf-\(index)", "externalId": "perf-\(index)",
                    "title": "[TEST] Headline \(index) about markets, earnings and rates moving shares today",
                    "summary": "Synthetic summary text for checking scroll smoothness of the home feed with several lines of copy.", "body": "",
                    "source": "Perf QA", "url": "https://example.com/perf-\(index)",
                    "publishedAt": Date.now.timeIntervalSinceReferenceDate - Double(index * 60),
                    "receivedAt": Date.now.timeIntervalSinceReferenceDate,
                    "category": "markets", "priority": "normal", "tickers": tickers, "tags": [],
                    "agent": "preview"]
        }
        let page: [String: Any] = ["stories": stories, "fetchedAt": Date.now.timeIntervalSinceReferenceDate]
        app.launchEnvironment["NEWSWIRE_TEST_URL"] = "https://feed-perf.invalid"
        app.launchEnvironment["NEWSWIRE_TEST_QUOTES"] = "1"
        app.launchEnvironment["NEWSWIRE_FRAME_STATS"] = framesPath
        app.launchEnvironment["NEWSWIRE_TEST_FEED"] = String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self)
        app.launch()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 20))
        sleep(5)
        return app
    }

    @MainActor func testStorySwipeBackHitches() throws {
        continueAfterFailure = false
        let app = try launchSyntheticFeed()
        fling(app, up: true)
        sleep(2)
        let headlines = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "[TEST] Headline"))
        var hitch = 0.0, slow = 0.0, worst = 0.0
        for index in 0..<4 {
            let row = headlines.element(boundBy: index % 2)
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            sleep(3)
            let before = readFrames()
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)), withVelocity: .default, thenHoldForDuration: 0)
            sleep(2)
            let after = readFrames()
            XCTAssertTrue(row.exists)
            hitch += (after["hitchMs"] ?? 0) - (before["hitchMs"] ?? 0)
            slow += (after["over25"] ?? 0) - (before["over25"] ?? 0)
            worst = max(worst, after["worstMs"] ?? 0)
        }
        print("SWIPE_BACK_STATS hitchMs=\(hitch) framesOver25ms=\(slow)")
    }

    @MainActor func testHomeFeedScrollHitches() throws {
        continueAfterFailure = false
        let app = try launchSyntheticFeed()
        for _ in 0..<2 { fling(app, up: true) }
        sleep(2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "feed"
        shot.lifetime = .keepAlways
        add(shot)
        for _ in 0..<2 { fling(app, up: false) }
        let options = XCTMeasureOptions()
        options.iterationCount = Int(ProcessInfo.processInfo.environment["PERF_ITERATIONS"] ?? "") ?? 3
        sleep(1)
        let before = readFrames()
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<6 { fling(app, up: true) }
            for _ in 0..<6 { fling(app, up: false) }
        }
        sleep(1)
        let after = readFrames()
        let frames = (after["frames"] ?? 0) - (before["frames"] ?? 0)
        let hitch = (after["hitchMs"] ?? 0) - (before["hitchMs"] ?? 0)
        let slow = (after["over25"] ?? 0) - (before["over25"] ?? 0)
        print("FRAME_STATS frames=\(frames) hitchMs=\(hitch) framesOver25ms=\(slow) worstMs=\(after["worstMs"] ?? 0)")
    }
}