import Testing
import Foundation
@testable import Newswire

struct MacroTextTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    @Test func fedOddsReadAsSentences() {
        #expect(MacroText.fedOdds("20% of a 25 bp hike") == "Traders see a 20% chance of a quarter-point hike and 80% that rates hold.")
        #expect(MacroText.fedOdds("No change priced") == "Traders expect rates to stay where they are.")
        #expect(MacroText.fedOdds("100% of a 25 bp cut (more than one move priced)") == "Traders expect a cut, possibly bigger than a quarter point.")
        #expect(MacroText.targetRange("Target range 3.50–3.75%; effective rate 3.58%.") == "3.50–3.75%")
    }

    @Test func calendarDaysAreRelative() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 18)))
        let today = MacroText.day("Tuesday, Oct 6", now: now, calendar: calendar)
        #expect(MacroText.relativeDay(today, now: now, calendar: calendar) == "Today")
        #expect(MacroText.relativeDay(MacroText.day("Wednesday, Oct 7", now: now, calendar: calendar), now: now, calendar: calendar) == "Tomorrow")
        let lateDecember = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 30)))
        let newYear = try #require(MacroText.day("Friday, Jan 1", now: lateDecember, calendar: calendar))
        #expect(calendar.component(.year, from: newYear) == 2027)
        let meeting = try #require(MacroText.meetingDate("Oct 28, 2026"))
        #expect(MacroText.countdown(to: meeting, now: now, calendar: calendar) == "In 22 days")
    }

    @Test func eventTitlesArePlain() {
        #expect(MacroText.title("USD FOMC Meeting Minutes").text == "Fed meeting minutes")
        #expect(MacroText.title("GBP BOE Gov Bailey Speaks").text == "Bank of England's Bailey speaks")
        #expect(MacroText.title("CAD Employment Change").text == "Jobs report")
        #expect(MacroText.title("GBP BOE Gov Bailey Speaks").flag == "🇬🇧")
    }
}
