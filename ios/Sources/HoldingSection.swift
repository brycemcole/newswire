import SwiftUI

struct HoldingSection: View {
    let symbol: String
    let chart: MarketChart?
    @State private var store = PortfolioStore.shared

    private var spot: (label: String, price: Double)? {
        guard let chart else { return nil }
        return chart.extendedQuote ?? ("Last", chart.price)
    }

    var body: some View {
        let positions = store.snapshot.positions(for: symbol)
        if !positions.isEmpty {
            QuoteSection("Your Position") {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(positions) { position in
                        PositionCard(symbol: symbol, position: position, spot: spot, store: store)
                    }
                    if let updated = store.snapshot.updated {
                        Text("Brokerage values as of \(updated.formatted(.relative(presentation: .named))). ≈ means cost is estimated from trade history. Estimates use Black-Scholes with the option's implied volatility.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct Stat: Identifiable {
    let label: String
    let value: String
    var tint: Color?
    var id: String { label }
}

private struct StatRows: View {
    let stats: [Stat]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: stats.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(stats[start..<min(start + 2, stats.count)]) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.label).font(.caption).foregroundStyle(.secondary)
                            Text(stat.value).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(stat.tint ?? .primary)
                                .contentTransition(.numericText())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct PositionCard: View {
    let symbol: String
    let position: Position
    let spot: (label: String, price: Double)?
    let store: PortfolioStore
    @State private var quote: OptionQuote?
    @State private var scenario: Double?
    @State private var editingCost = false
    @State private var costText = ""
    @Environment(\.scenePhase) private var phase

    private var estimated: String { position.isEstimated ? "≈" : "" }
    private var multiplier: Double { position.option.map { 100 * abs($0.contracts) } ?? abs(position.quantity) }
    private var sign: Double { (position.option?.contracts ?? position.quantity) < 0 ? -1 : 1 }
    private var estimate: OptionEstimate? {
        guard let quote, let option = position.option else { return nil }
        return OptionEstimate(quote: quote, option: option)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(heading).font(.headline)
                Spacer()
                Text(position.institution).font(.caption).foregroundStyle(.secondary)
            }
            StatRows(stats: position.option == nil ? stockStats : optionStats)
            if let option = position.option, let estimate, let spot {
                scenarioView(option: option, estimate: estimate, spot: spot.price)
            }
            Button(position.manualCost == nil ? "Set cost" : "Edit cost") {
                costText = position.costBasis.map { (abs($0) / multiplier).formatted(.number.precision(.fractionLength(2...4)).grouping(.never)) } ?? ""
                editingCost = true
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .alert(position.option == nil ? "Average cost per share" : "Premium paid per share", isPresented: $editingCost) {
            TextField("0.00", text: $costText).keyboardType(.decimalPad)
            Button("Save") {
                if let perShare = Double(costText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")), perShare >= 0 {
                    store.setCost(position, total: sign * perShare * multiplier)
                }
            }
            if position.manualCost != nil {
                Button("Use Brokerage Cost", role: .destructive) { store.setCost(position, total: nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(position.option == nil ? "Overrides the cost from your trade history." : "The price per share, before the ×100 multiplier.")
        }
        .task(id: phase == .active) {
            guard let option = position.option, phase == .active else { return }
            while !Task.isCancelled {
                if let fresh = try? await OptionChain.quote(symbol: symbol, option: option) { quote = fresh }
                do { try await Task.sleep(for: .seconds(quote?.liveMarket == true ? 20 : 120)) } catch { return }
            }
        }
    }

    private var heading: String {
        guard let option = position.option else {
            return "\(position.quantity.formatted(.number.precision(.fractionLength(0...4)))) shares"
        }
        let count = option.contracts.formatted(.number.precision(.fractionLength(0...2)))
        return "\(option.title) · \(option.expiration.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))) · ×\(count)"
    }

    private func gain(_ value: Double) -> Stat? {
        guard let cost = position.costBasis else { return nil }
        let gain = value - cost
        let percent = cost != 0 ? " (\(Money.percent(gain / abs(cost))))" : ""
        return Stat(label: "Gain", value: estimated + Money.signed(gain) + percent, tint: Money.tint(gain))
    }

    private var stockStats: [Stat] {
        var stats: [Stat] = []
        let value = spot.map { $0.price * position.quantity } ?? position.value
        if let value {
            let label = spot.map { $0.label == "Last" ? "Value now" : "Value (\($0.label.lowercased()))" } ?? "Value"
            stats.append(Stat(label: label, value: Money.text(value)))
        }
        if let cost = position.costBasis, position.quantity != 0 {
            stats.append(Stat(label: "Avg cost", value: estimated + Money.text(cost / position.quantity)))
        }
        if let value, let gain = gain(value) { stats.append(gain) }
        return stats
    }

    private var optionStats: [Stat] {
        guard let option = position.option else { return [] }
        var stats: [Stat] = []
        let contracts = 100 * option.contracts
        if let quote {
            let label = quote.liveMarket ? "Option mid" : "Last trade"
            stats.append(Stat(label: label, value: "\(Money.text(quote.mark)) · \(Money.text(quote.mark * contracts))"))
        } else if let value = position.value {
            stats.append(Stat(label: "Brokerage value", value: Money.text(value)))
        }
        if let estimate, let spot, !(quote?.liveMarket ?? false) || spot.label != "Last" {
            let value = estimate.perShare(at: spot.price) * contracts
            stats.append(Stat(label: "Est. now at \(spot.label.lowercased()) \(Money.text(spot.price))", value: Money.text(value)))
            if let gain = gain(value) { stats.append(Stat(label: "Est. gain now", value: gain.value, tint: gain.tint)) }
        } else if let value = quote.map({ $0.mark * contracts }) ?? position.value, let gain = gain(value) {
            stats.append(gain)
        }
        if let cost = position.costBasis { stats.append(Stat(label: "Paid", value: estimated + Money.text(abs(cost)))) }
        if let breakeven = position.breakeven {
            var text = Money.text(breakeven)
            if let spot, spot.price != 0 { text += " (\(Money.percent(breakeven / spot.price - 1)))" }
            stats.append(Stat(label: "Breakeven at expiry", value: estimated + text))
        }
        if let spot {
            let distance = option.isCall ? spot.price - option.strike : option.strike - spot.price
            stats.append(Stat(label: distance >= 0 ? "In the money" : "Out of the money", value: Money.text(abs(distance)) + " / share"))
        }
        if let estimate { stats.append(Stat(label: "Implied volatility", value: estimate.volatility.formatted(.percent.precision(.fractionLength(0))))) }
        stats.append(Stat(label: "Time left", value: option.daysLeft < 0 ? "Expired" : option.daysLeft == 0 ? "Expires today" : "\(option.daysLeft) days"))
        return stats
    }

    @ViewBuilder
    private func scenarioView(option: OptionDetail, estimate: OptionEstimate, spot: Double) -> some View {
        let price = scenario ?? spot
        let contracts = 100 * option.contracts
        let today = estimate.perShare(at: price) * contracts
        let expiry = option.intrinsic(at: price) * (option.contracts < 0 ? -1 : 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("If \(symbol) is \(Money.text(price))").font(.subheadline.weight(.semibold)).monospacedDigit()
                Spacer()
                if scenario != nil {
                    Button("Reset") { scenario = nil }.font(.footnote).buttonStyle(.borderless)
                }
            }
            Slider(value: Binding(get: { price }, set: { scenario = $0 }), in: (spot * 0.75)...(spot * 1.25))
                .accessibilityLabel("\(symbol) price")
            StatRows(stats: [
                Stat(label: "Worth today", value: Money.text(today), tint: position.costBasis.map { Money.tint(today - $0) }),
                Stat(label: "Worth at expiry", value: Money.text(expiry), tint: position.costBasis.map { Money.tint(expiry - $0) }),
            ])
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .sensoryFeedback(.selection, trigger: scenario.map { ($0 / max(spot * 0.01, 0.01)).rounded() })
    }
}
