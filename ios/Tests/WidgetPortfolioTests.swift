import Foundation
import Testing
@testable import Newswire

struct WidgetPortfolioTests {
    private func point(_ minute: Double, _ value: Double) -> WidgetPoint {
        WidgetPoint(date: Date(timeIntervalSince1970: minute * 60), value: value)
    }

    @Test func refreshCombinesHoldingsAgainstPreviousClose() {
        let portfolio = WidgetPortfolio(
            holdings: [WidgetHolding(symbol: "AAA", name: nil, quantity: 10, cost: 800, price: 90),
                       WidgetHolding(symbol: "BBB", name: nil, quantity: 2, cost: nil, price: 50),
                       WidgetHolding(symbol: "CCC", name: nil, quantity: 1, cost: nil, price: 30)],
            cash: 100, other: 20, otherGain: nil, value: 0, updated: .now)
        let charts = [
            "AAA": WidgetChart(previousClose: 95, points: [point(0, 96), point(5, 98), point(10, 100)]),
            "BBB": WidgetChart(previousClose: 40, points: [point(0, 41), point(10, 45)]),
        ]
        let refreshed = portfolio.refreshed(day: charts, month: [:])

        // CCC has no chart, so it stays at its stored value inside the constant part.
        #expect(refreshed.day.map(\.value) == [1192.0, 1212, 1240])
        #expect(refreshed.value == 1240.0)
        #expect(refreshed.dayBaseline == 1180.0)
        #expect(refreshed.dayChange == 60.0)
        #expect(abs(refreshed.holdings[0].dayPercent! - (100.0 / 95 - 1)) < 1e-9)
        #expect(refreshed.totalGain == 200.0)
        #expect(refreshed.fetched != nil)
        #expect(refreshed.month.isEmpty)
    }

    @Test func thinKeepsEndpoints() {
        let points = (0..<500).map { point(Double($0), Double($0)) }
        let thinned = WidgetPortfolio.thin(points, to: 60)
        #expect(thinned.count == 60)
        #expect(thinned.first?.value == 0)
        #expect(thinned.last?.value == 499)
    }
}
