import Charts
import SwiftUI

/// The Portfolio tab: value and graph on top, accounts, then stocks and options with live prices.
/// With nothing linked it shows clearly labelled sample data so the layout is visible; sample numbers never reach the shared store.
struct PortfolioHome: View {
    @State private var store = PortfolioStore.shared
    @State private var board = MarketBoard.shared
    @State private var optionQuotes: [String: OptionQuote] = [:]
    @State private var account: PortfolioAccount.ID?
    @State private var sampleAccount: Int?
    @State private var sampleRange = SamplePortfolio.Range.month
    @State private var selectedDate: Date?
    @State private var showingSettings = false
    @Environment(\.scenePhase) private var scenePhase

    private var accounts: [PortfolioAccount] { PortfolioAccount.group(store.snapshot) }
    private var isSample: Bool { accounts.isEmpty && store.snapshot.cash == 0 }

    // MARK: Real data

    private var selectedPositions: [Position] {
        guard let account else { return store.snapshot.positions }
        return accounts.first { $0.id == account }?.positions ?? []
    }

    private var overviewSnapshot: PortfolioSnapshot {
        guard let account, let entry = accounts.first(where: { $0.id == account }) else { return store.snapshot }
        let balances = store.snapshot.accountBalances?.filter { $0.itemID == account.item && $0.accountID == account.name }
        let residual = entry.reportedValue.map { $0 - entry.positions.compactMap(\.value).reduce(0, +) }
        var scoped = store.snapshot.itemScope(account.item)
        scoped.positions = entry.positions
        scoped.cashByItem = residual.map { [account.item: $0] } ?? [:]
        scoped.accountBalances = balances
        return scoped
    }

    private var realLines: [HoldingLine] {
        let positions = selectedPositions
        _ = store.snapshot.updated
        let rows = PositionMoversCard.rows(positions: positions, quotes: board.quotes, options: optionQuotes, now: .now)
        return rows.map { row in
            let isOption = positions.first { $0.id == row.id }?.option != nil
            let valueText = row.value.map(HomeFormat.whole)
            let detail = row.detail.components(separatedBy: " · ").filter { $0 != valueText && $0 != valueText.map({ "≈" + $0 }) }.joined(separator: " · ")
            return HoldingLine(id: row.id, symbol: row.symbol, title: row.title, detail: detail, value: row.value,
                               dayDollars: row.dollars, dayPercent: row.percent, fallback: row.fallback?.text, fallbackTint: row.fallback?.tint,
                               isOption: isOption, urgent: row.urgent, estimated: row.proxy != nil, valueEstimated: row.valueEstimated)
        }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if isSample { sampleBanner }
                    header
                    accountStrip
                    cashRow
                    let lines = isSample ? SamplePortfolio.lines(account: sampleAccount) : realLines
                    section("Stocks & ETFs", lines.filter { !$0.isOption })
                    section("Options", lines.filter(\.isOption))
                    if lines.isEmpty && !isSample {
                        ContentUnavailableView("No open positions", systemImage: "chart.pie",
                                               description: Text("Cash and sale proceeds remain included in your account value."))
                    }
                    Button { showingSettings = true } label: {
                        Label("Brokerages, funding and sync", systemImage: "gearshape").font(.subheadline)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .refreshable { if !isSample { await store.sync() } }
            .navigationTitle("Portfolio")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MarketSymbol.self) { QuoteDetail(symbol: $0.id) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Brokerages and sync")
                }
            }
            .sheet(isPresented: $showingSettings) { PortfolioView() }
            .asksAbout(AskContext(screen: askScreen))
            .task {
                store.reloadFromKeychain()
                let snapshot = store.snapshot
                if !accounts.isEmpty, (snapshot.updated ?? .distantPast).timeIntervalSinceNow < -300 { await store.sync() }
            }
            .task(id: "\(selectedPositions.map(\.id))-\(scenePhase == .active)-\(isSample)") { await refreshQuotes() }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private var askScreen: String {
        if isSample { return "The Portfolio tab showing sample data because no brokerage is linked on this install." }
        let positions = selectedPositions.filter { $0.value != nil }.sorted { ($0.value ?? 0) > ($1.value ?? 0) }
        let total = positions.compactMap(\.value).reduce(0, +)
        let top = positions.prefix(12).map { "\($0.symbol) \(Money.text($0.value ?? 0))" }.joined(separator: ", ")
        return "The Portfolio screen: \(positions.count) positions worth \(Money.text(total)). Largest: \(top)."
    }

    // MARK: Header and chart

    @ViewBuilder private var header: some View {
        if isSample {
            sampleHeader
        } else {
            PortfolioOverview(snapshot: overviewSnapshot, title: account == nil ? "All accounts" : accounts.first { $0.id == account }?.institution ?? "Account",
                              accounts: account.flatMap { id in accounts.first { $0.id == id }.map { [$0] } } ?? accounts)
                .id(account)
        }
    }

    private var sampleHeader: some View {
        let series = SamplePortfolio.series(range: sampleRange, end: SamplePortfolio.total(account: sampleAccount), seed: Double(sampleAccount ?? 2))
        let selected = selectedDate.flatMap { date in series.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        let shown = selected ?? series.last!
        let change = shown.value - series.first!.value
        let percent = change / series.first!.value * 100
        let tint = HomeFormat.tint(change)
        return VStack(alignment: .leading, spacing: 8) {
            Text(Money.text(shown.value))
                .font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                .numericTextTransition(value: shown.value)
            Text("\(HomeFormat.dollars(change)) (\(HomeFormat.percent(percent))) · \(sampleRange.caption)")
                .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(tint)
            Chart(series) { point in
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                    .interpolationMethod(.monotone).foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 2))
                if let selected, selected.id == point.id {
                    RuleMark(x: .value("Date", point.date)).foregroundStyle(.secondary.opacity(0.5))
                    PointMark(x: .value("Date", point.date), y: .value("Value", point.value)).foregroundStyle(tint)
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: (series.map(\.value).min() ?? 0) * 0.995 ... (series.map(\.value).max() ?? 1) * 1.005)
            .frame(height: 190)
            Picker("Range", selection: $sampleRange) {
                ForEach(SamplePortfolio.Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var sampleBanner: some View {
        Button { showingSettings = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "eye").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sample data").font(.subheadline.weight(.semibold))
                    Text("No brokerage is linked on this install. Link one to see your own portfolio.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: Accounts

    private var accountStrip: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if isSample {
                    accountCard(title: "All accounts", subtitle: "\(SamplePortfolio.accountNames.count) accounts", value: SamplePortfolio.total(account: nil), selected: sampleAccount == nil) { sampleAccount = nil }
                        .id("all")
                    ForEach(SamplePortfolio.accountNames.indices, id: \.self) { index in
                        accountCard(title: SamplePortfolio.accountNames[index], subtitle: SamplePortfolio.institutions[index], value: SamplePortfolio.total(account: index), selected: sampleAccount == index) { sampleAccount = index }
                            .id("sample-\(index)")
                    }
                } else {
                    accountCard(title: "All accounts", subtitle: "\(accounts.count) account\(accounts.count == 1 ? "" : "s")", value: store.snapshot.totalValue, selected: account == nil) { account = nil }
                        .id("all")
                    ForEach(accounts) { entry in
                        let value = entry.reportedValue ?? entry.positions.compactMap(\.value).reduce(0, +)
                        accountCard(title: entry.name, subtitle: entry.institution, value: value, selected: account == entry.id) { account = entry.id }
                            .id("\(entry.id.item)|\(entry.id.name)")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .onChange(of: sampleAccount) { _, new in withAnimation { proxy.scrollTo(new.map { "sample-\($0)" } ?? "all", anchor: .center) } }
        .onChange(of: account) { _, new in withAnimation { proxy.scrollTo(new.map { "\($0.item)|\($0.name)" } ?? "all", anchor: .center) } }
        }
    }

    private func accountCard(title: String, subtitle: String, value: Double, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(Money.text(value)).font(.callout.weight(.semibold)).monospacedDigit().padding(.top, 4)
            }
            .frame(minWidth: 120, alignment: .leading)
            .padding(12)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var cashRow: some View {
        let cash: Double? = isSample ? SamplePortfolio.cash(account: sampleAccount) : (account == nil ? store.snapshot.cash : overviewSnapshot.cash)
        return HStack {
            Text("Cash").font(.subheadline.weight(.semibold))
            Spacer()
            Text(cash.map { Money.text($0) } ?? "—").font(.subheadline).monospacedDigit()
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
    }

    // MARK: Holdings

    @ViewBuilder private func section(_ title: String, _ lines: [HoldingLine]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title3.weight(.bold))
                    Text("\(lines.count)").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if lines.contains(where: { $0.dayDollars != nil }) {
                        let total = lines.compactMap(\.dayDollars).reduce(0, +)
                        Text("\(HomeFormat.dollars(total)) today").font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(HomeFormat.tint(total))
                    }
                }
                .padding(.bottom, 8)
                ForEach(lines) { line in
                    row(line)
                    if line.id != lines.last?.id { Divider() }
                }
            }
        }
    }

    private func row(_ line: HoldingLine) -> some View {
        let content = HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(line.title).font(.body.weight(.semibold)).lineLimit(1)
                    if line.urgent { Image(systemName: "hourglass").font(.caption2).foregroundStyle(.orange) }
                }
                Text(line.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(line.value.map { (line.valueEstimated ? "≈" : "") + Money.text($0) } ?? "—").font(.body.weight(.semibold)).monospacedDigit()
                pill(line)
            }
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
        return NavigationLink(value: MarketSymbol(id: line.symbol)) { content }.buttonStyle(.plain)
    }

    @ViewBuilder private func pill(_ line: HoldingLine) -> some View {
        if let dollars = line.dayDollars {
            let text = (line.estimated ? "≈" : "") + (line.dayPercent.map { HomeFormat.percent($0) } ?? HomeFormat.dollars(dollars))
            Text(text).modifier(ChangePill(tint: HomeFormat.tint(dollars)))
        } else if let fallback = line.fallback {
            Text(fallback).modifier(ChangePill(tint: HomeFormat.tint(line.fallbackTint)))
        } else {
            Text("—").modifier(ChangePill(tint: .secondary))
        }
    }

    // MARK: Live prices

    private func refreshQuotes() async {
        guard scenePhase == .active, !isSample else { optionQuotes = [:]; return }
        while !Task.isCancelled {
            await board.refresh(quotes: HomeSymbols.quoted, sparks: [])
            let held = store.snapshot.positions.filter { ($0.option?.daysLeft ?? -1) >= 0 }
            if held.isEmpty {
                optionQuotes = [:]
            } else {
                let found = await withTaskGroup(of: (String, OptionQuote?).self) { group in
                    for position in held {
                        group.addTask { (position.id, try? await OptionChain.quote(symbol: HomeSymbols.normalize(position.symbol), option: position.option!)) }
                    }
                    var result: [String: OptionQuote] = [:]
                    for await (id, quote) in group { if let quote { result[id] = quote } }
                    return result
                }
                guard !Task.isCancelled else { return }
                // A failed fetch drops the contract back to its synced value rather than keeping an older quote as current.
                optionQuotes = found
            }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }
}

private struct HoldingLine: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let value: Double?
    /// Today's change in dollars, nil when unavailable rather than zero.
    let dayDollars: Double?
    let dayPercent: Double?
    /// Shown instead of today's change when it is unavailable, such as the total gain on an option that hasn't traded today.
    var fallback: String?
    var fallbackTint: Double?
    let isOption: Bool
    var urgent = false
    /// The change is estimated from a tracking fund rather than the holding's own price.
    var estimated = false
    /// The value is a model estimate at the underlying's current price.
    var valueEstimated = false
}

private struct ChangePill: ViewModifier {
    let tint: Color
    func body(content: Content) -> some View {
        content
            .font(.footnote.weight(.semibold)).monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.16), in: .capsule)
    }
}

/// Invented numbers for the empty state. Deterministic, and never written to the portfolio store.
private enum SamplePortfolio {
    enum Range: String, CaseIterable, Identifiable {
        case day = "1D", week = "1W", month = "1M", quarter = "3M", year = "1Y", all = "ALL"
        var id: Self { self }
        var caption: String {
            switch self {
            case .day: "Today"
            case .week: "Past week"
            case .month: "Past month"
            case .quarter: "Past 3 months"
            case .year: "Past year"
            case .all: "All time"
            }
        }
        var days: Double { switch self { case .day: 1; case .week: 7; case .month: 30; case .quarter: 90; case .year: 365; case .all: 730 } }
        var points: Int { switch self { case .day: 78; case .week: 70; case .month: 60; case .quarter: 90; case .year: 120; case .all: 150 } }
        var move: Double { switch self { case .day: 0.009; case .week: 0.021; case .month: 0.048; case .quarter: 0.095; case .year: 0.21; case .all: 0.44 } }
    }

    struct Point: Identifiable { let id: Int; let date: Date; let value: Double }

    struct Stock { let symbol: String; let name: String; let shares: Double; let price: Double; let dayPercent: Double; let account: Int }
    struct Option { let symbol: String; let title: String; let contracts: Double; let mark: Double; let dayPercent: Double; let totalGain: Double; let days: Int; let account: Int }

    static let accountNames = ["Individual ••1234", "Roth IRA ••9012"]
    static let institutions = ["Fidelity", "SoFi"]
    private static let cashByAccount = [3_250.0, 1_250.0]

    static let stocks: [Stock] = [
        Stock(symbol: "NVDA", name: "NVIDIA", shares: 40, price: 182.4, dayPercent: 2.4, account: 0),
        Stock(symbol: "AAPL", name: "Apple", shares: 30, price: 231.1, dayPercent: 0.6, account: 0),
        Stock(symbol: "MSFT", name: "Microsoft", shares: 14, price: 428.7, dayPercent: -0.3, account: 0),
        Stock(symbol: "AMZN", name: "Amazon", shares: 22, price: 214.5, dayPercent: 1.1, account: 0),
        Stock(symbol: "GOOGL", name: "Alphabet", shares: 25, price: 176.2, dayPercent: -0.8, account: 0),
        Stock(symbol: "TSLA", name: "Tesla", shares: 12, price: 342.9, dayPercent: -2.1, account: 0),
        Stock(symbol: "VOO", name: "Vanguard S&P 500 ETF", shares: 18, price: 578.3, dayPercent: 0.4, account: 1),
        Stock(symbol: "VTI", name: "Vanguard Total Stock Market", shares: 30, price: 289.6, dayPercent: 0.3, account: 1),
        Stock(symbol: "QQQ", name: "Invesco QQQ", shares: 10, price: 512.2, dayPercent: 0.9, account: 1),
        Stock(symbol: "AMD", name: "Advanced Micro Devices", shares: 35, price: 154.8, dayPercent: 3.2, account: 1),
        Stock(symbol: "PLTR", name: "Palantir", shares: 60, price: 79.4, dayPercent: -1.6, account: 1),
        Stock(symbol: "SOFI", name: "SoFi Technologies", shares: 120, price: 17.9, dayPercent: 1.8, account: 1),
    ]

    static let options: [Option] = [
        Option(symbol: "SPY", title: "SPY $734 Call", contracts: 1, mark: 1.16, dayPercent: -8.2, totalGain: -95.66, days: 4, account: 0),
        Option(symbol: "DELL", title: "DELL $370 Call", contracts: 1, mark: 0.16, dayPercent: -12.5, totalGain: -209.05, days: 9, account: 0),
        Option(symbol: "NVDA", title: "NVDA $200 Call", contracts: 2, mark: 3.40, dayPercent: 6.3, totalGain: 180, days: 23, account: 1),
        Option(symbol: "AMD", title: "AMD $170 Call", contracts: 3, mark: 2.05, dayPercent: 9.7, totalGain: 95, days: 37, account: 1),
    ]

    private static func inScope(_ account: Int?, _ item: Int) -> Bool { account == nil || account == item }

    static func lines(account: Int?) -> [HoldingLine] {
        let stockLines = stocks.filter { inScope(account, $0.account) }.map { stock -> HoldingLine in
            let value = stock.shares * stock.price
            return HoldingLine(id: "sample-\(stock.symbol)", symbol: stock.symbol, title: stock.symbol,
                               detail: "\(stock.shares.formatted(.number.precision(.fractionLength(0...2)))) sh · \(stock.name)", value: value,
                               dayDollars: value * stock.dayPercent / 100 / (1 + stock.dayPercent / 100), dayPercent: stock.dayPercent,
                               isOption: false)
        }
        let optionLines = options.filter { inScope(account, $0.account) }.map { option -> HoldingLine in
            let value = option.mark * 100 * option.contracts
            return HoldingLine(id: "sample-\(option.title)", symbol: option.symbol, title: option.title,
                               detail: "\(option.contracts.formatted(.number.precision(.fractionLength(0...2)))) ct · \(option.days) DTE", value: value,
                               dayDollars: value * option.dayPercent / 100 / (1 + option.dayPercent / 100), dayPercent: option.dayPercent,
                               isOption: true, urgent: option.days <= 7)
        }
        return stockLines.sorted { ($0.value ?? 0) > ($1.value ?? 0) } + optionLines
    }

    static func cash(account: Int?) -> Double {
        cashByAccount.indices.filter { inScope(account, $0) }.map { cashByAccount[$0] }.reduce(0, +)
    }

    static func total(account: Int?) -> Double {
        lines(account: account).compactMap(\.value).reduce(cash(account: account), +)
    }

    static func series(range: Range, end: Double, seed: Double) -> [Point] {
        let start = Date.now.addingTimeInterval(-range.days * 86_400)
        let count = range.points
        let base = end / (1 + range.move)
        return (0..<count).map { index in
            let progress = Double(index) / Double(count - 1)
            let wobble = sin(Double(index) * (0.7 + seed * 0.13) + seed) * 0.004 + sin(Double(index) * (0.23 + seed * 0.05) + 1 + seed * 2) * 0.006
            let value = index == count - 1 ? end : base * (1 + range.move * progress + wobble * (1 - progress * 0.3))
            return Point(id: index, date: start.addingTimeInterval(range.days * 86_400 * progress), value: value)
        }
    }
}
