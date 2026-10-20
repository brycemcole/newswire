import Charts
import SwiftUI

nonisolated struct PortfolioAccount: Identifiable {
    struct ID: Hashable { let item: String; let name: String }
    let id: ID
    let institution: String
    let name: String
    let positions: [Position]
    var reportedValue: Double?
    var history: InvestmentHistory?

    static func group(_ snapshot: PortfolioSnapshot) -> [Self] {
        guard let balances = snapshot.accountBalances, !balances.isEmpty else { return group(snapshot.positions) }
        var accounts = balances.map { balance in
            Self(id: ID(item: balance.itemID, name: balance.accountID), institution: balance.institution, name: balance.name,
                 positions: snapshot.positions.filter { $0.itemID == balance.itemID && $0.id.hasPrefix(balance.accountID + "|") }, reportedValue: balance.value, history: snapshot.histories?.first { $0.itemID == balance.itemID })
        }
        let represented = Set(accounts.flatMap { $0.positions.map(\.id) })
        accounts += group(snapshot.positions.filter { !represented.contains($0.id) })
        return accounts.sorted { ($0.institution, $0.name) < ($1.institution, $1.name) }
    }

    static func group(_ positions: [Position]) -> [Self] {
        Dictionary(grouping: positions) { position in
            ID(item: position.itemID, name: position.id.contains("|") ? String(position.id.split(separator: "|")[0]) : position.account)
        }
            .map { Self(id: $0.key, institution: $0.value[0].institution, name: $0.value[0].account, positions: $0.value) }
            .sorted { ($0.institution, $0.name) < ($1.institution, $1.name) }
    }
}

nonisolated struct PortfolioHolding: Identifiable {
    enum Sort: String, CaseIterable, Identifiable {
        case value = "Value", symbol = "Symbol", gain = "Gain"
        var id: Self { self }
    }
    let symbol: String
    let positions: [Position]
    var id: String { symbol }
    var name: String { positions.first(where: { $0.option == nil })?.name ?? symbol }
    var value: Double? {
        let values = positions.compactMap(\.value)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    var gain: Double? {
        let gains = positions.compactMap(\.gain)
        return gains.isEmpty ? nil : gains.reduce(0, +)
    }
    var partialValue: Bool { positions.contains { $0.value == nil } }
    var partialGain: Bool { positions.contains { $0.gain == nil } }
    var estimated: Bool { positions.contains { $0.isEstimated } }
    var shares: Double { positions.filter { $0.option == nil }.reduce(0) { $0 + $1.quantity } }
    var options: Int { positions.filter { $0.option != nil }.count }
    var accountCount: Int { PortfolioAccount.group(positions).count }

    static func group(_ positions: [Position], search: String, sort: Sort) -> [Self] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return Dictionary(grouping: positions, by: \.symbol)
            .map { Self(symbol: $0.key, positions: $0.value.sorted { $0.id < $1.id }) }
            .filter { query.isEmpty || $0.symbol.localizedCaseInsensitiveContains(query) || $0.positions.contains { ($0.name ?? "").localizedCaseInsensitiveContains(query) } }
            .sorted {
                switch sort {
                case .symbol: return $0.symbol < $1.symbol
                case .value:
                    if $0.value != $1.value { return ($0.value ?? -.infinity) > ($1.value ?? -.infinity) }
                case .gain:
                    if $0.gain != $1.gain { return ($0.gain ?? -.infinity) > ($1.gain ?? -.infinity) }
                }
                return $0.symbol < $1.symbol
            }
    }
}

struct PortfolioHoldingRow: View {
    let holding: PortfolioHolding
    let store: PortfolioStore
    @State private var expanded = false

    init(holding: PortfolioHolding, store: PortfolioStore = .shared) {
        self.holding = holding
        self.store = store
        #if DEBUG
        _expanded = State(initialValue: CommandLine.arguments.contains("-portfolioExpanded") && ["AAPL", "NVDA"].contains(holding.symbol))
        #endif
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(PortfolioAccount.group(holding.positions)) { account in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(account.institution) · \(account.name)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(account.positions) { position in
                        NavigationLink {
                            PortfolioPositionDetail(position: position, store: store)
                        } label: {
                            PositionRow(position: position, showsAccount: false)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            NavigationLink(value: MarketSymbol(id: holding.symbol)) {
                Label("\(holding.symbol) chart & position details", systemImage: "chart.xyaxis.line")
                    .font(.subheadline)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(holding.symbol).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(holding.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(composition).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(holding.value.map { (holding.partialValue ? "Known " : "") + Money.text($0) } ?? "Unavailable")
                            .font(.body.weight(.semibold)).monospacedDigit()
                            .numericTextTransition(value: holding.value)
                        if let gain = holding.gain {
                            Text((holding.estimated ? "≈" : "") + Money.signed(gain))
                                .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(Money.tint(gain))
                            Text(holding.partialGain ? "Partial unrealized" : "Unrealized")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("Unrealized unavailable").font(.caption2).foregroundStyle(.secondary)
                            Text(holding.positions.contains { $0.costBasis == nil } ? "Cost unavailable" : "Value unavailable")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
        }
        .tint(.wireAccent)
    }

    private var composition: String {
        var parts: [String] = []
        if holding.positions.contains(where: { $0.option == nil }) {
            parts.append("\(holding.shares.formatted(.number.precision(.fractionLength(0...4)))) shares")
        }
        if holding.options > 0 { parts.append("\(holding.options) option\(holding.options == 1 ? "" : "s")") }
        parts.append("\(holding.accountCount) account\(holding.accountCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

struct PortfolioOverview: View {
    let snapshot: PortfolioSnapshot
    var title = "All accounts"
    var accounts: [PortfolioAccount] = []
    @State private var funding = PortfolioFundingStore.shared
    @State private var performance = PortfolioPerformance(publishesWidgets: false)
    @State private var selected: PerformancePoint?
    @State private var refreshing = false
    @State private var explainingHistory = false
    @Environment(\.scenePhase) private var phase

    private var range: ChartRange { performance.range }
    private var series: PerformanceSeries? { performance.series[range] }
    private var recorded: [PerformancePoint] { performance.recorded[range] ?? [] }
    private var confirmedFunding: AccountFunding? { funding.combined(for: accounts) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selected == nil ? "\(title) · \(snapshot.reportedValue == nil ? "holdings value" : "brokerage value")" : (series == nil ? "Recorded value at selected sync" : "Estimated value at selected date"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(Money.text(selected?.value ?? snapshot.totalValue))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .numericTextTransition(value: selected?.value ?? snapshot.totalValue)
                if let selected {
                    Text(selected.date.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let totals = confirmedFunding, let value = snapshot.reportedValue, let gain = totals.gain(value: value) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Account gain · all time").font(.caption).foregroundStyle(.secondary)
                    Text((totals.approximate == true ? "≈" : "") + Money.signed(gain))
                        .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Money.tint(gain))
                        .numericTextTransition(value: gain)
                    HStack(alignment: .top, spacing: 16) {
                        metric("Money in", Money.text(totals.contributed))
                        metric("Money out", Money.text(totals.withdrawn ?? 0))
                        metric("Brokerage value", Money.text(value))
                    }

                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    metric(snapshot.reportedValue == nil ? "Holdings + cash" : "Brokerage value", Money.text(snapshot.totalValue))
                    metric("Lifetime gain", "Confirm funding")
                }
                if accounts.count == 1, let account = accounts.first, let history = account.history {
                    let flows = InvestmentCashFlows(history: history, accountID: account.id.name, institution: account.institution)
                    HStack(alignment: .top, spacing: 16) {
                        metric("Recorded deposits", Money.text(flows.contributed))
                        metric("Recorded withdrawals", Money.text(flows.withdrawn))
                    }
                    Text("Review Plaid history to confirm lifetime funding. Purchases and sales are included in activity, not counted as new deposits.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(snapshot.reportedValue == nil ? "Sync brokerage balances and review funding history to calculate return." : "Review funding history or set lifetime contributions to calculate account return.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if series == nil, let first = recorded.first {
                Text("Recorded balances · Since \(first.date.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            chart
            if series == nil, !recorded.isEmpty {
                Text("Includes deposits and withdrawals, not just investment gains. Earlier history is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let series {
                let change = selected.map { series.change(at: $0) } ?? series.change
                let percent = selected.flatMap { series.percent(at: $0) } ?? (selected == nil ? series.percent : nil)
                Text(Money.signed(change) + (percent.map { " (\(Money.percent($0)))" } ?? "") + " · Est. \(range.caption)")
                    .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(Money.tint(change))
                    .numericTextTransition(value: change)
            }
            Picker("Performance range", selection: $performance.range) {
                ForEach(PortfolioPerformance.ranges) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            NavigationLink {
                if accounts.count == 1, let account = accounts.first, let history = account.history {
                    PortfolioHistoryView(account: account, history: history)
                } else { PortfolioFundingView(accounts: accounts) }
            } label: {
                Label("Funding & trades", systemImage: "arrow.down.arrow.up")
                    .font(.subheadline)
            }
            Button { explainingHistory = true } label: {
                Label(series == nil && !recorded.isEmpty ? "About recorded balances" : "Transaction-based performance", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .alert("About this chart", isPresented: $explainingHistory) {
                Button("OK", role: .cancel) {}
            } message: {
                if series == nil, !recorded.isEmpty {
                    Text("These are brokerage-reported account values saved during successful syncs, including cash and options. Plaid's underlying values may be delayed. Only recorded observations are shown; missing earlier dates are not reconstructed. Deposits and withdrawals affect these values, so this is not an investment-return chart.\n\n" + (performance.errors[range] ?? "Complete trade-based performance is unavailable."))
                } else {
                    Text("Daily values reconstruct holdings and cash from recorded trades, including positions sold in full. Dollar gain excludes external deposits and withdrawals and includes income and fees. Percentage uses Modified Dietz, weighting funding by time invested. Order dates are used when available, otherwise posting dates; flows are treated as end-of-day. Values end at the latest brokerage sync. Missing history, option prices or unresolved corporate actions make performance unavailable.")
                }
            }
        }
        .task(id: range) { await refresh() }
        .task(id: snapshot.updated) { await refresh() }
        .task(id: snapshot.failedItemIDs) { await refresh() }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onChange(of: range) { selected = nil }
        .onChange(of: snapshot.positions) { selected = nil }
        .onChange(of: snapshot.updated) { selected = nil }
    }

    private func refresh() async {
        #if DEBUG
        if CommandLine.arguments.contains("-portfolioRecordedPreview") || CommandLine.arguments.contains("-portfolioPartialSync") {
            await performance.refresh(snapshot)
            return
        }
        if CommandLine.arguments.contains("-portfolioLedgerPreview") {
            do {
                let built = try PortfolioLedger(snapshot: snapshot, start: LedgerPreview.day(-4)).build(prices: LedgerPreview.prices)
                performance.preview(range, series: built)
            } catch { performance.previewFailure(range, message: error.localizedDescription) }
            return
        }
        if CommandLine.arguments.contains("-portfolioPreview") {
            for range in PortfolioPerformance.ranges {
                let points = (0..<60).map { index in
                    PerformancePoint(id: index, date: Date.now.addingTimeInterval(Double(index - 59) * (range == .day ? 300 : 86400)), value: snapshot.totalValue - 650 + Double(index) * 11 + sin(Double(index) * 0.4) * 160)
                }
                performance.preview(range, series: PerformanceSeries(points: points, baseline: snapshot.totalValue - 650))
            }
            return
        }
        #endif
        guard !refreshing else { return }
        refreshing = true
        repeat {
            let requested = performance.range
            await performance.refresh(snapshot)
            if requested == performance.range || Task.isCancelled { break }
        } while true
        refreshing = false
    }

    private func metric(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(tint ?? .primary)
                .numericTextTransition(text: value)
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var chart: some View {
        let points = series?.points ?? recorded
        if points.count > 1 {
            let values = points.map(\.value) + (series.map { [$0.baseline] } ?? [])
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let pad = max((high - low) * 0.1, 1)
            let tint = series.map { Money.tint($0.change) } ?? Color.wireAccent
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Date", point.date), yStart: .value("Floor", low - pad), yEnd: .value("Value", point.value))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 2))
                    if series == nil {
                        PointMark(x: .value("Date", point.date), y: .value("Value", point.value))
                            .foregroundStyle(tint).symbolSize(12)
                    }
                }
                if let series {
                    RuleMark(y: .value("Baseline", series.baseline))
                        .foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                if let selected {
                    RuleMark(x: .value("Selected time", selected.date)).foregroundStyle(.secondary)
                    PointMark(x: .value("Date", selected.date), y: .value("Value", selected.value)).foregroundStyle(tint)
                }
            }
            .chartYScale(domain: (low - pad)...(high + pad))
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisValueLabel() } }
            .frame(height: 96)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(.rect)
                        .gesture(LongPressGesture(minimumDuration: 0.15).sequenced(before: DragGesture(minimumDistance: 0))
                            .onChanged { value in
                                guard case .second(true, let drag?) = value, let frame = proxy.plotFrame,
                                      let date: Date = proxy.value(atX: drag.location.x - geometry[frame].origin.x) else { return }
                                selected = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                            }
                            .onEnded { _ in selected = nil })
                }
            }
            .sensoryFeedback(.selection, trigger: selected?.id)
            .accessibilityLabel("\(series == nil ? "Recorded brokerage balances" : "Estimated portfolio value"), \(range.caption)")
        } else {
            VStack(spacing: 8) {
                if series == nil, !recorded.isEmpty {
                    Image(systemName: "chart.xyaxis.line")
                    Text("Recording account values. A graph will appear after another successful sync.")
                } else if refreshing { ProgressView(); Text("Loading performance…") }
                else { Image(systemName: "chart.xyaxis.line"); Text(performance.errors[range] ?? "Performance unavailable") }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 96)
        }
    }
}

struct PortfolioGainSummary: View {
    let positions: [Position]

    var body: some View {
        let known = positions.filter { $0.gain != nil }
        let gain = known.reduce(0) { $0 + ($1.gain ?? 0) }
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent(known.count == positions.count ? "Unrealized gain" : "Partial unrealized gain") {
                Text(known.isEmpty ? "Unavailable" : (known.contains { $0.isEstimated } ? "≈" : "") + Money.signed(gain))
                    .monospacedDigit().foregroundStyle(known.isEmpty ? .secondary : Money.tint(gain))
            }
            Text("Cost available for \(known.count) of \(positions.count) positions · \(known.filter { $0.isEstimated }.count) estimated")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
