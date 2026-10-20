import Foundation
import Testing
@testable import Newswire

struct MarketQuoteTests {
    private func quote(state: String, postTime: Int = 200, postPrice: Double = 102) throws -> MarketQuote {
        let data = Data("""
        {"symbol":"SPY","regularMarketPrice":100,"regularMarketTime":100,
         "regularMarketChange":-1,"regularMarketChangePercent":-0.99,
         "marketState":"\(state)","postMarketPrice":\(postPrice),"postMarketTime":\(postTime),
         "preMarketPrice":103,"preMarketTime":300}
        """.utf8)
        return try #require(MarketQuote(JSONDecoder().decode(YValue.self, from: data)))
    }

    @Test func extendedSessionUsesPriceAndChangeFromClose() throws {
        let post = try quote(state: "POST")
        #expect(post.price == 102 && post.change == 2 && post.changePercent == 2)
        #expect(post.extendedLabel == "After")
        let pre = try quote(state: "PRE")
        #expect(pre.price == 103 && pre.changePercent == 3 && pre.extendedLabel == "Pre")
        let flat = try quote(state: "POST", postPrice: 100)
        #expect(flat.extendedLabel == "After" && flat.changePercent == 0)
    }

    @Test func regularAndStaleExtendedQuotesFallBack() throws {
        for value in [try quote(state: "REGULAR"), try quote(state: "CLOSED", postTime: 50)] {
            #expect(value.price == 100 && value.changePercent == -0.99 && value.extendedLabel == nil)
        }
        #expect(try quote(state: "CLOSED").price == 102)
    }

    @Test func observedAtFollowsTheSelectedSessionTimestamp() throws {
        #expect(try quote(state: "POST").observedAt == Date(timeIntervalSince1970: 200))
        #expect(try quote(state: "PRE").observedAt == Date(timeIntervalSince1970: 300))
        #expect(try quote(state: "REGULAR").observedAt == Date(timeIntervalSince1970: 100))
        #expect(try quote(state: "CLOSED", postTime: 50).observedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func indexesFundsAndUnknownSourceTimesUseTheirOwnWindows() throws {
        func quote(_ symbol: String, type: String, time: String?) throws -> MarketQuote {
            let stamp = time.map { ",\"regularMarketTime\":\(Int(ISO8601DateFormatter().date(from: $0)!.timeIntervalSince1970))" } ?? ""
            let data = Data("""
            {"symbol":"\(symbol)","quoteType":"\(type)","regularMarketPrice":100\(stamp),
             "regularMarketChange":1,"regularMarketChangePercent":1,"marketState":"REGULAR"}
            """.utf8)
            return try #require(MarketQuote(JSONDecoder().decode(YValue.self, from: data)))
        }
        let monday = ISO8601DateFormatter().date(from: "2026-10-19T15:00:00Z")!
        let indexAfterClose = ISO8601DateFormatter().date(from: "2026-10-19T21:00:00Z")!
        #expect(try quote("^VIX", type: "INDEX", time: "2026-10-19T14:50:00Z").freshness(at: monday) == .live)
        #expect(try quote("^VIX", type: "INDEX", time: "2026-10-19T14:00:00Z").freshness(at: monday) == .delayed(minutes: 60))
        #expect(try quote("^TNX", type: "INDEX", time: "2026-10-19T19:50:00Z").freshness(at: indexAfterClose) == .closed)
        #expect(try quote("VFIAX", type: "MUTUALFUND", time: "2026-10-19T14:00:00Z").freshness(at: monday) == .closed)
        let unknown = try quote("NVDA", type: "EQUITY", time: nil)
        #expect(unknown.freshness(at: monday) == .unknown)
        #expect(QuoteFreshness.unknown.notice?.text == "Source time unknown")
    }

    @Test func freshnessSeparatesDelayFromNormalClosure() throws {
        func stamped(_ iso: String, type: String = "ETF") throws -> MarketQuote {
            let time = Int(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970)
            let data = Data("""
            {"symbol":"SPY","quoteType":"\(type)","regularMarketPrice":100,"regularMarketTime":\(time),
             "regularMarketChange":1,"regularMarketChangePercent":1,"marketState":"REGULAR"}
            """.utf8)
            return try #require(MarketQuote(JSONDecoder().decode(YValue.self, from: data)))
        }
        let fridayClose = "2026-10-16T20:00:00Z", sundayNoon = "2026-10-18T12:00:00Z", mondayAfternoon = "2026-10-19T15:00:00Z"
        let sunday = ISO8601DateFormatter().date(from: sundayNoon)!
        let monday = ISO8601DateFormatter().date(from: mondayAfternoon)!
        #expect(try stamped(fridayClose).freshness(at: sunday) == .closed)
        #expect(try stamped("2026-10-19T14:50:00Z").freshness(at: monday) == .live)
        #expect(try stamped("2026-10-19T14:00:00Z").freshness(at: monday) == .delayed(minutes: 60))
        #expect(try stamped("2026-10-18T11:50:00Z", type: "CRYPTOCURRENCY").freshness(at: sunday) == .live)
        #expect(try stamped("2026-10-18T11:50:00Z").freshness(at: sunday) == .closed)
    }
}
