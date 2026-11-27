import Foundation

/// A generated explanation of the move across one chart range, grounded in the stock's own data: price path, sector and market
/// benchmarks over the same window, fundamentals, earnings inside the window, and the headlines nearest the largest swings.
@Observable final class RangeExplanation {
    struct Result: Codable, Equatable {
        let text: String
        let through: Date
        let benchmarks: [String]
    }

    enum Phase { case idle, writing, done, failed }

    private(set) var phase = Phase.idle
    private(set) var result: Result?
    /// Text of the explanation being written, shown over the previous one as it streams in.
    private(set) var partial = ""
    /// True when `result` is not for the current key: an older bucket of this range, or the range shown before.
    private(set) var stale = false
    /// Symbol and range of `result`, so a different range's text is only ever shown while its replacement is being written.
    private(set) var scope: String?
    private(set) var key: String?
    private static let storeKey = "rangeExplanations.v1"

    static var available: Bool { AIRouter.isAvailable(.moveExplanations) || (AIRouter.deepSeekEnabled(.moveExplanations) && ChatGPTAccount.shared.ready) }

    /// The cache bucket: short ranges are re-explained as new bars arrive, long ranges once per trading day.
    static func key(symbol: String, range: ChartRange, chart: MarketChart) -> String? {
        guard let last = chart.points.last?.date else { return nil }
        let bucket: TimeInterval = switch range {
        case .day: 1800
        case .week: 7200
        default: 86_400
        }
        return "\(symbol)|\(range.rawValue)|\(Int(last.timeIntervalSince1970 / bucket))"
    }

    func showsResult(symbol: String, range: ChartRange) -> Bool {
        result != nil && (scope == "\(symbol)|\(range.rawValue)" || phase == .writing)
    }

    /// Shows the saved explanation for this range right away: the current one if it exists, otherwise the newest older one.
    /// Returns true when the saved one is current and nothing needs generating.
    @discardableResult func restore(symbol: String, range: ChartRange, chart: MarketChart) -> Bool {
        guard let key = Self.key(symbol: symbol, range: range, chart: chart) else { return false }
        if self.key == key, phase == .done || phase == .writing { return true }
        let current = "\(symbol)|\(range.rawValue)"
        let saved = Self.load()
        if let exact = saved[key] {
            self.key = key
            result = exact
            scope = current
            stale = false
            partial = ""
            phase = .done
            return true
        }
        if let older = saved.filter({ $0.key.hasPrefix(current + "|") }).max(by: { $0.value.through < $1.value.through })?.value {
            result = older
            scope = current
        }
        stale = true
        return false
    }

    func explain(symbol: String, name: String, range: ChartRange, chart: MarketChart, summary: QuoteSummary?, events: [ChartCatalyst],
                 drivers: [ChartCatalyst.Driver]) async {
        guard let key = Self.key(symbol: symbol, range: range, chart: chart), !restore(symbol: symbol, range: range, chart: chart) else { return }
        let current = "\(symbol)|\(range.rawValue)"
        self.key = key
        partial = ""
        guard Self.available, let move = Self.change(chart, range: range) else { fail(current); return }
        phase = .writing
        defer {
            if Task.isCancelled, self.key == key, phase == .writing { partial = ""; phase = .idle }
        }
        let etf = Self.sectorETF(summary)
        let benchmarks = [etf, "SPY"].compactMap { $0 }.filter { $0 != symbol }
        var compared: [String: Double] = [:]
        await withTaskGroup(of: (String, Double?).self) { group in
            for benchmark in benchmarks {
                group.addTask { (benchmark, (try? await MarketClient.chart(benchmark, range: range)).flatMap { Self.change($0, range: range) }) }
            }
            for await (benchmark, change) in group { if let change { compared[benchmark] = change } }
        }
        guard !Task.isCancelled, self.key == key else { return }
        let prompt = Self.prompt(symbol: symbol, name: name, range: range, chart: chart, move: move, summary: summary, etf: etf,
                                 compared: compared, events: events, drivers: drivers)
        do {
            let text = try await Self.generate(instructions: Self.instructions(range), prompt: prompt) { [weak self] text in
                guard let self, self.key == key else { return }
                self.partial = text
            }.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled, self.key == key else { return }
            guard !text.isEmpty else { fail(current); return }
            let result = Result(text: text, through: chart.points.last?.date ?? .now, benchmarks: benchmarks.filter { compared[$0] != nil })
            self.result = result
            scope = current
            partial = ""
            stale = false
            phase = .done
            Self.save(key, result)
        } catch {
            guard self.key == key else { return }
            fail(current)
        }
    }

    private func fail(_ current: String) {
        partial = ""
        if scope != current { result = nil; scope = nil }
        phase = .failed
    }

    private static func generate(instructions: String, prompt: String, onPartial: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        if AIRouter.deepSeekEnabled(.moveExplanations), ChatGPTAccount.shared.ready {
            if let text = try? await ChatGPTResponses.text(instructions: instructions, prompt: prompt, onPartial: onPartial), !text.isEmpty { return text }
            try Task.checkCancellation()
        }
        return try await AIRouter.generate(.moveExplanations, instructions: instructions, prompt: prompt, temperature: 0.2, maxTokens: 220, onPartial: onPartial)
    }

    /// The same change the header shows: from the previous close on 1D, otherwise from the first bar in the range.
    nonisolated static func change(_ chart: MarketChart, range: ChartRange) -> Double? {
        let regular = chart.points.filter { !$0.extended }
        guard let last = (regular.last ?? chart.points.last)?.close, last > 0 else { return nil }
        let base = range == .day ? chart.previousClose : chart.points.first?.close
        guard let base, base > 0 else { return nil }
        return last / base - 1
    }

    static func sectorETF(_ summary: QuoteSummary?) -> String? {
        let industry = (summary?.text("assetProfile", "industry") ?? "").lowercased()
        if industry.contains("semiconductor") { return "SMH" }
        if industry.contains("software") { return "IGV" }
        if industry.contains("bank") { return "KBE" }
        if industry.contains("biotech") { return "XBI" }
        return switch summary?.text("assetProfile", "sector") {
        case "Technology": "XLK"
        case "Communication Services": "XLC"
        case "Consumer Cyclical": "XLY"
        case "Consumer Defensive": "XLP"
        case "Energy": "XLE"
        case "Financial Services": "XLF"
        case "Healthcare": "XLV"
        case "Industrials": "XLI"
        case "Basic Materials": "XLB"
        case "Real Estate": "XLRE"
        case "Utilities": "XLU"
        default: nil
        }
    }

    private static func instructions(_ range: ChartRange) -> String {
        let horizon = switch range {
        case .day, .week:
            "This is a short window. Say first whether the stock moved with its sector and the market or on its own, using the benchmark changes. Then give the most likely company-specific or sector catalyst from the headlines, if one fits."
        case .month, .threeMonths, .sixMonths, .ytd:
            "This is a medium window. Weigh earnings results inside the window, guidance or analyst headlines near the largest swings, and how the sector traded over the same period."
        case .year, .fiveYears, .max:
            "This is a long window. Explain the structural story: the demand themes and business shifts this company is widely known for, revenue and earnings growth, and whether it outran or lagged its sector. Single headlines matter only if they mark a turning point."
        }
        return """
        You explain why a stock moved over a chart range, for a markets app. \(horizon) \
        Use the supplied data for every number and date. You may use well-established knowledge of what the company does and the \
        industry themes it is known for, but never invent figures, dates, events, or analyst calls that are not supplied. \
        If the data does not explain the move, say so plainly. Write at most two short sentences, under 45 words, plain text, \
        no preamble, markdown, hedging boilerplate, or investment advice. Do not restate the percentage change as the first words.
        """
    }

    private static func prompt(symbol: String, name: String, range: ChartRange, chart: MarketChart, move: Double, summary: QuoteSummary?, etf: String?,
                               compared: [String: Double], events: [ChartCatalyst], drivers: [ChartCatalyst.Driver]) -> String {
        let percent = { (value: Double) in value.formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always())) }
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: chart.timeZone)
        let stamp = range.intraday ? Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: chart.timeZone) : day
        guard let first = chart.points.first, let last = chart.points.last else { return "" }
        var lines = ["\(name) (\(symbol)) · \(range.caption): \(percent(move)), from \(first.date.formatted(stamp)) to \(last.date.formatted(stamp))."]
        if let high = chart.points.max(by: { $0.close < $1.close }), let low = chart.points.min(by: { $0.close < $1.close }) {
            lines.append("Range high \(high.close.formatted(.number.precision(.fractionLength(2)))) on \(high.date.formatted(stamp)); low \(low.close.formatted(.number.precision(.fractionLength(2)))) on \(low.date.formatted(stamp)); last \(last.close.formatted(.number.precision(.fractionLength(2)))).")
        }
        let profile = [summary?.text("assetProfile", "sector"), summary?.text("assetProfile", "industry")].compactMap { $0 }
        if !profile.isEmpty { lines.append("Sector: " + profile.joined(separator: " · ")) }
        if let about = summary?.text("assetProfile", "longBusinessSummary") { lines.append("Business: " + String(about.prefix(420))) }
        let benchmarks = compared.sorted { $0.key < $1.key }.map { "\($0.key == "SPY" ? "S&P 500 (SPY)" : "sector ETF \($0.key)") \(percent($0.value))" }
        if !benchmarks.isEmpty { lines.append("Same window: " + benchmarks.joined(separator: "; ") + ".") }
        let fundamentals = [("Revenue growth (latest quarter, y/y)", summary?.text("financialData", "revenueGrowth")),
                            ("Earnings growth (latest quarter, y/y)", summary?.text("financialData", "earningsGrowth")),
                            ("Trailing P/E", summary?.text("summaryDetail", "trailingPE")),
                            ("Forward P/E", summary?.text("summaryDetail", "forwardPE"))].compactMap { label, value in value.map { "\(label) \($0)" } }
        if !fundamentals.isEmpty { lines.append("Current fundamentals: " + fundamentals.joined(separator: "; ") + ".") }
        let window = first.date...last.date.addingTimeInterval(86_400)
        let earnings = events.filter { $0.kind == .earnings && window.contains($0.date) }.suffix(8)
        if !earnings.isEmpty {
            lines.append("Earnings in window:\n" + earnings.map { "- \($0.date.formatted(day)): \($0.title)\($0.detail.map { " · \($0)" } ?? "")" }.joined(separator: "\n"))
        }
        if !drivers.isEmpty {
            lines.append("Largest swings and the nearest headline:\n" + drivers.map {
                "- \(percent($0.move.change)) from \($0.move.from.formatted(stamp)) to \($0.move.to.formatted(stamp)); [\($0.event.source), \($0.event.date.formatted(day))] \($0.event.title)"
            }.joined(separator: "\n"))
        }
        var used = Set(drivers.map(\.event.id) + drivers.map { $0.event.title.lowercased() })
        let headlines = events.filter { $0.kind == .news && window.contains($0.date) && used.insert($0.id).inserted && used.insert($0.title.lowercased()).inserted }
            .sorted { ($0.tagged ? 1 : 0, $0.date) > ($1.tagged ? 1 : 0, $1.date) }.prefix(8)
        if !headlines.isEmpty {
            lines.append("Other headlines in window:\n" + headlines.map { "- [\($0.source), \($0.date.formatted(day))] \($0.title)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    private static func load() -> [String: Result] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Result].self, from: data)) ?? [:]
    }

    private static func save(_ key: String, _ result: Result) {
        var all = load()
        all[key] = result
        if all.count > 60 {
            for old in all.sorted(by: { $0.value.through < $1.value.through }).prefix(all.count - 60) { all[old.key] = nil }
        }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: storeKey) }
    }
}
