import Foundation
import Testing
@testable import Newswire

@MainActor
private final class QuoteFeedStub {
    var now: Date
    var replies: [Result<[MarketQuote], Error>] = []
    var requested: [[String]] = []

    init(now: Date) { self.now = now }

    func fetch(_ symbols: [String]) throws -> [MarketQuote] {
        requested.append(symbols)
        return try replies.removeFirst().get()
    }
}

@MainActor
struct MarketBoardFreshnessTests {
    private func quote(_ symbol: String, observed: Date) throws -> MarketQuote {
        let time = Int(observed.timeIntervalSince1970)
        let data = Data("""
        {"symbol":"\(symbol)","quoteType":"ETF","regularMarketPrice":100,"regularMarketTime":\(time),
         "regularMarketChange":1,"regularMarketChangePercent":1,"marketState":"REGULAR"}
        """.utf8)
        return try #require(MarketQuote(JSONDecoder().decode(YValue.self, from: data)))
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func failedRefreshKeepsCachedQuoteAndMarksItUnavailable() async throws {
        let feed = QuoteFeedStub(now: date("2026-10-19T15:00:00Z"))
        let board = MarketBoard(fetchQuotes: { try feed.fetch($0) }, fetchSparks: { _ in [:] }, clock: { feed.now })

        feed.replies = [.success([try quote("SPY", observed: feed.now)])]
        await board.refresh(quotes: ["SPY"], sparks: [])
        #expect(board.freshness(of: "SPY", now: feed.now) == .live)

        feed.now = feed.now.addingTimeInterval(60)
        feed.replies = [.failure(URLError(.notConnectedToInternet))]
        await board.refresh(quotes: ["SPY"], sparks: [])
        #expect(board.quotes["SPY"] != nil)
        #expect(board.quoteStatus["SPY"] == .failed)
        #expect(board.freshness(of: "SPY", now: feed.now) == .unavailable)
    }

    @Test func partialResponseMarksOnlyTheMissingSymbolAndRecovers() async throws {
        let feed = QuoteFeedStub(now: date("2026-10-19T15:00:00Z"))
        let board = MarketBoard(fetchQuotes: { try feed.fetch($0) }, fetchSparks: { _ in [:] }, clock: { feed.now })

        feed.replies = [.success([try quote("SPY", observed: feed.now), try quote("QQQ", observed: feed.now)])]
        await board.refresh(quotes: ["SPY", "QQQ"], sparks: [])

        feed.now = feed.now.addingTimeInterval(60)
        feed.replies = [.success([try quote("SPY", observed: feed.now)])]
        await board.refresh(quotes: ["SPY", "QQQ"], sparks: [])
        #expect(board.quoteStatus["SPY"] == .ok)
        #expect(board.quoteStatus["QQQ"] == .missing)
        #expect(board.quotes["QQQ"] != nil)
        #expect(board.freshness(of: "QQQ", now: feed.now) == .unavailable)

        feed.now = feed.now.addingTimeInterval(60)
        feed.replies = [.success([try quote("QQQ", observed: feed.now)])]
        await board.refresh(quotes: ["QQQ"], sparks: [])
        #expect(board.quoteStatus["QQQ"] == .ok)
        #expect(board.freshness(of: "QQQ", now: feed.now) == .live)
    }

    @Test func unknownSymbolHasNoFreshnessUntilRequested() {
        let feed = QuoteFeedStub(now: date("2026-10-19T15:00:00Z"))
        let board = MarketBoard(fetchQuotes: { try feed.fetch($0) }, fetchSparks: { _ in [:] }, clock: { feed.now })
        #expect(board.freshness(of: "NVDA", now: feed.now) == nil)
    }
}
