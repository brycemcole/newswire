import SwiftUI

nonisolated struct ImpliedVolatility: Sendable, Hashable {
    /// At-the-money implied volatility as a fraction (0.82 = 82%).
    let value: Double
    let expiration: Date
    /// When the chain was fetched; Yahoo's chain carries no per-contract observation time we rely on.
    let fetchedAt: Date
    /// True when no live two-sided quote was available and the value was solved from last trade prices.
    let estimated: Bool

    static let minimumDays = 7.0

    /// Average of the call and put nearest the spot price in the first expiry at least a week out, so expiry-week distortion doesn't dominate the ranking.
    /// Uses Yahoo's IV only while the contract has a live bid and ask (it reports a 0.00001 placeholder otherwise); falls back to solving from the last trade.
    static func parse(_ root: YValue, fetchedAt: Date) -> ImpliedVolatility? {
        guard let result = root["optionChain"]?["result"]?.array.first,
              let spot = result["quote"]?["regularMarketPrice"]?.raw,
              let chain = result["options"]?.array.first,
              let expiration = chain["expirationDate"]?.date else { return nil }
        let years = BlackScholes.years(from: fetchedAt, to: expiration)
        var estimated = false
        func volatility(_ side: String, call: Bool) -> Double? {
            var best: (distance: Double, value: Double, estimated: Bool)?
            for contract in chain[side]?.array ?? [] {
                guard let strike = contract["strike"]?.raw, abs(strike / spot - 1) < 0.1,
                      best.map({ abs(strike - spot) < $0.distance }) ?? true else { continue }
                let bid = contract["bid"]?.raw ?? 0, ask = contract["ask"]?.raw ?? 0
                let live = bid > 0 && ask > 0
                if live, let iv = contract["impliedVolatility"]?.raw, iv > 0.05 {
                    best = (abs(strike - spot), iv, false)
                } else if let last = contract["lastPrice"]?.raw, last > 0,
                          let solved = BlackScholes.impliedVolatility(call: call, premium: live ? (bid + ask) / 2 : last, spot: spot, strike: strike, years: years),
                          solved > 0.05 {
                    best = (abs(strike - spot), solved, true)
                }
            }
            if let best, best.estimated { estimated = true }
            return best?.value
        }
        let sides = [volatility("calls", call: true), volatility("puts", call: false)].compactMap { $0 }
        guard !sides.isEmpty else { return nil }
        return ImpliedVolatility(value: sides.reduce(0, +) / Double(sides.count), expiration: expiration, fetchedAt: fetchedAt, estimated: estimated)
    }

    static func targetExpiration(_ expirations: [Date], after now: Date) -> Date? {
        expirations.first { $0.timeIntervalSince(now) >= minimumDays * 86_400 } ?? expirations.last
    }
}

extension MarketClient {
    @concurrent static func impliedVolatility(_ symbol: String, now: Date = .now) async throws -> ImpliedVolatility? {
        let path = "/v7/finance/options/\(symbol)"
        let first = try await authed(path, [])
        guard let result = first["optionChain"]?["result"]?.array.first else { return nil }
        let expirations = (result["expirationDates"]?.array ?? []).compactMap(\.date)
        let current = result["options"]?.array.first?["expirationDate"]?.date
        if let target = ImpliedVolatility.targetExpiration(expirations, after: now), target != current {
            let page = try await authed(path, [URLQueryItem(name: "date", value: String(Int(target.timeIntervalSince1970)))])
            let r = ImpliedVolatility.parse(page, fetchedAt: now)
            return r
        }
        return ImpliedVolatility.parse(first, fetchedAt: now)
    }
}

struct MoverPill: Identifiable, Hashable {
    let symbol: String
    let label: String
    let changePercent: Double?
    var detail: String?

    var id: String { symbol }

    init(symbol: String, label: String? = nil, changePercent: Double?, detail: String? = nil) {
        self.symbol = symbol
        self.label = label ?? symbol
        self.changePercent = changePercent
        self.detail = detail
    }

    init(_ row: ScreenerRow, metric: ScreenerMetric) {
        self.init(symbol: row.symbol, label: row.label, changePercent: row.changePercent, detail: row.metric(metric))
    }
}

struct MoverPillRows: View {
    let pills: [MoverPill]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                LazyHGrid(rows: [GridItem(.fixed(40), spacing: 8), GridItem(.fixed(40), spacing: 8)], spacing: 8) {
                    ForEach(pills) { pill in
                        Button { onSelect(pill.symbol) } label: { MoverPillLabel(pill: pill) }
                            .buttonStyle(PressSpringStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .frame(height: 88)
    }
}

private struct MoverPillLabel: View {
    let pill: MoverPill

    var body: some View {
        HStack(spacing: 6) {
            Text(pill.label).font(.subheadline.weight(.semibold))
            if let detail = pill.detail {
                Text(detail)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let change = pill.changePercent {
                HStack(spacing: 3) {
                    Image(systemName: change >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 8))
                    Text(String(format: "%.2f%%", abs(change)))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(QuoteFormat.color(change))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 14)
        .frame(height: 40)
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        var parts = [pill.label]
        if let detail = pill.detail { parts.append(detail) }
        if let change = pill.changePercent { parts.append(QuoteFormat.percent(change)) }
        return parts.joined(separator: ", ")
    }
}
