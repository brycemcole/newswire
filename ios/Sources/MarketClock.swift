import Foundation

nonisolated enum MarketClock {
    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/New_York")!
        return result
    }

    static func at(_ day: Date, hour: Int, minute: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    static func session(on day: Date) -> MarketSession? {
        let c = calendar
        let year = c.component(.year, from: day)
        let weekday = c.component(.weekday, from: day)
        guard weekday != 1 && weekday != 7 else { return nil }
        func date(_ month: Int, _ day: Int) -> Date { c.date(from: DateComponents(year: year, month: month, day: day, hour: 12))! }
        func nth(_ month: Int, _ weekday: Int, _ occurrence: Int) -> Date {
            let first = date(month, 1)
            return c.date(byAdding: .day, value: (weekday - c.component(.weekday, from: first) + 7) % 7 + 7 * (occurrence - 1), to: first)!
        }
        func observed(_ month: Int, _ day: Int) -> Date {
            let raw = date(month, day)
            let weekday = c.component(.weekday, from: raw)
            return c.date(byAdding: .day, value: weekday == 7 ? -1 : weekday == 1 ? 1 : 0, to: raw)!
        }
        let a = year % 19, b = year / 100, cc = year % 100, d = b / 4, e = b % 4, f = (b + 8) / 25
        let g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30, i = cc / 4, k = cc % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7, m = (a + 11 * h + 22 * l) / 451
        let easter = date((h + l - 7 * m + 114) / 31, (h + l - 7 * m + 114) % 31 + 1)
        let goodFriday = c.date(byAdding: .day, value: -2, to: easter)!
        let mayLast = date(5, 31)
        let memorial = c.date(byAdding: .day, value: -(c.component(.weekday, from: mayLast) + 5) % 7, to: mayLast)!
        let thanksgiving = nth(11, 5, 4)
        var holidays = [nth(1, 2, 3), nth(2, 2, 3), goodFriday, memorial, observed(7, 4), nth(9, 2, 1), thanksgiving, observed(12, 25)]
        if year >= 2022 { holidays.append(observed(6, 19)) }
        if c.component(.weekday, from: date(1, 1)) != 7 { holidays.append(observed(1, 1)) }
        guard !holidays.contains(where: { c.isDate($0, inSameDayAs: day) }) else { return nil }
        let md = c.dateComponents([.month, .day], from: day)
        let early = c.isDate(day, inSameDayAs: c.date(byAdding: .day, value: 1, to: thanksgiving)!) || (md.month == 12 && md.day == 24) || (md.month == 7 && md.day == 3)
        return MarketSession(start: at(day, hour: 9, minute: 30), end: at(day, hour: early ? 13 : 16))
    }

    static func nextOpen(after now: Date) -> Date {
        for offset in 0..<14 {
            let day = calendar.date(byAdding: .day, value: offset, to: now)!
            if let session = session(on: day), session.start > now { return session.start }
        }
        return now
    }

    static func futuresReopen(after now: Date) -> Date {
        for offset in 0..<8 {
            let day = calendar.date(byAdding: .day, value: offset, to: now)!
            let weekday = calendar.component(.weekday, from: day)
            let reopen = at(day, hour: 18)
            if weekday != 6 && weekday != 7 && reopen > now { return reopen }
        }
        return now
    }

    static func futuresScheduled(_ now: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        return weekday != 7 && !(weekday == 1 && hour < 18) && !(weekday == 6 && hour >= 17) && hour != 17
    }

    static func title(at now: Date) -> String {
        if let session = session(on: now) {
            if session.contains(now) { return "The market is open" }
            if now < session.start { return calendar.component(.hour, from: now) < 6 ? "The overnight watch" : "Before the bell" }
            return "After the bell"
        }
        return futuresScheduled(now) ? "The overnight watch" : "The week ahead"
    }
}
