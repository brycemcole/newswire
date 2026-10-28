import Foundation
import Testing
import WebKit
@testable import Newswire

struct SoFiTests {
    private var now: Date { MarketClock.calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 11))! }
    private func quote(_ price: Double, at date: Date? = nil, currency: String = "USD") -> PriceWatchQuote {
        PriceWatchQuote(price: price, currency: currency, quotedAt: date ?? now)
    }

    @Test func highOnlyRisesAndCrossingTriggersOnce() {
        var rule = SoFiTrail(symbol: "AAPL", percent: 10)
        let observed1 = rule.observe(quote(100), now: now)
        #expect(!observed1)
        #expect(rule.threshold == 90)
        let observed2 = rule.observe(quote(120, at: now.addingTimeInterval(15)), now: now.addingTimeInterval(15))
        #expect(!observed2)
        #expect(rule.threshold == 108)
        let observed3 = rule.observe(quote(108, at: now.addingTimeInterval(30)), now: now.addingTimeInterval(30))
        #expect(observed3)
        #expect(rule.high == 120)
        #expect(rule.triggeredAt == now.addingTimeInterval(30))
        let observed4 = rule.observe(quote(100, at: now.addingTimeInterval(45)), now: now.addingTimeInterval(45))
        #expect(!observed4)
        #expect(rule.lastPrice == 108)
    }

    @Test func missingStaleFutureDuplicateAndInvalidQuotesCannotMoveHigh() {
        var rule = SoFiTrail(symbol: "AAPL", percent: 5)
        let bad = [quote(200, at: now.addingTimeInterval(-301)), quote(200, at: now.addingTimeInterval(1)),
                   quote(.nan), quote(.infinity), quote(0), quote(-1), quote(200, currency: "CAD")]
        for value in bad {
            let observed = rule.observe(value, now: now)
            #expect(!observed)
        }
        #expect(rule.high == nil && rule.quotedAt == nil && rule.triggeredAt == nil)
        let observed6 = rule.observe(quote(100), now: now)
        #expect(!observed6)
        let observed7 = rule.observe(quote(90), now: now)
        #expect(!observed7)
        let observed8 = rule.observe(quote(90, at: now.addingTimeInterval(-1)), now: now)
        #expect(!observed8)
        #expect(rule.high == 100 && rule.lastPrice == 100 && rule.quotedAt == now)
    }

    @Test func calendarRejectsHolidaysEarlyCloseAndPreviousSession() {
        let holiday = MarketClock.calendar.date(from: DateComponents(year: 2026, month: 12, day: 25, hour: 11))!
        let earlyClose = MarketClock.calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 14))!
        for date in [holiday, earlyClose] {
            var rule = SoFiTrail(symbol: "AAPL", percent: 5)
            let observed9 = rule.observe(quote(100, at: date), now: date)
            #expect(!observed9)
            #expect(rule.high == nil)
            #expect(rule.status(active: true, now: date) == "Waiting for regular market hours")
        }
        let open = MarketClock.at(now, hour: 9, minute: 30)
        var rule = SoFiTrail(symbol: "AAPL", percent: 5)
        let observed10 = rule.observe(quote(100, at: open.addingTimeInterval(-1)), now: open)
        #expect(!observed10)
        #expect(rule.high == nil)
    }

    @Test func persistencePauseResetAndRecovery() throws {
        let suite = "SoFiTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SoFiTrailStore(defaults: defaults)
        try store.add(symbol: " aapl ", percent: 10)
        let id = try #require(store.rules.first?.id)
        store.ingest(symbol: "AAPL", quote: quote(100), now: now)
        let restored = SoFiTrailStore(defaults: defaults)
        #expect(restored.rules.first?.high == 100 && restored.rules.first?.quotedAt == now)
        restored.toggle(id)
        #expect(restored.ingest(symbol: "AAPL", quote: quote(80, at: now.addingTimeInterval(15)), now: now.addingTimeInterval(15)).isEmpty)
        #expect(restored.rules.first?.lastPrice == 100)
        restored.toggle(id)
        #expect(restored.ingest(symbol: "AAPL", quote: quote(80, at: now.addingTimeInterval(30)), now: now.addingTimeInterval(30)).count == 1)
        let triggered = SoFiTrailStore(defaults: defaults)
        #expect(triggered.rules.first?.triggeredAt != nil)
        #expect(triggered.ingest(symbol: "AAPL", quote: quote(70, at: now.addingTimeInterval(45)), now: now.addingTimeInterval(45)).isEmpty)
        triggered.reset(id)
        #expect(triggered.rules.first?.high == nil && triggered.rules.first?.triggeredAt == nil)
        #expect(triggered.ingest(symbol: "AAPL", quote: quote(70, at: now.addingTimeInterval(60)), now: now.addingTimeInterval(60)).isEmpty)
        #expect(triggered.rules.first?.high == 70)
    }

    @Test func contractQuoteNeverUsesUnderlying() throws {
        let suite = "SoFiTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SoFiTrailStore(defaults: defaults)
        try store.add(symbol: "AAPL261218C00250000", percent: 10)
        store.ingest(symbol: "AAPL", quote: quote(250), now: now)
        #expect(store.rules.first?.high == nil)
        store.ingest(symbol: "AAPL261218C00250000", quote: quote(8), now: now)
        #expect(store.rules.first?.high == 8)
        #expect(SoFiTrail.validSymbol("AAPL261218C00250000"))
        #expect(!SoFiTrail.validSymbol("AAPL 250 call"))
        #expect(!SoFiTrail.validSymbol("https://evil.example"))
    }

    @Test func navigationAndSavedURLRejectForeignOriginsAndCredentials() {
        for raw in ["https://www.sofi.com/dashboard/", "https://login.sofi.com/authorize"] {
            #expect(SoFiSession.allows(URL(string: raw)!))
        }
        for raw in ["http://www.sofi.com", "https://sofi.com.evil.test", "https://evilsofi.com", "https://user:pass@sofi.com", "https://sofi.com:8443"] {
            #expect(!SoFiSession.allows(URL(string: raw)!))
        }
        let suite = "SoFiTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://evil.test/wealth/app/", forKey: "sofiPortfolioPath")
        #expect(SoFiSession(defaults: defaults).resumeURL == SoFiSession.dashboard)
        defaults.set("https://www.sofi.com/wealth/app/?token=example", forKey: "sofiPortfolioPath")
        #expect(SoFiSession(defaults: defaults).resumeURL == SoFiSession.dashboard)
        #expect(!SoFiSession.isPortfolio(URL(string: "https://www.sofi.com/login/")!))
    }

    @Test func partialTablesKeepMissingValuesAndRejectAmbiguousOptions() throws {
        let data = Data(#"{"login":false,"tables":[{"headers":["Symbol","Shares","Market value","Price"],"rows":[["AAPL","2","$1,234.50","—"],["MSFT","0","$0","$500"],["NVDA","1","unavailable","$100"]]},{"headers":["Symbol","Contracts","Price"],"rows":[["AAPL","1","$8"],["AAPL261218C00250000","1","$8"]]},{"headers":["Name","Value"],"rows":[["Total","$5,000"]]}]}"#.utf8)
        let page = try JSONDecoder().decode(SoFiPage.self, from: data)
        #expect(page.holdings.count == 3)
        #expect(page.holdings[0].value == 1234.5 && page.holdings[0].price == nil)
        #expect(page.holdings[1].value == nil && page.holdings[1].price == 100)
        #expect(page.holdings[2].symbol == "AAPL261218C00250000")
        let empty = try JSONDecoder().decode(SoFiPage.self, from: Data(#"{"login":false,"tables":[]}"#.utf8))
        #expect(empty.holdings.isEmpty)
    }

    @Test func pageReaderExtractsVisibleTableWithoutPasswordOrAccountText() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.loadHTMLString("""
        <p>Private account text must not be captured</p><input type="password" value="fixture-only">
        <table><thead><tr><th>Symbol</th><th>Shares</th><th>Market value</th></tr></thead>
        <tbody><tr><td>AAPL</td><td>2</td><td>$500</td></tr></tbody></table>
        """, baseURL: nil)
        for _ in 0..<100 {
            if !webView.isLoading, (try? await webView.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let raw = try await webView.evaluateJavaScript(SoFiSession.captureScript, in: nil, contentWorld: .defaultClient)
        let text = try #require(raw as? String)
        #expect(!text.contains("fixture-only") && !text.contains("Private account"))
        let page = try JSONDecoder().decode(SoFiPage.self, from: Data(text.utf8))
        #expect(page.login)
        #expect(page.holdings.first?.symbol == "AAPL" && page.holdings.first?.value == 500)
    }

    @Test func dedicatedProfileRetainsCookiesAndClearsOnlyItsOwnData() async throws {
        let id = UUID()
        let otherID = UUID()
        let store = WKWebsiteDataStore(forIdentifier: id)
        let other = WKWebsiteDataStore(forIdentifier: otherID)
        let cookie = try #require(HTTPCookie(properties: [.domain: "example.test", .path: "/", .name: "test-session",
            .value: "fixture-only", .secure: "TRUE", .expires: Date.now.addingTimeInterval(600)]))
        await store.httpCookieStore.setCookie(cookie)
        await other.httpCookieStore.setCookie(cookie)
        let restored = WKWebsiteDataStore(forIdentifier: id)
        #expect(restored.isPersistent)
        let cookies = await restored.httpCookieStore.allCookies()
        #expect(cookies.contains { $0.name == "test-session" })
        await restored.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let cleared = await store.httpCookieStore.allCookies()
        let untouched = await other.httpCookieStore.allCookies()
        #expect(cleared.isEmpty)
        #expect(untouched.contains { $0.name == "test-session" })
        await other.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
