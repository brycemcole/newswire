import Foundation
import Testing
@testable import Newswire

struct SimulatorTests {
    private func day(_ offset: Int) -> Date { Date.now.addingTimeInterval(Double(offset) * 86_400) }

    @Test func parsesOccSymbols() throws {
        let option = try #require(OptionSymbol("AAPL260116C00150000"))
        #expect(option.underlying == "AAPL" && option.isCall && option.strike == 150)
        #expect(option.title == "AAPL 150C 1/16/26")
        #expect(OptionSymbol("SPY261218P00612500")?.strike == 612.5)
        #expect(OptionSymbol("AAPL") == nil)
        #expect(OptionSymbol.display("BTC-USD") == "BTC-USD")
    }

    @Test func backtestBuysFirstCloseOnOrAfterDate() throws {
        let history = [
            HistoryPoint(date: day(-400), close: 50, adjusted: 48),
            HistoryPoint(date: day(-366), close: 100, adjusted: 96),
            HistoryPoint(date: day(-200), close: 80, adjusted: 78),
            HistoryPoint(date: day(-1), close: 150, adjusted: 150),
        ]
        let test = try #require(Backtest(history: history, from: day(-370), amount: 1000, price: 200))
        #expect(test.start.close == 100)
        #expect(test.shares == 10 && test.value == 2000 && test.gain == 1000 && test.change == 1)
        #expect(abs(test.drawdown - -0.2) < 1e-9)
        #expect(test.annualized != nil)
        let dividends = try #require(test.withDividends)
        #expect(abs(dividends - (150.0 / 96 * (200.0 / 150) - 1)) < 1e-9)
        let drip = try #require(test.dripValue)
        #expect(abs(drip - 1000 * (1 + dividends)) < 1e-9)
        #expect(abs(try #require(test.dripShares) - drip / 200) < 1e-9)
        let flat = [HistoryPoint(date: day(-366), close: 100, adjusted: 100), HistoryPoint(date: day(-1), close: 150, adjusted: 150)]
        let noDividends = try #require(Backtest(history: flat, from: day(-370), amount: 1000, price: 150))
        #expect(noDividends.dripValue == nil && noDividends.dripShares == nil && noDividends.cashDividends == nil)
        var reinvested = test
        reinvested.reinvest = true
        #expect(abs(reinvested.value - drip) < 1e-9 && abs(reinvested.change - dividends) < 1e-9)
        #expect(abs(reinvested.worth(history[1]) - 1000) < 1e-9)
        var flatReinvested = noDividends
        flatReinvested.reinvest = true
        #expect(flatReinvested.value == noDividends.value)
        #expect(Backtest(history: history, from: day(1), amount: 1000, price: 200) == nil)
        #expect(Backtest(history: history, from: day(-370), amount: 0, price: 200) == nil)
    }

    @Test func recoversCashDividendsFromAdjustedCloses() throws {
        let history = [
            HistoryPoint(date: day(-40), close: 50, adjusted: 49.5 * 0.98),
            HistoryPoint(date: day(-30), close: 50, adjusted: 50 * 0.99 * 0.98),
            HistoryPoint(date: day(-20), close: 48, adjusted: 48 * 0.98),
            HistoryPoint(date: day(-10), close: 47, adjusted: 47),
        ]
        let test = try #require(Backtest(history: history, from: day(-35), amount: 1000, price: 47))
        #expect(abs(test.dividendsPerShare - (50 * 0.01 + 48 * 0.02)) < 1e-9)
        #expect(abs(try #require(test.cashDividends) - 20 * (0.5 + 0.96)) < 1e-9)
    }

    @Test func parsesChartHistoryAndSkipsNulls() throws {
        let json = #"{"timestamp":[1,2,3],"indicators":{"quote":[{"close":[10,null,12]}],"adjclose":[{"adjclose":[9,null,11.5]}]}}"#
        let points = HistoryPoint.parse(try JSONDecoder().decode(YValue.self, from: Data(json.utf8)))
        #expect(points.map(\.close) == [10, 12])
        #expect(points.map(\.adjusted) == [9, 11.5])
    }

    @Test func parsesOptionChainPage() throws {
        let json = #"{"optionChain":{"result":[{"expirationDates":[1790985600,1791590400],"quote":{"regularMarketPrice":101.5},"options":[{"expirationDate":1790985600,"calls":[{"contractSymbol":"XYZ261002C00100000","strike":100,"bid":2,"ask":2.2,"lastPrice":2.1,"percentChange":5,"volume":10,"openInterest":300,"impliedVolatility":0.3,"inTheMoney":true}],"puts":[]}]}]}}"#
        let page = try #require(OptionChainPage.parse(Data(json.utf8)))
        #expect(page.spot == 101.5 && page.expirations.count == 2 && page.puts.isEmpty)
        let call = try #require(page.calls.first)
        #expect(call.inTheMoney && abs(call.mark - 2.1) < 1e-9 && call.openInterest == 300)
    }
}
