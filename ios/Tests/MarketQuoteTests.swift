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
}
