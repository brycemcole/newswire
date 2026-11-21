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
    /// News the provider tagged to this ticker, as opposed to a headline found by text search.
    let tagged: Bool

    init(id: String, kind: Kind, date: Date, dateOnly: Bool = false, title: String, detail: String?, source: String, tagged: Bool = false) {
        self.id = id
        self.kind = kind
        self.date = date
        self.dateOnly = dateOnly
        self.title = title
        self.detail = detail
        self.source = source
        self.tagged = tagged
    }

    init(_ story: TickerStory) {
        self.init(id: story.id, kind: .news, date: story.date, title: story.title, detail: "Possible catalyst · news published at this time", source: story.publisher, tagged: story.tagged)
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

    // MARK: Catalyst selection

    /// A large price swing in the visible chart: `start` and `index` are the bars it ran between.
    struct Move: Identifiable, Sendable {
        let start: Int
        let index: Int
        let change: Double
        let from: Date
        let to: Date
        var id: Int { index }
    }

    /// The headline picked as the possible cause of a move.
    struct Driver: Identifiable, Sendable {
        let move: Move
        let event: ChartCatalyst
        var id: String { event.id }
    }

    /// How far from a move a story may be published and still count, by chart range.
    static func tolerance(for range: ChartRange) -> TimeInterval {
        switch range {
        case .day: 6 * 3600
        case .week: 36 * 3600
        case .month: 2 * 86_400
        case .threeMonths, .sixMonths, .ytd, .year: 3 * 86_400
        case .fiveYears: 10 * 86_400
        case .max: 45 * 86_400
        }
    }

    /// The largest non-overlapping swings across the range, biggest first. Swings are measured over about a thirtieth of the
    /// chart so one noisy bar cannot qualify, and each must be at least 40% as large as the biggest swing found.
    static func moves(chart: MarketChart, limit: Int = 4) -> [Move] {
        let points = chart.points
        let count = points.count
        guard count >= 8 else { return [] }
        let width = max(1, count / 30)
        let candidates: [Move] = (width..<count).compactMap { index in
            let base = points[index - width].close
            guard base > 0, points[index].close > 0 else { return nil }
            return Move(start: index - width, index: index, change: points[index].close / base - 1, from: points[index - width].date, to: points[index].date)
        }
        guard let top = candidates.map({ abs($0.change) }).max(), top > 0.002 else { return [] }
        let spacing = max(width, count / 8)
        var picked: [Move] = []
        for move in candidates.sorted(by: { abs($0.change) > abs($1.change) }) {
            guard abs(move.change) >= top * 0.4, picked.count < limit else { break }
            if picked.allSatisfy({ abs($0.index - move.index) > spacing }) { picked.append(move) }
        }
        return picked
    }

    private static let negative = ["plunge", "plummet", "tumble", "sink", "slump", "drop", "fall", "slide", "selloff", "sell-off", "crash", "miss", "cuts", "downgrade", "lawsuit", "probe", "investigation", "banned", "restrict", "tariff", "warn", "weak", "concern", "fear", "delay", "recall", "layoff", "short"]
    private static let positive = ["surge", "soar", "jump", "rally", "climb", "gain", "rise", "record", "beat", "upgrade", "raise", "boost", "wins", "approve", "deal", "partnership", "strong", "buyback"]
    private static let general = ["earnings", "guidance", "forecast", "revenue", "outlook", "results", "report", "announce", "acquire", "merger", "ceo", "stock", "shares"]

    /// Headline relevance from 0 to 1: provider-tagged, names a market-moving subject, and leans the way the price moved.
    static func relevance(_ event: ChartCatalyst, change: Double) -> Double {
        let title = event.title.lowercased()
        let leaning = change < 0 ? negative : positive
        let opposite = change < 0 ? positive : negative
        var score = event.tagged ? 0.25 : 0
        if leaning.contains { title.contains($0) } { score += 0.4 }
        else if opposite.contains { title.contains($0) } { score += 0.1 }
        if general.contains { title.contains($0) } { score += 0.2 }
        return min(score + 0.15, 1)
    }

    /// For each large move, the most relevant story published near it, with no story used twice. The tie between two stories of
    /// similar relevance goes to the one closest in time.
    static func drivers(stories: [ChartCatalyst], chart: MarketChart, range: ChartRange) -> [Driver] {
        let window = tolerance(for: range)
        var used: Set<String> = []
        var result: [Driver] = []
        for move in moves(chart: chart) {
            let scored: [(event: ChartCatalyst, score: Double)] = stories.filter { $0.kind == .news && !used.contains($0.id) }.compactMap { story in
                let distance = story.date < move.from ? move.from.timeIntervalSince(story.date) : story.date > move.to ? story.date.timeIntervalSince(move.to) : 0
                guard distance <= window else { return nil }
                return (story, (1 - distance / window) * 0.8 + relevance(story, change: move.change))
            }
            guard let best = scored.max(by: { $0.score < $1.score }) else { continue }
            used.insert(best.event.id)
            let percent = move.change.formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always()))
            let event = ChartCatalyst(id: best.event.id, kind: .news, date: best.event.date, title: best.event.title,
                                      detail: "Possible catalyst for a \(percent) move · published near it, not confirmed as the cause",
                                      source: best.event.source, tagged: best.event.tagged)
            result.append(Driver(move: move, event: event))
        }
        return result
    }

    /// Non-news events plus only the headlines chosen as catalysts, so news dots mark causes instead of clustering on the latest stories.
    static func curated(_ events: [Self], chart: MarketChart, range: ChartRange) -> (events: [Self], drivers: [Driver]) {
        let drivers = drivers(stories: events, chart: chart, range: range)
        return (events.filter { $0.kind != .news } + drivers.map(\.event), drivers)
    }
}
