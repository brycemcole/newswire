import Foundation
import Testing
@testable import Newswire

struct PriceWatchTests {
    @Test func legacyWatchesKeepTheirMeaning() throws {
        let data = Data(#"{"id":"old","symbol":"SPY","direction":"above"}"#.utf8)
        let watch = try JSONDecoder().decode(PriceWatch.self, from: data)
        #expect(watch.percent == nil)
        #expect(watch.target == nil)
        #expect(watch.alertDescription.contains("no price notification"))
    }

    @Test func percentageWatchesRoundTrip() throws {
        let watch = PriceWatch(symbol: "SPY", target: nil, direction: "either", percent: 1)
        let restored = try JSONDecoder().decode(PriceWatch.self, from: JSONEncoder().encode(watch))
        #expect(restored == watch)
        #expect(restored.alertDescription.contains("±1%"))
    }

    @Test func directQuotesPreserveSourceTimeAndChooseNewestObservation() throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        func parse(_ meta: String, _ closes: String = "[10200]", _ stamps: String = "[1799999940]") throws -> PriceWatchQuote? {
            let data = Data("{\"meta\":{\"currency\":\"GBp\",\(meta)},\"timestamp\":\(stamps),\"indicators\":{\"quote\":[{\"close\":\(closes)}]}}".utf8)
            return PriceWatchQuote.parse(try JSONDecoder().decode(YValue.self, from: data), now: now)
        }
        let current = try #require(try parse("\"regularMarketPrice\":10300,\"regularMarketTime\":1800000000"))
        #expect(current.price == 103)
        #expect(current.currency == "GBP")
        #expect(current.quotedAt == now)
        #expect(try parse("\"regularMarketPrice\":10300,\"regularMarketTime\":1800000120")?.quotedAt == now.addingTimeInterval(-60))
        #expect(try parse("\"regularMarketPrice\":10300", "[null]", "[1800000000]") == nil)
        let extended = try #require(try parse("\"regularMarketPrice\":10300,\"regularMarketTime\":1799999900", "[10400]", "[1800000000]"))
        #expect(extended.price == 104)
        #expect(extended.quotedAt == now)
        #expect(current.canReplace(now.addingTimeInterval(-1), now: now))
        #expect(!current.canReplace(now, now: now))
        #expect(!current.canReplace(now.addingTimeInterval(1), now: now))
        #expect(!current.canReplace(now.addingTimeInterval(-1), now: now.addingTimeInterval(301)))
        #expect(!current.canReplace(now.addingTimeInterval(-1), now: now.addingTimeInterval(-61)))
        let watch = PriceWatch(symbol: "TEST", target: 103, direction: "above")
        #expect(current.state(for: watch, now: now).reached)
    }
}
