import Charts
import SwiftUI

/// Each holding's share of the portfolio, day by day, estimated from today's holdings at past closing prices.
@Observable final class WeightHistory {
    struct Day: Identifiable, Hashable { let symbol: String; let date: Date; let percent: Double; var id: String { symbol + date.description } }

    private(set) var days: [Day] = []
    private(set) var loading = false
    private(set) var failed = false
    private(set) var missing: [String] = []
    nonisolated private static let cache = Cache()

    private actor Cache {
        var tracks: [String: (fetched: Date, points: [HistoryPoint])] = [:]
        func get(_ symbol: String) -> [HistoryPoint]? {
            guard let entry = tracks[symbol], -entry.fetched.timeIntervalSinceNow < 1800 else { return nil }
            return entry.points
        }
        func set(_ symbol: String, _ points: [HistoryPoint]) { tracks[symbol] = (.now, points) }
    }

    func load(symbols wanted: [String], snapshot: PortfolioSnapshot) async {
        loading = true
        failed = false
        defer { loading = false }
        var quantities: [String: Double] = [:]
        var current: [String: Double] = [:]
        for position in snapshot.positions where position.option == nil && position.quantity.isFinite && position.quantity != 0 {
            quantities[position.symbol, default: 0] += position.quantity
            if let price = position.price { current[position.symbol] = price }
        }
        guard !quantities.isEmpty else { failed = true; return }
        let start = Calendar.current.date(byAdding: .day, value: -34, to: .now)!
        let cache = Self.cache
        let currentPrices = current
        let tracks = await withTaskGroup(of: (String, [HistoryPoint]?).self) { group in
            for symbol in quantities.keys {
                group.addTask {
                    if let hit = await cache.get(symbol) { return (symbol, hit) }
                    #if DEBUG
                    if CommandLine.arguments.contains("-portfolioPreview") || CommandLine.arguments.contains("-goalDetailPreview") || CommandLine.arguments.contains("-goalsPreview") { return (symbol, Self.synthetic(symbol, from: start, endingAt: currentPrices[symbol] ?? 100)) }
                    #endif
                    guard let points = try? await MarketClient.portfolioHistory(symbol, from: start) else { return (symbol, nil) }
                    let sorted = points.sorted { $0.date < $1.date }
                    await cache.set(symbol, sorted)
                    return (symbol, sorted)
                }
            }
            var found: [String: [HistoryPoint]] = [:]
            for await (symbol, points) in group { if let points { found[symbol] = points } }
            return found
        }
        missing = quantities.keys.filter { tracks[$0] == nil }.sorted()
        guard missing.isEmpty else { failed = true; days = []; return }
        let calendar = Calendar.current
        let allDays = Set(tracks.values.flatMap { $0.map { calendar.startOfDay(for: $0.date) } }).filter { $0 >= calendar.startOfDay(for: start) }.sorted()
        var result: [Day] = []
        for day in allDays {
            var values: [String: Double] = [:]
            var complete = true
            for (symbol, quantity) in quantities {
                guard let close = tracks[symbol]?.last(where: { calendar.startOfDay(for: $0.date) <= day })?.close, close > 0 else { complete = false; break }
                values[symbol] = quantity * close
            }
            let total = values.values.reduce(0, +)
            guard complete, total > 0 else { continue }
            for symbol in wanted { if let value = values[symbol] { result.append(Day(symbol: symbol, date: day, percent: value / total * 100)) } }
        }
        days = result
    }

    #if DEBUG
    nonisolated private static func synthetic(_ symbol: String, from start: Date, endingAt last: Double) -> [HistoryPoint] {
        var seed = UInt64(abs(symbol.hashValue % 10_000) + 7)
        var price = 100.0
        let walk: [Double] = (0..<35).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            price *= 1 + (Double(seed >> 33 % 1000) / 1000 - 0.5) * 0.03
            return price
        }
        let scale = last / (walk.last ?? 1)
        return walk.enumerated().map { index, value in
            let date = Calendar.current.date(byAdding: .day, value: index, to: start)!
            return HistoryPoint(date: date, close: value * scale, adjusted: value * scale)
        }
    }
    #endif
}

struct GoalWeightChart: View {
    let symbols: [String]
    var limit: Double?
    @State private var history = WeightHistory()
    @State private var store = PortfolioStore.shared
    @State private var selected: Date?

    private var shown: [String] {
        if !symbols.isEmpty { return symbols }
        return Dictionary(grouping: store.snapshot.positions.filter { $0.option == nil && $0.value != nil }, by: \.symbol)
            .mapValues { $0.compactMap(\.value).reduce(0, +) }.sorted { $0.value > $1.value }.prefix(5).map(\.key)
    }

    private func value(_ symbol: String, near date: Date?) -> WeightHistory.Day? {
        let points = history.days.filter { $0.symbol == symbol }
        guard let date else { return points.last }
        return points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if history.days.isEmpty {
                Group {
                    if history.loading { ProgressView() }
                    else { Text(history.failed ? "Price history isn't available for every holding, so there is no day-by-day chart." : "No history yet.").font(.footnote).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                chart
            }
            Text("Last 30 days. Estimated from today's holdings at each day's closing price.").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: shown) { await history.load(symbols: shown, snapshot: store.snapshot) }
    }

    private var header: some View {
        let lead = shown.first.flatMap { value($0, near: selected) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(lead.map { "\($0.symbol) · " + ($0.date.formatted(.dateTime.month(.abbreviated).day())) } ?? "Share of portfolio")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(lead.map { $0.percent.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "—")
                .font(.system(size: 56, weight: .bold)).monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    private var chart: some View {
        let values = history.days.map(\.percent) + (limit.map { [$0] } ?? [])
        let low = max((values.min() ?? 0) * 0.85, 0), top = (values.max() ?? 10) * 1.1
        return Chart {
            ForEach(history.days) { day in
                LineMark(x: .value("Day", day.date, unit: .day), y: .value("Share", day.percent), series: .value("Holding", day.symbol))
                    .foregroundStyle(by: .value("Holding", day.symbol))
                    .interpolationMethod(.monotone)
            }
            if let limit {
                RuleMark(y: .value("Limit", limit))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing) { Text("Limit \(limit.formatted(.number.precision(.fractionLength(0...1))))%").font(.caption2).foregroundStyle(.secondary) }
            }
            if let selected {
                RuleMark(x: .value("Selected", selected, unit: .day)).foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .chartYScale(domain: low...top)
        .chartYAxis {
            AxisMarks(position: .trailing) { mark in
                AxisGridLine()
                AxisValueLabel { if let value = mark.as(Double.self) { Text("\(Int(value))%") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartXSelection(value: $selected)
        .chartLegend(shown.count > 1 ? .visible : .hidden)
        .frame(height: 210)
    }
}
