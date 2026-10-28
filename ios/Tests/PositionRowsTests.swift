import Foundation
import Testing
@testable import Newswire

struct PositionRowsTests {
    private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private let session = ISO8601DateFormatter().date(from: "2026-10-28T15:00:00Z")!

    private func contract(change: Double?, traded: String?, bid: Double = 9.9, ask: Double = 10.1, state: String = "REGULAR") -> OptionQuote {
        OptionQuote(bid: bid, ask: ask, last: 10, lastTrade: traded.map(utc), change: change, yahooVolatility: nil,
                    regular: 700, pre: nil, post: nil, marketState: state)
    }

    private let call = Position(id: "a|gev-call", itemID: "a", institution: "Robinhood", account: "Individual", symbol: "GEV", name: "GE Vernova Call",
                                option: OptionDetail(isCall: true, strike: 700, expiration: Date.now.addingTimeInterval(30 * 86400), contracts: 2),
                                quantity: 200, price: 9, value: 1800, reportedCost: 1500)
    private let shares = Position(id: "a|kai", itemID: "a", institution: "Robinhood", account: "Individual", symbol: "KAI", name: "Kadant",
                                  option: nil, quantity: 10.72, price: 4.02, value: 43.09, reportedCost: nil)

    @Test func contractMoveCountsOnlyAfterItTradesInTodaysSession() {
        #expect(PositionMoversCard.sessionChange(contract(change: 1.5, traded: "2026-10-28T14:50:00Z"), now: session) == 1.5)
        #expect(PositionMoversCard.sessionChange(contract(change: 1.5, traded: "2026-10-27T19:59:00Z"), now: session) == nil)
        #expect(PositionMoversCard.sessionChange(contract(change: 1.5, traded: "2026-10-27T19:59:00Z"), now: utc("2026-10-28T12:00:00Z")) == nil)
        #expect(PositionMoversCard.sessionChange(contract(change: nil, traded: "2026-10-28T14:50:00Z"), now: session) == nil)
        #expect(PositionMoversCard.sessionChange(contract(change: 1.5, traded: "2026-10-30T19:00:00Z"), now: utc("2026-10-31T15:00:00Z")) == nil)
    }

    @Test func optionsRankByContractValueWithoutATodayMove() throws {
        let rows = PositionMoversCard.rows(positions: [shares, call], quotes: [:], options: [:], now: utc("2026-10-28T12:00:00Z"))
        #expect(rows.map(\.id) == ["a|gev-call", "KAI"])
        let option = try #require(rows.first)
        #expect(option.dollars == nil && option.value == 1800)
        #expect(option.detail.hasPrefix("2 ct · $1,800 · "))
        #expect(option.fallback?.text == "+$300.00" && option.fallback?.caption == "total")
    }

    @Test func liveContractQuoteSetsValueAndTodaysDollars() throws {
        let quote = contract(change: 1.5, traded: "2026-10-28T14:50:00Z")
        let rows = PositionMoversCard.rows(positions: [call], quotes: [:], options: [call.id: quote], now: session)
        let option = try #require(rows.first)
        #expect(option.value == 2000)
        #expect(option.dollars == 300)
        #expect(abs((option.percent ?? 0) - 1.5 / 8.5 * 100) < 1e-9)
    }

    @Test func staleContractQuoteFallsBackToSyncedValue() throws {
        let quote = contract(change: 1.5, traded: "2026-10-27T19:59:00Z", bid: 0, ask: 0, state: "PRE")
        let rows = PositionMoversCard.rows(positions: [call], quotes: [:], options: [call.id: quote], now: utc("2026-10-28T12:00:00Z"))
        let option = try #require(rows.first)
        #expect(option.value == 1800 && option.dollars == nil && option.percent == nil)
    }

    private func fund(_ symbol: String, name: String? = nil, value: Double? = 4688) -> Position {
        Position(id: "b|\(symbol)", itemID: "b", institution: "Empower", account: "401(k)", symbol: symbol, name: name,
                 option: nil, quantity: 12.84, price: nil, value: value, reportedCost: nil)
    }

    @Test func planFundsMapToTheETFTrackingTheirIndex() {
        #expect(fund("SP.500.INDEX.PL.CL.D").proxySymbol == "SPY")
        #expect(fund("SP.INTL.INDEX.D").proxySymbol == "VXUS")
        #expect(fund("SP.SMALL.CP.IND.CL.D").proxySymbol == "IWM")
        #expect(fund("SP.MID.CAP.INDEX.D").proxySymbol == "IJH")
        #expect(fund("US.BOND.INDEX.CL.F").proxySymbol == "AGG")
        #expect(fund("TARGET.2055.FUND.K").proxySymbol == nil)
        #expect(fund("VOO").proxySymbol == nil)
        #expect(shares.proxySymbol == nil && call.proxySymbol == nil)
    }

    @Test func planFundEstimatesTodayFromTheProxyPercentOnItsSyncedValue() throws {
        let data = Data("""
        {"symbol":"SPY","regularMarketPrice":600,"regularMarketTime":100,"regularMarketChange":6,"regularMarketChangePercent":1,"marketState":"REGULAR"}
        """.utf8)
        let spy = try #require(MarketQuote(JSONDecoder().decode(YValue.self, from: data)))
        let row = try #require(PositionMoversCard.rows(positions: [fund("SP.500.INDEX.PL.CL.D")], quotes: ["SPY": spy], options: [:], now: session).first)
        #expect(row.symbol == "SPY" && row.proxy == "SPY" && row.title == "SP.500.INDEX.PL.CL.D")
        #expect(row.value == 4688 && abs((row.dollars ?? 0) - 46.88) < 1e-9 && row.percent == 1)
        #expect(row.detail == "12.84 sh · $4,688 · tracks SPY")

        let unquoted = try #require(PositionMoversCard.rows(positions: [fund("SP.500.INDEX.PL.CL.D")], quotes: [:], options: [:], now: session).first)
        #expect(unquoted.dollars == nil && unquoted.value == 4688)
        let unvalued = try #require(PositionMoversCard.rows(positions: [fund("SP.500.INDEX.PL.CL.D", value: nil)], quotes: ["SPY": spy], options: [:], now: session).first)
        #expect(unvalued.dollars == nil && unvalued.percent == 1)
    }
}
