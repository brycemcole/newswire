import Foundation

nonisolated struct ChartCatalyst: Identifiable, Sendable {
    enum Kind: Sendable {
        case earnings, dividend, split, news
        var icon: String {
            switch self {
            case .earnings: "calendar.badge.clock"
            case .dividend: "dollarsign.circle"
            case .split: "arrow.triangle.branch"
            case .news: "newspaper"
            }
        }
        var badge: String {
            switch self {
            case .earnings: "E"
            case .dividend: "D"
            case .split: "S"
            case .news: "•"
            }
        }
    }
    let id: String
    let kind: Kind
    let date: Date
    let dateOnly: Bool
    let title: String
    let detail: String?
    let source: String

    init(id: String, kind: Kind, date: Date, dateOnly: Bool = false, title: String, detail: String?, source: String) {
        self.id = id
        self.kind = kind
        self.date = date
        self.dateOnly = dateOnly
        self.title = title
        self.detail = detail
        self.source = source
    }

    init(_ story: TickerStory) {
        self.init(id: story.id, kind: .news, date: story.date, title: story.title, detail: "Possible catalyst · news published at this time", source: story.publisher)
    }

    static func earnings(_ summary: QuoteSummary?) -> [Self] {
        guard let summary else { return [] }
        return (summary.value("earnings", "earningsChart")?["quarterly"]?.array ?? []).compactMap { item in
            guard let date = reportDate(item["reportedDate"]), date <= .now else { return nil }
            let actual = item["actual"]?.raw, estimate = item["estimate"]?.raw
            var details: [String] = []
            if let actual { details.append("EPS \(actual.formatted(.number.precision(.fractionLength(2))))") }
            if let estimate { details.append("Estimate \(estimate.formatted(.number.precision(.fractionLength(2))))") }
            if let actual, let estimate, estimate != 0 {
                details.append("Surprise \(((actual - estimate) / abs(estimate)).formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always())))")
            }
            return Self(id: "earnings:\(date.timeIntervalSince1970)", kind: .earnings, date: date, dateOnly: true,
                        title: "Earnings" + (item["date"]?.text.map { " · \($0)" } ?? ""),
                        detail: details.isEmpty ? nil : details.joined(separator: " · "), source: "Yahoo Finance · report date; time unavailable")
        }
    }

    private static func reportDate(_ value: YValue?) -> Date? {
        if let date = value?.date { return date }
        guard let text = value?.text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        for format in ["yyyy-MM-dd", "MMM d, yyyy", "MM/dd/yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func corporateActions(_ value: YValue?) -> [Self] {
        var events: [Self] = []
        for (key, kind) in [("dividends", Kind.dividend), ("splits", Kind.split)] {
            guard case let .object(items)? = value?[key] else { continue }
            for (id, item) in items {
                guard let date = item["date"]?.date else { continue }
                let detail = kind == .dividend ? item["amount"]?.raw.map { "Dividend per share: \($0.formatted()) in quote currency" } : item["splitRatio"]?.text
                events.append(Self(id: key + id, kind: kind, date: date, title: kind == .dividend ? "Ex-dividend" : "Stock split", detail: detail, source: "Yahoo Finance"))
            }
        }
        return events
    }

    struct Marker: Identifiable, Sendable {
        let event: ChartCatalyst
        let index: Int
        var id: String { event.id }
    }

    static func mapped(_ events: [Self], chart: MarketChart, range: ChartRange) -> [Marker] {
        guard let first = chart.points.first, let last = chart.points.last else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chart.timeZone
        var utc = calendar
        utc.timeZone = .gmt
        var seen: Set<String> = []
        return events.sorted { $0.date < $1.date }.compactMap { event in
            guard seen.insert(event.id).inserted else { return nil }
            let date: Date
            if event.dateOnly {
                guard let local = calendar.date(from: utc.dateComponents([.year, .month, .day], from: event.date)) else { return nil }
                date = local
            } else { date = event.date }
            if range == .fiveYears || range == .max {
                let component: Calendar.Component = range == .max ? .month : .weekOfYear
                guard let index = chart.points.firstIndex(where: { calendar.dateInterval(of: component, for: $0.date)?.contains(date) == true }) else { return nil }
                return Marker(event: event, index: index)
            }
            guard date >= calendar.startOfDay(for: first.date), date < (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last.date)) ?? last.date) else { return nil }
            if range.intraday && event.dateOnly {
                guard let index = chart.points.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }) else { return nil }
                return Marker(event: event, index: index)
            }
            if range.intraday && date > last.date { return nil }
            let index = chart.points.firstIndex { point in
                range.intraday ? point.date >= date : calendar.startOfDay(for: point.date) >= calendar.startOfDay(for: date)
            }
            guard let index, chart.points[index].date.timeIntervalSince(date) < 4 * 86_400 else { return nil }
            return Marker(event: event, index: index)
        }
    }
}
