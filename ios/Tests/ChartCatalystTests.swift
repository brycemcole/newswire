import Foundation
import Testing
@testable import Newswire

struct ChartCatalystTests {
    @Test func usesReportDatesAndIgnoresFiscalPeriodDates() throws {
        let root = try JSONDecoder().decode(YValue.self, from: Data(#"{"earnings":{"earningsChart":{"quarterly":[{"date":"2Q2026","reportedDate":"2026-07-30","actual":1.2,"estimate":1.0},{"date":"3Q2026","quarter":{"raw":1788134400},"actual":2}]}}}"#.utf8))
        let events = ChartCatalyst.earnings(QuoteSummary(root: root))
        #expect(events.count == 1)
        #expect(events.first?.date == date("2026-07-30T00:00:00Z"))
        #expect(events.first?.detail?.contains("20.0%") == true)
    }

    @Test func dateOnlyPreservesReportDayInNewYork() throws {
        let event = ChartCatalyst(id: "e", kind: .earnings, date: date("2026-07-30T00:00:00Z"), dateOnly: true, title: "Earnings", detail: nil, source: "Test")
        let chart = chart(["2026-07-29T13:30:00Z", "2026-07-30T13:30:00Z", "2026-07-31T13:30:00Z"])
        #expect(ChartCatalyst.mapped([event], chart: chart, range: .threeMonths).first?.index == 1)
    }

    @Test func overnightNewsMapsToNextSessionWithoutLeakingIntoEarlierIntradayBars() {
        let event = ChartCatalyst(id: "n", kind: .news, date: date("2026-07-30T21:00:00Z"), title: "Guidance", detail: nil, source: "Test")
        let chart = chart(["2026-07-30T19:30:00Z", "2026-07-31T13:30:00Z"])
        #expect(ChartCatalyst.mapped([event], chart: chart, range: .week).first?.index == 1)
        #expect(ChartCatalyst.mapped([event], chart: self.chart(["2026-07-30T19:30:00Z"]), range: .day).isEmpty)
    }

    @Test func weeklyBarsContainEventsWithinTheirWeek() {
        let event = ChartCatalyst(id: "e", kind: .earnings, date: date("2026-07-30T00:00:00Z"), dateOnly: true, title: "Earnings", detail: nil, source: "Test")
        #expect(ChartCatalyst.mapped([event], chart: chart(["2026-07-27T13:30:00Z", "2026-08-03T13:30:00Z"]), range: .fiveYears).first?.index == 0)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func chart(_ dates: [String]) -> MarketChart {
        MarketChart(symbol: "TEST", name: "Test", exchange: "", currency: "USD", instrument: "EQUITY", price: 100,
                    previousClose: 99, dayHigh: nil, dayLow: nil, volume: nil, yearHigh: nil, yearLow: nil, decimals: 2,
                    timeZone: TimeZone(identifier: "America/New_York")!,
                    points: dates.enumerated().map { PricePoint(id: $0.offset, date: date($0.element), open: 100, close: 100, extended: false, run: 0) },
                    slots: dates.count, pre: nil, regular: nil, post: nil)
    }
}
