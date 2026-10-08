import Foundation
import Testing
@testable import Newswire

struct EconomicHistoryTests {
    @Test func csvKeepsAllReadingsAndSkipsMissingValues() {
        let values = EconomicHistory.parse("observation_date,PAYEMS\n1939-01-01,29923\n1939-02-01,.\n1939-03-01,30000\n1939-04-01,\n", id: "PAYEMS")
        #expect(values.count == 2)
        #expect(values.first?.date == "1939-01-01")
        #expect(EconomicHistory.parse("<html>blocked</html>", id: "PAYEMS").isEmpty)
        #expect(EconomicHistory.parse("observation_date,UNRATE\n2026-01-01,4.2", id: "PAYEMS").isEmpty)
    }

    @Test func payrollChangeKeepsNegativeMonthsAndConvertsThousandsToJobs() throws {
        let observations = EconomicHistory.parse("observation_date,PAYEMS\n2026-07-01,158882\n2026-08-01,159015\n2026-09-01,159044", id: "PAYEMS")
        let points = EconomicHistory.points(observations, transform: "diff")
        #expect(points.map(\.value) == [133, 29])
        let data = Data(#"{"title":"Nonfarm payrolls (PAYEMS)","source":"FRED","url":"https://fred.stlouisfed.org/series/PAYEMS","as_of":"2026-10-06T00:00:00.000Z","note":"Transform: diff","sections":[],"chart":{"label":"Payrolls","unit":"K","points":[{"x":"2026-09-01","value":29}]},"text":""}"#.utf8)
        let payload = try NewswireAPI.decoder().decode(DataPayload.self, from: data)
        let display = try #require(SeriesPresentation(route: DataRoute("series/PAYEMS"), payload: payload, observations: points))
        #expect(display.value(29) == "29,000 jobs")
        #expect(display.headline.contains("added 29,000 jobs"))
        #expect(display.comparisonText?.contains("104,000 jobs fewer") == true)
        #expect(display.period("2026-09-01") == "September 2026")
    }

    @Test func yearOverYearNeedsTheMatchingPeriodAndDoesNotBridgeAGap() {
        let values = [EconomicHistory.Observation(date: "2025-08-01", value: 100), .init(date: "2026-08-01", value: 103), .init(date: "2026-09-01", value: 105)]
        let points = EconomicHistory.points(values, transform: "yoy")
        #expect(points.count == 1)
        #expect(abs((points.first?.value ?? 0) - 3) < 0.0001)
    }

    @Test func allHistoryKeepsEveryObservationWhileChartReductionKeepsEndpoints() {
        let points = (0..<1000).map { DataPayload.Point(x: String(format: "%04d-01-01", 1000 + $0), value: Double($0)) }
        #expect(EconomicHistory.visible(points, window: .all).count == 1000)
        let chart = EconomicHistory.chart(points)
        #expect(chart.count == 600)
        #expect(chart.first == points.first && chart.last == points.last)
    }
}
