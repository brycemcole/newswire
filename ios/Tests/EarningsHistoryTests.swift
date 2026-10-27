import Foundation
import Testing
@testable import Newswire

struct EarningsHistoryTests {
    private func json(_ text: String) throws -> YValue {
        try JSONDecoder().decode(YValue.self, from: Data(text.utf8))
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!

    @Test func retainsEveryReturnedPeriodAndPreservesMissingVersusZero() throws {
        let root = try json(#"{"timeseries":{"result":[{"meta":{"type":["quarterlyTotalRevenue"]},"quarterlyTotalRevenue":[{"asOfDate":"2026-06-30","periodType":"3M","currencyCode":"USD","reportedValue":{"raw":0}},{"asOfDate":"2020-03-31","periodType":"3M","currencyCode":"USD","reportedValue":{"raw":100}}]},{"meta":{"type":["quarterlyNetIncome"]},"quarterlyNetIncome":[{"asOfDate":"2026-06-30","periodType":"3M","currencyCode":"USD","reportedValue":{"raw":-5}}]}]}}"#)
        let rows = ReportedEarnings.parse(root, now: now)
        #expect(rows.count == 2)
        #expect(rows.first?.end == "2026-06-30")
        #expect(rows.first?.revenue == 0)
        #expect(rows.first?.netIncome == -5)
        #expect(rows.first?.dilutedEPS == nil)
        #expect(rows.last?.netIncome == nil)
    }

    @Test func doesNotJoinDifferentCurrenciesOrAnnualAndQuarterlyValues() throws {
        let root = try json(#"{"timeseries":{"result":[{"meta":{"type":["annualTotalRevenue"]},"annualTotalRevenue":[{"asOfDate":"2025-12-31","periodType":"12M","currencyCode":"USD","reportedValue":{"raw":100}}]},{"meta":{"type":["quarterlyNetIncome"]},"quarterlyNetIncome":[{"asOfDate":"2025-12-31","periodType":"3M","currencyCode":"EUR","reportedValue":{"raw":10}}]},{"meta":{"type":["quarterlyTotalRevenue"]},"quarterlyTotalRevenue":[{"asOfDate":"2025-12-31","periodType":"3M","currencyCode":"USD","reportedValue":{"raw":20}}]}]}}"#)
        let rows = ReportedEarnings.parse(root, now: now)
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3)
        #expect(rows.allSatisfy { $0.revenue == nil || $0.netIncome == nil })
    }

    @Test func rejectsFutureOrWrongDurationReportedValues() throws {
        let root = try json(#"{"timeseries":{"result":[{"meta":{"type":["quarterlyTotalRevenue"]},"quarterlyTotalRevenue":[{"asOfDate":"2026-12-31","periodType":"3M","currencyCode":"USD","reportedValue":{"raw":100}},{"asOfDate":"2026-06-30","periodType":"6M","currencyCode":"USD","reportedValue":{"raw":100}}]}]}}"#)
        #expect(ReportedEarnings.parse(root, now: now).isEmpty)
    }

    @Test func supportsRevenueOnlyForecastAndRetainsZeroEPS() throws {
        let summary = QuoteSummary(root: try json(#"{"earningsTrend":{"trend":[{"period":"0q","endDate":"2026-12-31","revenueEstimate":{"avg":{"raw":100},"low":{"raw":90},"high":{"raw":110}}},{"period":"+1q","endDate":"2027-03-31","earningsEstimate":{"avg":{"raw":0}}}]}}"#))
        let rows = EarningsForecast.parse(summary, now: now)
        #expect(rows.count == 2)
        #expect(rows.first?.value["revenueEstimate"]?["avg"]?.raw == 100)
        #expect(rows.first?.value["earningsEstimate"] == nil)
        #expect(rows.last?.value["earningsEstimate"]?["avg"]?.raw == 0)
    }

    @Test func expiredForecastIsNotPresentedAsCurrent() throws {
        let summary = QuoteSummary(root: try json(#"{"earningsTrend":{"trend":[{"period":"0q","endDate":"2025-09-30","earningsEstimate":{"avg":{"raw":1}}},{"period":"+5y","endDate":"2030-12-31","earningsEstimate":{"avg":{"raw":4}}}]}}"#))
        #expect(EarningsForecast.parse(summary, now: now).isEmpty)
    }

    @Test func futureCalendarDoesNotReviveOldConsensus() throws {
        let summary = QuoteSummary(root: try json(#"{"calendarEvents":{"earnings":{"earningsDate":[{"raw":1794873600}]}},"earningsTrend":{"trend":[{"period":"0q","endDate":"2024-09-30","revenueEstimate":{"avg":{"raw":100}}}]}}"#))
        #expect(EarningsForecast.parse(summary, now: now).isEmpty)
    }

    @Test func reportingQuarterCanEndBeforeItsUpcomingRelease() throws {
        let summary = QuoteSummary(root: try json(#"{"calendarEvents":{"earnings":{"earningsDate":[{"raw":1794873600}]}},"earningsTrend":{"trend":[{"period":"0q","endDate":"2026-09-30","revenueEstimate":{"avg":{"raw":2140000000}}}]}}"#))
        let row = try #require(EarningsForecast.parse(summary, now: now).first)
        #expect(row.end == "2026-09-30")
        #expect(row.validThrough == "2026-11-17")
        #expect(!row.isValid(now: ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")!))
    }
}
