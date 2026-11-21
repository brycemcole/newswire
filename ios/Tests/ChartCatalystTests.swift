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

    @Test func picksTheHeadlineBehindEachLargeMoveInsteadOfTheLatest() {
        // Flat for 40 bars, drops 15% across bars 40-44, then flat again.
        let start = date("2026-03-02T14:30:00Z")
        let dates = (0..<80).map { ISO8601DateFormatter().string(from: start.addingTimeInterval(Double($0) * 86_400)) }
        var built = self.chart(dates)
        built.points = built.points.map { point in
            PricePoint(id: point.id, date: point.date, open: nil, close: point.id < 40 ? 100 : point.id < 45 ? 100 - Double(point.id - 39) * 3 : 85, extended: false, run: 0)
        }
        let cause = ChartCatalyst(id: "cause", kind: .news, date: built.points[40].date, title: "Shares plunge as company cuts guidance", detail: nil, source: "Test", tagged: true)
        let unrelated = ChartCatalyst(id: "late", kind: .news, date: built.points[78].date, title: "Company opens new office", detail: nil, source: "Test")
        let earlyNoise = ChartCatalyst(id: "early", kind: .news, date: built.points[5].date, title: "Company hires analyst", detail: nil, source: "Test")
        let result = ChartCatalyst.curated([earlyNoise, unrelated, cause], chart: built, range: .year)
        #expect(result.drivers.map(\.event.id) == ["cause"])
        #expect(result.events.map(\.id) == ["cause"])
        #expect((result.drivers.first?.move.change ?? 0) < -0.1)
        #expect(result.drivers.first?.event.detail?.contains("not confirmed") == true)
    }

    @Test func flatChartsHaveNoMovesAndSoNoNewsDots() {
        let flat = chart((0..<20).map { "2026-03-\(String(format: "%02d", $0 + 1))T14:30:00Z" })
        #expect(ChartCatalyst.moves(chart: flat).isEmpty)
        let story = ChartCatalyst(id: "n", kind: .news, date: date("2026-03-10T14:30:00Z"), title: "Anything", detail: nil, source: "Test")
        #expect(ChartCatalyst.curated([story], chart: flat, range: .month).events.isEmpty)
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
