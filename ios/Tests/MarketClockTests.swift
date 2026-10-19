import Foundation
import Testing
@testable import Newswire

struct MarketClockTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    @Test func holidaysAndEarlyClose() {
        for day in ["2026-07-03", "2026-11-26", "2026-04-03", "2026-05-25"] {
            #expect(MarketClock.session(on: date(day + "T16:00:00Z")) == nil)
        }
        #expect(MarketClock.session(on: date("2026-11-27T16:00:00Z"))?.end == date("2026-11-27T18:00:00Z"))
        #expect(MarketClock.session(on: date("2026-12-24T16:00:00Z"))?.end == date("2026-12-24T18:00:00Z"))
    }
    @Test func nextOpenAndDaylightSaving() {
        #expect(MarketClock.nextOpen(after: date("2026-10-17T16:00:00Z")) == date("2026-10-19T13:30:00Z"))
        #expect(MarketClock.nextOpen(after: date("2026-11-26T16:00:00Z")) == date("2026-11-27T14:30:00Z"))
        #expect(MarketClock.title(at: date("2026-10-19T13:30:00Z")) == "The market is open")
        #expect(MarketClock.title(at: date("2026-10-19T20:00:00Z")) == "After the bell")
    }
    @Test func futuresWeekendAndMaintenance() {
        #expect(!MarketClock.futuresScheduled(date("2026-10-17T16:00:00Z")))
        #expect(!MarketClock.futuresScheduled(date("2026-10-18T21:59:00Z")))
        #expect(MarketClock.futuresScheduled(date("2026-10-18T22:00:00Z")))
        #expect(!MarketClock.futuresScheduled(date("2026-10-19T21:30:00Z")))
        #expect(MarketClock.futuresReopen(after: date("2026-10-17T16:00:00Z")) == date("2026-10-18T22:00:00Z"))
    }
}
