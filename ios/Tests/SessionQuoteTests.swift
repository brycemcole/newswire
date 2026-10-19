import Foundation
import Testing
@testable import Newswire

struct SessionQuoteTests {
    @Test func nullBarsCannotMakeOldPricesLookFresh() throws {
        let root = try JSONDecoder().decode(YValue.self, from: Data(#"{"chart":{"result":[{"meta":{"chartPreviousClose":100},"timestamp":[1000,1300,1600],"indicators":{"quote":[{"close":[100,101,null]}]}}]}}"#.utf8))
        let quote = try #require(SessionQuote.parse(root, symbol: "ES=F"))
        #expect(quote.at == Date(timeIntervalSince1970: 1300))
        #expect(quote.price == 101)
        #expect(abs(quote.change - 1) < 0.0001)
        #expect(quote.points == [100, 101])
        let overridden = try #require(SessionQuote.parse(root, symbol: "ES=F", baseline: 101))
        #expect(overridden.change == 0)
    }

    @Test func emptyWeekendBarsNeedFallback() throws {
        let root = try JSONDecoder().decode(YValue.self, from: Data(#"{"chart":{"result":[{"meta":{"chartPreviousClose":100},"indicators":{"quote":[{"close":[]}]}}]}}"#.utf8))
        #expect(SessionQuote.parse(root, symbol: "ES=F") == nil)
    }
}
