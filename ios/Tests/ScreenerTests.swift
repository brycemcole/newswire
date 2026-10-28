import Foundation
import Testing
@testable import Newswire

@MainActor
struct ScreenerTests {
    private func row(_ symbol: String, change: Double = 1, volume: Double? = nil, average: Double? = nil, iv: Double? = nil) throws -> ScreenerRow {
        var json = #"{"symbol":"\#(symbol)","longName":"\#(symbol) Inc","quoteType":"EQUITY","regularMarketPrice":10,"regularMarketChange":0.1,"regularMarketChangePercent":\#(change),"marketState":"REGULAR""#
        if let volume { json += #","regularMarketVolume":\#(volume)"# }
        if let average { json += #","averageDailyVolume3Month":\#(average)"# }
        json += "}"
        var parsed = try #require(ScreenerRow(JSONDecoder().decode(YValue.self, from: Data(json.utf8))))
        parsed.impliedVolatility = iv
        return parsed
    }

    private func preset(_ id: String) throws -> ScreenerPreset { try #require(ScreenerPreset.preset(id)) }

    @Test func requestBodyEncodesSortAndFilters() throws {
        let body = try preset("gainers").requestBody()
        #expect(body["sortField"] as? String == "percentchange")
        #expect(body["sortType"] as? String == "DESC")
        let operands = ((body["query"] as? [String: Any])?["operands"] as? [[String: Any]]) ?? []
        #expect(operands.count == 3)
        #expect(operands.first?["operator"] as? String == "eq")
        #expect(try preset("losers").requestBody()["sortType"] as? String == "ASC")
    }

    @Test func criteriaIsGeneratedFromFilters() throws {
        let text = try preset("smallcap").criteria
        #expect(text.contains("US listed"))
        #expect(text.contains("Cap $300M–$2B"))
    }

    @Test func unusualVolumeKeepsOnlyElevatedNamesRankedByRatio() throws {
        let rows = try [row("A", volume: 3_000_000, average: 1_000_000), row("B", volume: 1_200_000, average: 1_000_000),
                        row("C", volume: 5_000_000, average: 1_000_000), row("D", volume: 9_000_000)]
        let ranked = ScreenerRanking.apply(try preset("unusual"), to: rows).map(\.symbol)
        #expect(ranked == ["C", "A"])
    }

    @Test func volatilityRankingDropsNamesWithoutIVAndOrdersDescending() throws {
        let rows = try [row("A", iv: 0.4), row("B"), row("C", iv: 1.2), row("D", iv: 0.9)]
        #expect(ScreenerRanking.apply(try preset("iv"), to: rows).map(\.symbol) == ["C", "D", "A"])
    }

    @Test func cryptoRankingSortsByChangeBothWays() throws {
        let rows = try [row("A-USD", change: 3), row("B-USD", change: -5), row("C-USD", change: 8)]
        #expect(ScreenerRanking.apply(try preset("cryptoGainers"), to: rows).map(\.symbol) == ["C-USD", "A-USD", "B-USD"])
        #expect(ScreenerRanking.apply(try preset("cryptoLosers"), to: rows).map(\.symbol) == ["B-USD", "A-USD", "C-USD"])
        #expect(try row("BTC-USD").label == "BTC")
    }

    @Test func impliedVolatilityParsingUsesNearestLiquidStrikeAndSkipsJunk() throws {
        let json = """
        {"optionChain":{"result":[{"quote":{"regularMarketPrice":100},"options":[{"expirationDate":1800000000,
        "calls":[{"strike":100,"impliedVolatility":0.0001,"bid":0,"ask":0,"lastPrice":0},{"strike":105,"impliedVolatility":0.6,"bid":1,"ask":2,"lastPrice":2}],
        "puts":[{"strike":100,"impliedVolatility":0.5,"bid":1,"ask":2,"lastPrice":2},{"strike":95,"impliedVolatility":0.9,"bid":1,"ask":2,"lastPrice":2}]}]}]}}
        """
        let value = try #require(ImpliedVolatility.parse(JSONDecoder().decode(YValue.self, from: Data(json.utf8)), fetchedAt: .now))
        #expect(abs(value.value - 0.55) < 0.0001)
    }

    @Test func closedMarketSolvesFromLastTradeAndFlagsEstimate() throws {
        let expiry = Date.now.addingTimeInterval(30 * 86_400)
        let premium = BlackScholes.price(call: true, spot: 100, strike: 100, years: BlackScholes.years(from: .now, to: expiry), volatility: 0.8)
        let json = """
        {"optionChain":{"result":[{"quote":{"regularMarketPrice":100},"options":[{"expirationDate":\(Int(expiry.timeIntervalSince1970)),
        "calls":[{"strike":100,"impliedVolatility":0.00001,"bid":0,"ask":0,"lastPrice":\(premium)}],"puts":[]}]}]}}
        """
        let value = try #require(ImpliedVolatility.parse(JSONDecoder().decode(YValue.self, from: Data(json.utf8)), fetchedAt: .now))
        #expect(abs(value.value - 0.8) < 0.02)
        #expect(value.estimated)
    }

    @Test func targetExpirationSkipsExpiryWeek() {
        let now = Date(timeIntervalSince1970: 0)
        let days = { (n: Double) in Date(timeIntervalSince1970: n * 86_400) }
        #expect(ImpliedVolatility.targetExpiration([days(2), days(9), days(30)], after: now) == days(9))
    }

    @Test func storeKeepsCachedRowsWhenRefreshFails() async throws {
        var calls = 0
        let store = ScreenerStore(fetch: { _ in
            calls += 1
            if calls > 1 { throw MarketError.status(503) }
            return [try self.row("AAA")]
        }, clock: { .now.addingTimeInterval(Double(calls) * 120) })
        let gainers = try preset("gainers")
        await store.refresh(gainers)
        #expect(store.state(gainers) == .loaded)
        await store.refresh(gainers, force: true)
        #expect(store.state(gainers) == .unavailable)
        #expect(store.rows(gainers).map(\.symbol) == ["AAA"])
    }
}
