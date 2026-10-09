import Foundation
import Testing
@testable import Newswire

struct WidgetPortfolioTests {
    private func point(_ minute: Double, _ value: Double) -> WidgetPoint {
        WidgetPoint(date: Date(timeIntervalSince1970: minute * 60), value: value)
    }

    @Test func legacyRefreshDoesNotInventPortfolioReturns() {
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

        #expect(refreshed.day.isEmpty)
        #expect(refreshed.value == portfolio.value)
        #expect(refreshed.dayBaseline == nil)
        #expect(refreshed.dayChange == nil)
        #expect(abs(refreshed.holdings[0].dayPercent! - (100.0 / 95 - 1)) < 1e-9)
        #expect(refreshed.totalGain == 200.0)
        #expect(refreshed.fetched != nil)
        #expect(refreshed.month.isEmpty)
    }

    @Test func refreshPreservesTransactionBasedReturn() {
        let now = Date.now
        let portfolio = WidgetPortfolio(holdings: [WidgetHolding(symbol: "AAA", name: nil, quantity: 5, cost: 500, price: 120)],
            cash: 600, other: 0, otherGain: nil, value: 1200, dayBaseline: 1000,
            day: [WidgetPoint(date: now, value: 1200)], updated: now,
            accountingVersion: 1, measuredDayChange: 200, measuredDayPercent: 0.2)
        let refreshed = portfolio.refreshed(day: ["AAA": WidgetChart(previousClose: 110, points: [point(0, 125)])], month: [:], at: now)
        #expect(refreshed.value == 1200 && refreshed.dayChange == 200 && refreshed.dayPercent == 0.2)
        let tomorrow = portfolio.refreshed(day: [:], month: [:], at: now.addingTimeInterval(86400))
        #expect(tomorrow.dayChange == nil && tomorrow.dayPercent == nil && tomorrow.day.isEmpty)
    }

    @Test func thinKeepsEndpoints() {
        let points = (0..<500).map { point(Double($0), Double($0)) }
        let thinned = WidgetPortfolio.thin(points, to: 60)
        #expect(thinned.count == 60)
        #expect(thinned.first?.value == 0)
        #expect(thinned.last?.value == 499)
    }
}
