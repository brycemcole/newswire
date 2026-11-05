import SwiftUI

struct HoldingSection: View {
    let symbol: String
    let chart: MarketChart?
    @State private var store = PortfolioStore.shared
    @Environment(\.scenePhase) private var phase

    private var spot: (label: String, price: Double)? {
        guard let chart else { return nil }
        return chart.extendedQuote ?? ("Last", chart.price)
    }

    var body: some View {
        content.task(id: phase == .active) {
            guard phase == .active, !store.syncing, (store.snapshot.updated ?? .distantPast).timeIntervalSinceNow < -60 else { return }
            await store.sync()
        }
    }

    @ViewBuilder private var content: some View {
        let positions = store.snapshot.positions(for: symbol).filter { ($0.option?.daysLeft ?? 0) >= 0 }
        if !positions.isEmpty {
            QuoteSection("Your Position") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(positions) { position in
                        VStack(alignment: .leading, spacing: 6) {
                            PositionCard(symbol: symbol, position: position, spot: spot, store: store)
                            if store.snapshot.isStale(position.itemID) {
                                Text("Brokerage not refreshed · showing cached values")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    if let updated = store.snapshot.aggregateSyncedAt {
                        Text("Brokerages synced \(updated.formatted(.relative(presentation: .named)))")
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
        VStack(spacing: 8) {
            ForEach(stats) { stat in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(stat.label).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(stat.value).fontWeight(.medium).monospacedDigit()
                        .foregroundStyle(stat.tint ?? .primary)
                        .multilineTextAlignment(.trailing)
                        .numericTextTransition(text: stat.value)
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct PositionCard: View {
    let symbol: String
    let position: Position
    let spot: (label: String, price: Double)?
    let store: PortfolioStore
    var requestsOptionQuote = true
    var previewQuote: OptionQuote?
    @State private var fetchedQuote: OptionQuote?
    @State private var scenario: Double?
    @State private var showingDetails = false
    @State private var editingCost = false
    @State private var costText = ""
    @Environment(\.scenePhase) private var phase

    private var quote: OptionQuote? { fetchedQuote ?? previewQuote }
    private var estimated: String { position.isEstimated ? "≈" : "" }
    private var multiplier: Double { position.option.map { 100 * abs($0.contracts) } ?? abs(position.quantity) }
    private var estimate: OptionEstimate? {
        guard let quote, let option = position.option else { return nil }
        return OptionEstimate(quote: quote, option: option)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(heading).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Text(position.institution).font(.caption).foregroundStyle(.secondary)
            }
            summary
            if let option = position.option {
                DisclosureGroup("Scenario, cost & details", isExpanded: $showingDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let estimate, let spot {
                            scenarioView(option: option, estimate: estimate, spot: spot)
                        }
                        costSection
                        StatRows(stats: optionDetails(option))
                        if estimate != nil {
                            Text("Est. values use Black-Scholes with the option's implied volatility.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.footnote.weight(.medium))
            } else {
                costSection
            }
        }
        .alert(position.option == nil ? "Average cost per share" : "Premium paid per share", isPresented: $editingCost) {
            TextField("0.00", text: $costText).keyboardType(.decimalPad)
            Button("Save") {
                if let total = position.totalCost(averageCost: costText) {
                    store.setCost(position, total: total)
                }
            }
            .disabled(position.totalCost(averageCost: costText) == nil)
            if position.manualCost != nil {
                Button("Use Brokerage Cost", role: .destructive) { store.setCost(position, total: nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(position.option == nil ? "Enter the average cost verified with your brokerage, not the current price. This local override calculates unrealized gain, not daily change. It does not change your brokerage account." : "The price per share, before the ×100 multiplier. This local override does not change your brokerage account.")
        }
        .task(id: phase == .active) {
            guard requestsOptionQuote, let option = position.option, phase == .active else { return }
            while !Task.isCancelled {
                if let fresh = try? await OptionChain.quote(symbol: symbol, option: option) { fetchedQuote = fresh }
                do { try await Task.sleep(for: .seconds(quote?.liveMarket == true ? 20 : 120)) } catch { return }
            }
        }
    }

    private var heading: String {
        guard let option = position.option else {
            return "\(position.quantity.formatted(.number.precision(.fractionLength(0...4)))) shares"
        }
        let sameYear = Calendar.current.isDate(option.expiration, equalTo: .now, toGranularity: .year)
        let date = sameYear ? option.expiration.formatted(.dateTime.month(.abbreviated).day()) : option.expiration.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))
        let left = option.daysLeft < 0 ? "Expired" : option.daysLeft == 0 ? "Expires today" : option.daysLeft == 1 ? "1 day left" : "\(option.daysLeft) days left"
        let count = option.contracts == 1 ? "" : " · ×\(option.contracts.formatted(.number.precision(.fractionLength(0...2))))"
        return "\(option.title) · \(date) · \(left)\(count)"
    }

    private func gain(_ value: Double) -> (text: String, tint: Color)? {
        guard let cost = position.costBasis else { return nil }
        let gain = value - cost
        let percent = cost != 0 ? " (\(Money.percent(gain / abs(cost))))" : ""
        return (estimated + Money.signed(gain) + percent, Money.tint(gain))
    }

    private var current: (label: String, value: Double, gainLabel: String)? {
        guard let option = position.option else {
            guard let value = spot.map({ $0.price * position.quantity }) ?? position.value else { return nil }
            let label = spot.map { $0.label == "Last" ? "Value now" : "Value (\($0.label.lowercased()))" } ?? "Value"
            return (label, value, "Unrealized gain")
        }
        let contracts = 100 * option.contracts
        if let estimate, let spot, !(quote?.liveMarket ?? false) || spot.label != "Last" {
            let session = spot.label == "Last" ? "" : " · \(spot.label.lowercased())"
            return ("Est. value\(session)", estimate.perShare(at: spot.price) * contracts, "Est. gain")
        }
        if let quote {
            return (quote.liveMarket ? "Value at option mid" : "Value at last trade", quote.mark * contracts, "Unrealized gain")
        }
        return position.value.map { ("Brokerage value", $0, "Unrealized gain") }
    }

    private var summary: some View {
        let result = current.flatMap { gain($0.value) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let current {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        Text(Money.text(current.value)).font(.title2.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .numericTextTransition(text: Money.text(current.value))
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(current?.gainLabel ?? "Unrealized gain").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(result?.text ?? "Unavailable").font(.headline).monospacedDigit()
                        .foregroundStyle(result?.tint ?? .secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .numericTextTransition(text: result?.text ?? "Unavailable")
                }
                .accessibilityElement(children: .combine)
            }
            if position.option != nil, let breakeven = position.breakeven {
                Text("Breaks even at \(estimated)\(Money.text(breakeven))\(breakevenMove(breakeven)) at expiry")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func breakevenMove(_ breakeven: Double) -> String {
        guard let spot, spot.price != 0 else { return "" }
        return " (\(Money.percent(breakeven / spot.price - 1)))"
    }

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(costLabel).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(costValue).fontWeight(.medium).monospacedDigit()
                Button(position.manualCost == nil ? "Set cost" : "Edit cost") {
                    costText = position.costBasis.map { (abs($0) / multiplier).formatted(.number.precision(.fractionLength(2...4)).grouping(.never)) } ?? ""
                    editingCost = true
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.mini)
                .disabled(multiplier == 0 || !multiplier.isFinite)
            }
            .font(.footnote)
            if position.manualCost != nil {
                Text("Using your verified cost override").font(.caption).foregroundStyle(.secondary)
            } else if position.costBasis == nil {
                Text("Cost basis unavailable from brokerage and reconciled trade history. Unrealized gain is unavailable, not zero.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if position.isEstimated {
                Text("≈ estimated from trade history").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var costLabel: String {
        guard let option = position.option else { return "Avg cost" }
        return option.contracts < 0 ? "Received" : "Paid"
    }

    private var costValue: String {
        guard let cost = position.costBasis else { return "Unavailable" }
        if position.option == nil {
            return position.quantity == 0 ? "Unavailable" : estimated + Money.text(cost / position.quantity)
        }
        return estimated + Money.text(abs(cost))
    }

    private func optionDetails(_ option: OptionDetail) -> [Stat] {
        var stats: [Stat] = []
        if let quote {
            stats.append(Stat(label: quote.liveMarket ? "Option mid" : "Last option trade", value: "\(Money.text(quote.mark)) / share"))
        }
        if let spot {
            let distance = option.isCall ? spot.price - option.strike : option.strike - spot.price
            let side = spot.price >= option.strike ? "above" : "below"
            stats.append(Stat(label: distance >= 0 ? "In the money" : "Out of the money", value: "\(symbol) \(Money.text(abs(spot.price - option.strike))) \(side) strike"))
        }
        if let estimate { stats.append(Stat(label: "Implied volatility", value: estimate.volatility.formatted(.percent.precision(.fractionLength(0))))) }
        return stats
    }

    @ViewBuilder
    private func scenarioView(option: OptionDetail, estimate: OptionEstimate, spot: (label: String, price: Double)) -> some View {
        let price = scenario ?? spot.price
        let contracts = 100 * option.contracts
        let today = estimate.perShare(at: price) * contracts
        let expiry = option.intrinsic(at: price)
        VStack(alignment: .leading, spacing: 6) {
            scenarioHeader(price: price, spot: spot.price)
            Slider(value: Binding(get: { price }, set: { scenario = $0 }), in: (spot.price * 0.75)...(spot.price * 1.25))
                .accessibilityLabel("\(symbol) price")
                .accessibilityValue(Money.text(price))
            HStack(alignment: .top, spacing: 16) {
                outcome(option.contracts < 0 ? "Closed today" : "Sold today", value: today)
                outcome("Held to expiry", value: expiry)
            }
        }
        .sensoryFeedback(.selection, trigger: scenario.map { ($0 / max(spot.price * 0.01, 0.01)).rounded() })
    }

    private func scenarioHeader(price: Double, spot: Double) -> some View {
        let move: String? = scenario != nil && spot != 0 ? Money.percent(price / spot - 1) : nil
        let formatted: String = Money.text(price)
        return HStack(alignment: .firstTextBaseline) {
            Text("If \(symbol) is \(formatted)").font(.subheadline.weight(.semibold)).monospacedDigit()
                .numericTextTransition(text: formatted)
            if let move {
                Text(move).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if scenario != nil {
                Button("Reset") { withAnimation(.snappy) { scenario = nil } }.font(.footnote).buttonStyle(.borderless)
            } else {
                Text("Drag to try a price").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func outcome(_ label: String, value: Double) -> some View {
        let change = position.costBasis.map { value - $0 }
        return VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Money.text(value)).font(.subheadline.weight(.semibold))
                    .numericTextTransition(text: Money.text(value))
                if let change {
                    Text(estimated + Money.signed(change)).font(.caption.weight(.medium)).foregroundStyle(Money.tint(change))
                        .numericTextTransition(text: Money.signed(change))
                }
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
