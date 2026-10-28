import Foundation
import Testing
@testable import Newswire

struct HomeEventsTests {
    private let calendar = Calendar.current
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private var now: Date { at(28, 18, 51) }

    @Test func groupsSameSessionEarningsWithoutPlaceholderTimes() throws {
        let reports = ["KEX", "VFC", "GEV"].map {
            TodayEventsCard.Earnings(symbol: $0, at: at(28, 21, 30), timing: "Before open", estimated: false, held: $0 == "GEV")
        }
        let events = TodayEventsCard.events(upcoming: [], earnings: reports, now: now)
        let event = try #require(events.only)
        #expect(event.title == "KEX, VFC, GEV earnings")
        #expect(event.detail == nil && event.note == "GEV held")
        #expect(event.symbols == ["KEX", "VFC", "GEV"])
        #expect(TodayEventsCard.time(event, now: now) == "Before open")
    }

    @Test func keepsEstimatedDatesApartAndShowsOnlyTheDay() throws {
        let reports = [
            TodayEventsCard.Earnings(symbol: "KEX", at: at(29, 21, 30), timing: "Before open", estimated: false, held: false),
            TodayEventsCard.Earnings(symbol: "VFC", at: at(29, 21, 30), timing: nil, estimated: true, held: true),
        ]
        let events = TodayEventsCard.events(upcoming: [], earnings: reports, now: now)
        #expect(events.count == 2)
        let estimated = try #require(events.first { $0.symbols == ["VFC"] })
        #expect(estimated.note == "Held · date est.")
        #expect(TodayEventsCard.time(estimated, now: now) == "Tomorrow")
        let confirmed = try #require(events.first { $0.symbols == ["KEX"] })
        #expect(confirmed.note == nil)
        #expect(TodayEventsCard.time(confirmed, now: now) == "Tmrw before open")
    }

    @Test func macroEventsKeepMinutesAndOnlyTheirFact() throws {
        let upcoming = [
            MarketPulse.Upcoming(title: "Federal Funds Rate, FOMC Statement", at: at(29, 3), detail: "Federal Funds Rate forecast 4.00%. A surprise here can outweigh everything above.", timing: nil),
            MarketPulse.Upcoming(title: "FOMC Press Conference", at: at(29, 3, 30), detail: "A surprise here can outweigh everything above.", timing: nil),
            MarketPulse.Upcoming(title: "ASML earnings", at: at(29, 21, 30), detail: "Expected EPS 10.76. Big enough to move tech stocks on its own.", timing: "before the open"),
            MarketPulse.Upcoming(title: "Retail Sales", at: at(31, 21, 30), detail: "Usually a smaller mover.", timing: nil),
        ]
        let events = TodayEventsCard.events(upcoming: upcoming, earnings: [], now: now)
        #expect(events.map(\.title) == ["Federal Funds Rate, FOMC Statement", "FOMC Press Conference", "ASML earnings"])
        #expect(events.map(\.detail) == ["Federal Funds Rate forecast 4.00%", nil, "Expected EPS 10.76"])
        #expect(TodayEventsCard.time(events[1], now: now) == "Tmrw \(at(29, 3, 30).formatted(.dateTime.hour().minute()))")
        #expect(TodayEventsCard.time(events[2], now: now) == "Tmrw before open")
    }

    @Test func dropsReportsOutsideTheWindow() {
        let reports = [
            TodayEventsCard.Earnings(symbol: "OLD", at: at(27, 21, 30), timing: "After close", estimated: false, held: false),
            TodayEventsCard.Earnings(symbol: "FAR", at: calendar.date(byAdding: .day, value: 5, to: now)!, timing: "After close", estimated: false, held: false),
        ]
        #expect(TodayEventsCard.events(upcoming: [], earnings: reports, now: now).isEmpty)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
