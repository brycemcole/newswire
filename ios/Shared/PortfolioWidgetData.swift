import Foundation
import SwiftUI

nonisolated enum Money {
    static func text(_ value: Double) -> String { text(value, code: "USD") }
    static func whole(_ value: Double) -> String { whole(value, code: "USD") }
    static func compact(_ value: Double) -> String { compact(value, code: "USD") }
    static func text(_ value: Double, code: String) -> String { value.formatted(.currency(code: code)) }
    static func whole(_ value: Double, code: String) -> String { value.formatted(.currency(code: code).precision(.fractionLength(0))) }
    static func compact(_ value: Double, code: String) -> String { value.formatted(.currency(code: code).notation(.compactName).precision(.significantDigits(3))) }
    static func signedCompact(_ value: Double) -> String { (value >= 0 ? "+" : "−") + compact(abs(value)) }
    static func signed(_ value: Double) -> String { signed(value, code: "USD") }
    static func signed(_ value: Double, code: String) -> String { (value >= 0 ? "+" : "−") + abs(value).formatted(.currency(code: code)) }
    static func symbol(_ code: String) -> String {
        Locale(identifier: "en_US@currency=\(code)").currencySymbol ?? code
    }
    static func percent(_ value: Double) -> String { (value >= 0 ? "+" : "−") + abs(value).formatted(.percent.precision(.fractionLength(1))) }
    static func percent2(_ value: Double) -> String { (value >= 0 ? "+" : "−") + abs(value).formatted(.percent.precision(.fractionLength(2))) }
    static func tint(_ value: Double) -> Color { value >= 0 ? .green : .red }
}

nonisolated struct WidgetPoint: Codable, Hashable, Sendable {
    let date: Date
    let value: Double
}

nonisolated struct WidgetHolding: Codable, Hashable, Identifiable, Sendable {
    let symbol: String
    let name: String?
    let quantity: Double
    let cost: Double?
    var price: Double
    var previousClose: Double?
    var spark: [Double] = []

    var id: String { symbol }
    var value: Double { quantity * price }
    var dayChange: Double? { previousClose.map { quantity * (price - $0) } }
    var dayPercent: Double? { previousClose.flatMap { $0 == 0 ? nil : price / $0 - 1 } }
}

nonisolated struct WidgetChart: Sendable {
    let previousClose: Double?
    let points: [WidgetPoint]
}

nonisolated struct WidgetPortfolio: Codable, Sendable {
    static let group = "group.com.brycecole.newswire"
    static let kind = "Portfolio"

    var holdings: [WidgetHolding]
    var cash: Double
    var other: Double
    var otherGain: Double?
    var value: Double
    var dayBaseline: Double?
    var day: [WidgetPoint] = []
    var month: [WidgetPoint] = []
    var updated: Date
    var fetched: Date?
    var monthFetched: Date?
    var accountingVersion: Int?
    var measuredDayChange: Double?
    var measuredDayPercent: Double?

    var dayChange: Double? { accountingVersion == 1 ? measuredDayChange : nil }
    var dayPercent: Double? { accountingVersion == 1 ? measuredDayPercent : nil }
    var monthChange: Double? { nil }
    var monthPercent: Double? { nil }
    var dayHigh: Double? { day.map(\.value).max() }
    var dayLow: Double? { day.map(\.value).min() }
    var byValue: [WidgetHolding] { holdings.sorted { $0.value > $1.value } }

    var totalGain: Double? {
        let gains = holdings.compactMap { holding in holding.cost.map { holding.value - $0 } } + [otherGain].compactMap { $0 }
        return gains.isEmpty ? nil : gains.reduce(0, +)
    }

    var totalGainPercent: Double? {
        let cost = holdings.compactMap(\.cost).reduce(0, +)
        guard let gain = totalGain, cost > 0, otherGain == nil else { return nil }
        return gain / cost
    }

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appending(path: "portfolio-widget.json")
    }

    static func load() -> WidgetPortfolio? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetPortfolio.self, from: data)
    }

    func save() {
        guard let url = Self.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        // Widgets render while the phone is locked, so the file must stay readable after first unlock.
        try? encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func refreshed(day charts: [String: WidgetChart], month monthly: [String: WidgetChart], at now: Date = .now) -> WidgetPortfolio {
        var next = self
        for index in next.holdings.indices {
            guard let chart = charts[next.holdings[index].symbol], let last = chart.points.last else { continue }
            next.holdings[index].price = last.value
            next.holdings[index].previousClose = chart.previousClose ?? chart.points.first?.value
            next.holdings[index].spark = Self.thin(chart.points, to: 40).map(\.value)
        }
        if accountingVersion != 1 {
            next.day = []
            next.dayBaseline = nil
        }
        if !Calendar.current.isDate(updated, inSameDayAs: now) {
            next.measuredDayChange = nil
            next.measuredDayPercent = nil
            next.day = []
            next.dayBaseline = nil
        }
        next.month = []
        next.monthFetched = nil
        next.fetched = now
        return next
    }

    static func thin(_ points: [WidgetPoint], to limit: Int) -> [WidgetPoint] {
        guard points.count > limit, limit > 1 else { return points }
        let step = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * step).rounded())] }
    }

    static var sample: WidgetPortfolio {
        let start = Calendar.current.date(bySettingHour: 9, minute: 30, second: 0, of: .now) ?? .now
        let wave = { (index: Int, seed: Double) -> Double in sin(Double(index) / 9 + seed) * 0.004 + Double(index) * 0.00012 }
        let rows: [(String, String, Double, Double, Double, Double)] = [
            ("AAPL", "Apple Inc.", 120, 232.1, 229.4, 1.1),
            ("NVDA", "NVIDIA Corporation", 80, 181.6, 176.0, 2.3),
            ("VTI", "Vanguard Total Stock Market ETF", 95, 312.4, 310.9, 0.4),
            ("MSFT", "Microsoft Corporation", 30, 508.2, 511.7, 3.9),
            ("AMZN", "Amazon.com, Inc.", 45, 227.8, 225.3, 5.2),
            ("TSLA", "Tesla, Inc.", 20, 440.5, 452.0, 0.2),
        ]
        let holdings = rows.map { symbol, name, quantity, price, previous, seed -> WidgetHolding in
            let spark: [Double] = (0..<40).map { index in
                let drift: Double = (price - previous) * Double(index) / 39
                return previous * (1 + wave(index, seed)) + drift
            }
            return WidgetHolding(symbol: symbol, name: name, quantity: quantity, cost: quantity * previous * 0.82, price: price,
                                 previousClose: previous, spark: spark)
        }
        let value = holdings.reduce(4_250) { $0 + $1.value }
        let baseline = holdings.reduce(4_250) { $0 + $1.quantity * ($1.previousClose ?? $1.price) }
        let day: [WidgetPoint] = (0..<78).map { index in
            let progress: Double = (value - baseline) * Double(index) / 77
            return WidgetPoint(date: start.addingTimeInterval(Double(index) * 300), value: baseline + progress + baseline * wave(index, 0.6))
        }
        let month: [WidgetPoint] = (0..<22).map { index in
            let shape: Double = 0.955 + Double(index) * 0.002 + sin(Double(index) / 2.5) * 0.008
            return WidgetPoint(date: start.addingTimeInterval(Double(index - 21) * 86_400), value: value * shape)
        }
        return WidgetPortfolio(holdings: holdings, cash: 4_250, other: 0, otherGain: nil, value: day.last?.value ?? value, dayBaseline: baseline,
                               day: day, month: month, updated: .now, fetched: .now, monthFetched: .now)
    }
}
