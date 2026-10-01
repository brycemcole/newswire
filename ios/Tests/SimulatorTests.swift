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
        #expect(Backtest(history: history, from: day(1), amount: 1000, price: 200) == nil)
        #expect(Backtest(history: history, from: day(-370), amount: 0, price: 200) == nil)
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
