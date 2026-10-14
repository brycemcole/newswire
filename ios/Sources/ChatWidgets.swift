import Charts
import SwiftUI

// MARK: - Quotes

/// One option contract exactly as a tool returned it. Widgets read prices from here, never from model text.
nonisolated struct ChatOption: Codable, Hashable, Sendable, Identifiable {
    let symbol: String
    let strike: Double
    let bid: Double
    let ask: Double
    let last: Double
    let volume: Double
    let openInterest: Double
    let volatility: Double?
    let spot: Double

    var id: String { symbol }

    init(symbol: String, strike: Double, bid: Double, ask: Double, last: Double = 0, volume: Double = 0, openInterest: Double = 0, volatility: Double? = nil, spot: Double) {
        self.symbol = symbol; self.strike = strike; self.bid = bid; self.ask = ask; self.last = last
        self.volume = volume; self.openInterest = openInterest; self.volatility = volatility; self.spot = spot
    }

    init(_ contract: OptionContract, spot: Double) {
        self.init(symbol: contract.symbol, strike: contract.strike, bid: contract.bid, ask: contract.ask, last: contract.last,
                  volume: contract.volume, openInterest: contract.openInterest, volatility: contract.volatility, spot: spot)
    }

    var parsed: OptionSymbol? { OptionSymbol(symbol) }
    var underlying: String { parsed?.underlying ?? symbol }
    var isCall: Bool { parsed?.isCall ?? true }
    var expiration: Date? { parsed?.expiration }
    var mark: Double { bid > 0 && ask > 0 ? (bid + ask) / 2 : last }

    /// Buying pays the ask and selling receives the bid; the last trade only stands in when a side is not quoted.
    func entry(buying: Bool) -> Double { (buying ? ask : bid) > 0 ? (buying ? ask : bid) : last }

    /// Underlying price at expiry where a single long contract breaks even.
    var breakeven: Double { isCall ? strike + entry(buying: true) : strike - entry(buying: true) }
}

// MARK: - Widget specs

nonisolated struct ChatOptionsSpec: Codable, Hashable, Sendable {
    var title: String?
    var contracts: [String]
}

nonisolated struct ChatStrategyLeg: Codable, Hashable, Sendable {
    var contract: String?
    var shares: Double?
    var side: String
    var qty: Double?
}

nonisolated struct ChatStrategySpec: Codable, Hashable, Sendable {
    var name: String?
    var outlook: String?
    var legs: [ChatStrategyLeg]
}

/// A fenced block in an answer that renders as a native card: ```options or ```strategy, each holding JSON.
nonisolated enum ChatWidget: Hashable, Sendable {
    case options(ChatOptionsSpec)
    case strategy(ChatStrategySpec)

    static let languages: Set<String> = ["options", "option-chain", "strategy", "position"]

    static func normalize(_ language: String) -> String {
        let first = language.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        return first.lowercased().replacingOccurrences(of: "newswire-", with: "")
    }

    static func parse(language: String, body: String) -> ChatWidget? {
        let data = Data(body.utf8)
        let decoder = JSONDecoder()
        switch normalize(language) {
        case "options", "option-chain":
            guard let spec = try? decoder.decode(ChatOptionsSpec.self, from: data), !spec.contracts.isEmpty else { return nil }
            return .options(spec)
        case "strategy", "position":
            guard let spec = try? decoder.decode(ChatStrategySpec.self, from: data), !spec.legs.isEmpty else { return nil }
            return .strategy(spec)
        default:
            return nil
        }
    }
}

// MARK: - Strategy math

nonisolated struct PricedLeg: Hashable, Sendable {
    /// Nil for a leg of the underlying stock.
    let option: ChatOption?
    let sign: Double
    let quantity: Double
    let entry: Double
    let multiplier: Double

    /// Profit or loss at expiry for the whole leg, in dollars.
    func pnl(at spot: Double) -> Double {
        let value: Double
        if let option { value = option.isCall ? max(spot - option.strike, 0) : max(option.strike - spot, 0) } else { value = spot }
        return sign * quantity * multiplier * (value - entry)
    }

    /// Dollars of profit per $1 of underlying move above the highest strike.
    var tailSlope: Double { option == nil || option?.isCall == true ? sign * quantity * multiplier : 0 }
}

nonisolated struct PayoffPoint: Hashable, Sendable, Identifiable {
    let spot: Double
    let pnl: Double
    var id: Double { spot }
}

/// Expiry payoff of a one-underlying, one-expiry strategy, computed from quoted prices.
nonisolated struct StrategyAnalysis: Hashable, Sendable {
    let legs: [PricedLeg]
    let underlying: String
    let spot: Double
    let expiration: Date
    /// Positive is a net debit paid, negative a net credit received.
    let net: Double
    /// Nil means unlimited.
    let maxProfit: Double?
    let maxLoss: Double?
    let breakevens: [Double]
    let curve: [PayoffPoint]

    static func sign(_ side: String) -> Double? {
        switch side.lowercased() {
        case "buy", "long", "bto", "btc": 1
        case "sell", "short", "write", "sto", "stc": -1
        default: nil
        }
    }

    /// Nil unless every leg is a quoted contract (or shares) on one underlying and one expiry.
    init?(spec: ChatStrategySpec, options: [ChatOption]) {
        let lookup = Dictionary(options.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        guard !spec.legs.isEmpty, spec.legs.count <= 6,
              let anchor = spec.legs.compactMap({ $0.contract.flatMap { lookup[$0] } }).first,
              let expiration = anchor.expiration else { return nil }
        var priced: [PricedLeg] = []
        for leg in spec.legs {
            guard let sign = Self.sign(leg.side) else { return nil }
            if let symbol = leg.contract {
                let quantity = leg.qty ?? 1
                guard let option = lookup[symbol], option.underlying == anchor.underlying, option.expiration == expiration,
                      quantity > 0, quantity <= 1000 else { return nil }
                let entry = option.entry(buying: sign > 0)
                guard entry > 0 else { return nil }
                priced.append(PricedLeg(option: option, sign: sign, quantity: quantity, entry: entry, multiplier: 100))
            } else if let shares = leg.shares ?? leg.qty, shares > 0, shares <= 100_000, anchor.spot > 0 {
                priced.append(PricedLeg(option: nil, sign: sign, quantity: shares, entry: anchor.spot, multiplier: 1))
            } else {
                return nil
            }
        }
        let legs = priced
        self.legs = legs
        underlying = anchor.underlying
        spot = anchor.spot
        self.expiration = expiration
        net = legs.reduce(0) { $0 + $1.sign * $1.quantity * $1.multiplier * $1.entry }

        // Expiry payoff is piecewise linear with kinks at the strikes, so the extremes sit at 0 or a strike.
        let strikes = Array(Set(legs.compactMap { $0.option?.strike })).sorted()
        let total = { (price: Double) -> Double in legs.reduce(0) { $0 + $1.pnl(at: price) } }
        let nodes: [Double] = [0] + strikes
        let values = nodes.map(total)
        let slope = legs.reduce(0) { $0 + $1.tailSlope }
        let epsilon = 1e-9
        maxProfit = slope > epsilon ? nil : values.max().map { max($0, 0) }
        maxLoss = slope < -epsilon ? nil : values.min().map { max(-$0, 0) }

        var crossings: [Double] = []
        for index in nodes.indices {
            let x = nodes[index], fx = values[index]
            if abs(fx) < epsilon { if x > 0 { crossings.append(x) } }
            if index + 1 < nodes.count {
                let next = nodes[index + 1], fnext = values[index + 1]
                if fx * fnext < 0 { crossings.append(x + (next - x) * fx / (fx - fnext)) }
            }
        }
        if let last = nodes.last, let flast = values.last, abs(slope) > epsilon, flast * slope < 0 { crossings.append(last - flast / slope) }
        var unique: [Double] = []
        for value in crossings.sorted() where unique.last.map({ value - $0 > 0.005 }) ?? true { unique.append(value) }
        breakevens = unique

        let reach = strikes + unique + [anchor.spot]
        let low = (reach.min() ?? anchor.spot) * 0.92
        let high = (reach.max() ?? anchor.spot) * 1.08
        let xs = Set([low, high] + reach.filter { $0 > low && $0 < high }).sorted()
        curve = xs.map { PayoffPoint(spot: $0, pnl: total($0)) }
    }

    func pnl(at price: Double) -> Double { legs.reduce(0) { $0 + $1.pnl(at: price) } }
}

// MARK: - Formatting

private enum WidgetFormat {
    static let utc = TimeZone(identifier: "UTC")!

    static func money(_ value: Double) -> String {
        "$" + abs(value).formatted(.number.precision(.fractionLength(abs(value) >= 1000 ? 0 : 2)))
    }

    static func signed(_ value: Double) -> String {
        (value > 0 ? "+" : value < 0 ? "−" : "") + money(value)
    }

    static func price(_ value: Double) -> String { "$" + QuoteFormat.price(value) }

    static func day(_ date: Date) -> String { date.formatted(Date.FormatStyle(timeZone: utc).month(.abbreviated).day()) }

    static func axis(_ value: Double) -> String {
        (value < 0 ? "−" : "") + "$" + abs(value).formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

// MARK: - Views

struct ChatWidgetView: View {
    let widget: ChatWidget
    let options: [ChatOption]

    var body: some View {
        switch widget {
        case .options(let spec): OptionsWidget(spec: spec, options: options)
        case .strategy(let spec): StrategyWidget(spec: spec, options: options)
        }
    }
}

private struct WidgetCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: .rect(cornerRadius: 20, style: .continuous))
    }
}

private struct OptionsWidget: View {
    let spec: ChatOptionsSpec
    let options: [ChatOption]

    private var rows: [ChatOption] {
        let lookup = Dictionary(options.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        return spec.contracts.prefix(8).compactMap { lookup[$0] }
    }

    var body: some View {
        let shown = rows
        if let first = shown.first {
            WidgetCard {
                HStack(alignment: .firstTextBaseline) {
                    Text(spec.title ?? "\(first.underlying) options").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text("Spot \(WidgetFormat.price(first.spot))").font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(shown) { option in
                        row(option)
                        if option.id != shown.last?.id { Divider() }
                    }
                }
                Text("Per share; one contract covers 100 shares. Buying pays the ask. Quotes may be delayed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ option: ChatOption) -> some View {
        let expiry = option.expiration.map(WidgetFormat.day) ?? ""
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(option.strike.formatted(.number.precision(.fractionLength(0...2)))) \(option.isCall ? "Call" : "Put")")
                    .font(.subheadline.weight(.semibold))
                Text(expiry).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(WidgetFormat.price(option.mark)).font(.subheadline.weight(.semibold))
                Text("\(QuoteFormat.price(option.bid))–\(QuoteFormat.price(option.ask))").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 84, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Cost \(WidgetFormat.money(option.entry(buying: true) * 100))").font(.subheadline.weight(.semibold))
                Text(["B/E \(WidgetFormat.price(option.breakeven))", option.volatility.map { $0.formatted(.percent.precision(.fractionLength(0))) + " IV" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.strike.formatted()) \(option.isCall ? "call" : "put") expiring \(expiry), mid \(WidgetFormat.price(option.mark)), bid \(QuoteFormat.price(option.bid)), ask \(QuoteFormat.price(option.ask)), cost \(WidgetFormat.money(option.entry(buying: true) * 100)) per contract, breakeven \(WidgetFormat.price(option.breakeven))")
    }
}

private struct StrategyWidget: View {
    let spec: ChatStrategySpec
    let options: [ChatOption]

    var body: some View {
        WidgetCard {
            if let analysis = StrategyAnalysis(spec: spec, options: options) {
                header(analysis)
                legs(analysis)
                metrics(analysis)
                PayoffChart(analysis: analysis)
                Text("Value at expiry from quoted bid and ask, before fees and taxes. Not advice; quotes may be delayed.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Label("Couldn't price this strategy. Its contracts need quotes from this chat, on one underlying and one expiry.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func header(_ analysis: StrategyAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(spec.name ?? "Strategy").font(.subheadline.weight(.semibold))
                if let outlook = spec.outlook, !outlook.isEmpty {
                    Text(outlook.capitalized)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.wireAccent.opacity(0.15), in: .capsule)
                        .foregroundStyle(Color.wireAccent)
                }
            }
            Text("\(analysis.underlying) · expires \(WidgetFormat.day(analysis.expiration)) · spot \(WidgetFormat.price(analysis.spot))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func legs(_ analysis: StrategyAnalysis) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(analysis.legs.enumerated()), id: \.offset) { index, leg in
                HStack(spacing: 10) {
                    Text(leg.sign > 0 ? "BUY" : "SELL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(leg.sign > 0 ? Color.green : Color.red)
                        .frame(width: 34, alignment: .leading)
                    if let option = leg.option {
                        Text("\(leg.quantity.formatted()) × \(option.strike.formatted(.number.precision(.fractionLength(0...2)))) \(option.isCall ? "Call" : "Put")")
                            .font(.subheadline)
                    } else {
                        Text("\(leg.quantity.formatted()) shares").font(.subheadline)
                    }
                    Spacer(minLength: 4)
                    Text(WidgetFormat.price(leg.entry)).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                if index < analysis.legs.count - 1 { Divider() }
            }
        }
    }

    private func metrics(_ analysis: StrategyAnalysis) -> some View {
        let debit = analysis.net >= 0
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                metric(debit ? "Net cost" : "Net credit", WidgetFormat.money(analysis.net), tint: .primary)
                metric("Breakeven", analysis.breakevens.isEmpty ? "None" : analysis.breakevens.map(WidgetFormat.price).joined(separator: " / "), tint: .primary)
            }
            GridRow {
                metric("Max profit", analysis.maxProfit.map { WidgetFormat.money($0) } ?? "Unlimited", tint: .green)
                metric("Max loss", analysis.maxLoss.map { WidgetFormat.money($0) } ?? "Unlimited", tint: .red)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(tint).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PayoffChart: View {
    let analysis: StrategyAnalysis

    var body: some View {
        let curve = analysis.curve
        Chart {
            ForEach(curve) { point in
                AreaMark(x: .value("Price", point.spot), yStart: .value("Zero", 0.0), yEnd: .value("Profit", max(point.pnl, 0)), series: .value("Side", "gain"))
                    .foregroundStyle(Color.green.opacity(0.25))
            }
            ForEach(curve) { point in
                AreaMark(x: .value("Price", point.spot), yStart: .value("Zero", 0.0), yEnd: .value("Loss", min(point.pnl, 0)), series: .value("Side", "loss"))
                    .foregroundStyle(Color.red.opacity(0.25))
            }
            ForEach(curve) { point in
                LineMark(x: .value("Price", point.spot), y: .value("P/L", point.pnl))
                    .foregroundStyle(Color.wireAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            RuleMark(y: .value("Zero", 0.0)).foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
            RuleMark(x: .value("Now", analysis.spot))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("Now").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXScale(domain: (curve.first?.spot ?? 0)...(curve.last?.spot ?? 1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel { if let price = value.as(Double.self) { Text(WidgetFormat.axis(price)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { if let pnl = value.as(Double.self) { Text(WidgetFormat.axis(pnl)) } }
            }
        }
        .frame(height: 160)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Payoff at expiry. Maximum profit \(analysis.maxProfit.map { WidgetFormat.money($0) } ?? "unlimited"), maximum loss \(analysis.maxLoss.map { WidgetFormat.money($0) } ?? "unlimited").")
    }
}

#if DEBUG
enum ChatWidgetFixture {
    static let options = [
        ChatOption(symbol: "QQQ261030C00600000", strike: 600, bid: 5.05, ask: 5.20, last: 5.10, volume: 8123, openInterest: 21_400, volatility: 0.21, spot: 598.40),
        ChatOption(symbol: "QQQ261030C00610000", strike: 610, bid: 1.75, ask: 1.85, last: 1.80, volume: 5640, openInterest: 17_900, volatility: 0.19, spot: 598.40),
        ChatOption(symbol: "QQQ261030P00590000", strike: 590, bid: 3.40, ask: 3.55, last: 3.45, volume: 4210, openInterest: 12_300, volatility: 0.23, spot: 598.40),
    ]

    static let messages = [
        StockChatMessage(user: true, text: "can you see qqq options?"),
        StockChatMessage(user: false, text: """
        **Yes. QQQ trades at $598.40, and here are the Oct 30 contracts nearest the price.**

        ```options
        {"title":"QQQ Oct 30","contracts":["QQQ261030C00600000","QQQ261030C00610000","QQQ261030P00590000"]}
        ```

        A bull call spread lowers the cost of a bullish bet and caps the gain:

        ```strategy
        {"name":"Bull call spread","outlook":"bullish","legs":[{"contract":"QQQ261030C00600000","side":"buy","qty":1},{"contract":"QQQ261030C00610000","side":"sell","qty":1}]}
        ```

        Sources: Yahoo Finance (delayed quotes).
        """, sources: [StockSource(title: "Yahoo Finance · QQQ", url: URL(string: "https://finance.yahoo.com/quote/QQQ/")!),
                       StockSource(title: "Yahoo Finance chain", url: URL(string: "https://finance.yahoo.com/quote/QQQ/options/")!)],
                         provider: "Fixture", options: options),
    ]
}
#endif
