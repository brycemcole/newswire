import Charts
import SwiftUI

nonisolated struct PaperTrade: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    let symbol: String
    let date: Date
    let price: Double
    let amount: Double

    var shares: Double { amount / price }
    func value(at price: Double) -> Double { shares * price }
}

@Observable final class PaperPortfolio {
    static let shared = PaperPortfolio()
    private(set) var trades: [PaperTrade]

    private init() {
        trades = UserDefaults.standard.data(forKey: "paperTrades").flatMap { try? JSONDecoder().decode([PaperTrade].self, from: $0) } ?? []
    }

    func trades(for symbol: String) -> [PaperTrade] { trades.filter { $0.symbol == symbol } }

    func add(_ trade: PaperTrade) { save(trades + [trade]) }

    func remove(_ trade: PaperTrade) { save(trades.filter { $0.id != trade.id }) }

    private func save(_ next: [PaperTrade]) {
        trades = next
        UserDefaults.standard.set(try? JSONEncoder().encode(next), forKey: "paperTrades")
    }
}

nonisolated struct Backtest: Sendable {
    let start: HistoryPoint
    let points: [HistoryPoint]
    let amount: Double
    let price: Double

    /// Buys at the close of the first trading day on or after `date`, and values the position at `price`.
    init?(history: [HistoryPoint], from date: Date, amount: Double, price: Double?) {
        let day = Calendar.current.startOfDay(for: date)
        guard amount > 0, let index = history.firstIndex(where: { $0.date >= day }) else { return nil }
        let points = Array(history[index...])
        guard let price = price ?? points.last?.close else { return nil }
        start = points[0]
        self.points = points
        self.amount = amount
        self.price = price
    }

    var shares: Double { amount / start.close }
    var value: Double { shares * price }
    var gain: Double { value - amount }
    var change: Double { price / start.close - 1 }
    var years: Double { Date.now.timeIntervalSince(start.date) / (365.25 * 86_400) }
    var annualized: Double? { years >= 1 ? pow(1 + change, 1 / years) - 1 : nil }

    /// Total return with dividends reinvested, from Yahoo's adjusted closes.
    var withDividends: Double? {
        guard let last = points.last, start.adjusted > 0, last.close > 0 else { return nil }
        let total = last.adjusted / start.adjusted * (price / last.close) - 1
        return abs(total - change) > 0.0005 ? total : nil
    }

    var drawdown: Double {
        var peak = start.close, worst = 0.0
        for point in points {
            peak = max(peak, point.close)
            worst = min(worst, point.close / peak - 1)
        }
        return worst
    }

    var series: [HistoryPoint] {
        let step = max(points.count / 240, 1)
        var sampled = stride(from: 0, to: points.count, by: step).map { points[$0] }
        if let last = points.last, sampled.last != last { sampled.append(last) }
        return sampled
    }
}

struct SimulatorSection: View {
    let symbol: String
    let price: Double?
    var currency = "USD"
    @State private var amountText = UserDefaults.standard.string(forKey: "simulatorAmount") ?? "1000"
    @State private var date = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
    @State private var history: [HistoryPoint] = []
    @State private var loadedFrom: Date?
    @State private var loading = false
    @State private var error: String?
    @State private var paper = PaperPortfolio.shared
    @State private var watchlist = Watchlist.shared
    @State private var tracked = 0
    @FocusState private var editing: Bool

    private let presets: [(label: String, component: Calendar.Component, value: Int)] = [
        ("1M", .month, -1), ("6M", .month, -6), ("1Y", .year, -1), ("5Y", .year, -5), ("10Y", .year, -10),
    ]

    private var amount: Double { Double(amountText.filter { $0.isNumber || $0 == "." }) ?? 0 }
    private var today: Bool { Calendar.current.isDateInToday(date) }
    private var backtest: Backtest? { today ? nil : Backtest(history: history, from: date, amount: amount, price: price) }

    var body: some View {
        QuoteSection("What if") {
            inputs
            if let backtest {
                result(backtest)
            } else if today {
                if let price, amount > 0 {
                    trackButton("Start Paper Trade at \(QuoteFormat.price(price))") {
                        PaperTrade(symbol: symbol, date: .now, price: price, amount: amount)
                    }
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else if let error {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
            }
            if let entry = watchlist.entries[symbol], watchlist.contains(symbol), let price {
                watchingRow(entry, price: price)
            }
            let trades = paper.trades(for: symbol)
            if !trades.isEmpty { paperRows(trades) }
        }
        .animation(.easeOut(duration: 0.2), value: history.count)
        .sensoryFeedback(.success, trigger: tracked)
        .onChange(of: amountText) { _, text in UserDefaults.standard.set(text, forKey: "simulatorAmount") }
        .task(id: Calendar.current.startOfDay(for: date)) {
            if let loadedFrom, date >= loadedFrom { return }
            guard !today else { return }
            let from = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: date)) ?? date
            loading = true
            defer { loading = false }
            do {
                history = try await MarketClient.history(symbol, from: from)
                loadedFrom = from
                error = history.isEmpty ? "No price history for this date." : nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Invest").foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    Text(Money.symbol(currency))
                    TextField("1000", text: $amountText)
                        .keyboardType(.decimalPad)
                        .focused($editing)
                        .fixedSize()
                }
                .font(.body.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(.fill.tertiary, in: .capsule)
                Text("on").foregroundStyle(.secondary)
                DatePicker("Start date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    .labelsHidden()
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                ForEach(presets, id: \.label) { preset in
                    Button(preset.label) {
                        editing = false
                        date = Calendar.current.date(byAdding: preset.component, value: preset.value, to: .now) ?? date
                    }
                    .font(.caption.weight(.bold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(Color.wireAccent)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }
            }
        }
    }

    @ViewBuilder
    private func result(_ test: Backtest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Money.whole(test.amount, code: currency)) → \(Money.text(test.value, code: currency))")
                .font(.title2.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
            Text("\(Money.signed(test.gain, code: currency)) (\(Money.percent(test.change)))")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Money.tint(test.gain))
        }
        .accessibilityElement(children: .combine)
        BacktestChart(test: test, currency: currency).frame(height: 120)
        StatGrid(stats: [
            ("Bought at", QuoteFormat.price(test.start.close)),
            ("Buy date", test.start.date.formatted(date: .abbreviated, time: .omitted)),
            ("Shares", test.shares.formatted(.number.precision(.fractionLength(0...4)))),
            test.annualized.map { ("Annualized", Money.percent($0)) },
            test.withDividends.map { ("With dividends", Money.percent($0)) },
            ("Max drawdown", test.drawdown.formatted(.percent.precision(.fractionLength(1)))),
        ].compactMap { $0 })
        trackButton("Track as Paper Trade") {
            PaperTrade(symbol: symbol, date: test.start.date, price: test.start.close, amount: test.amount)
        }
    }

    private func trackButton(_ title: String, trade: @escaping () -> PaperTrade) -> some View {
        Button {
            editing = false
            withAnimation(.easeOut(duration: 0.2)) { paper.add(trade()) }
            tracked += 1
        } label: {
            Label(title, systemImage: "plus.circle").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Color.wireAccent)
    }

    private func watchingRow(_ entry: WatchEntry, price: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Watching since \(entry.added.formatted(date: .abbreviated, time: .omitted))").font(.subheadline.weight(.semibold))
                Text("Added at \(QuoteFormat.price(entry.price))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let change = entry.change(to: price) {
                Text(Money.percent(change)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Money.tint(change))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func paperRows(_ trades: [PaperTrade]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paper trades").font(.caption).foregroundStyle(.secondary)
            ForEach(trades) { trade in
                PaperTradeRow(trade: trade, price: price)
                    .contextMenu {
                        Button("Remove Paper Trade", systemImage: "trash", role: .destructive) {
                            withAnimation(.easeOut(duration: 0.2)) { paper.remove(trade) }
                        }
                    }
            }
        }
    }
}

struct PaperTradeRow: View {
    let trade: PaperTrade
    let price: Double?
    var showsSymbol = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showsSymbol ? OptionSymbol.display(trade.symbol) : Money.whole(trade.amount))
                    .font(showsSymbol ? .body.weight(.semibold).monospaced() : .subheadline.weight(.semibold))
                Text("\(showsSymbol ? Money.whole(trade.amount) + " · " : "")\(trade.date.formatted(date: .abbreviated, time: .omitted)) at \(QuoteFormat.price(trade.price))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let price {
                let value = trade.value(at: price)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Money.text(value)).font(.subheadline.weight(.semibold))
                    Text("\(Money.signed(value - trade.amount)) (\(Money.percent(price / trade.price - 1)))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Money.tint(value - trade.amount))
                }
                .monospacedDigit()
                .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BacktestChart: View {
    let test: Backtest
    var currency = "USD"

    var body: some View {
        let shares = test.shares
        let up = test.gain >= 0
        let values = test.series.map { $0.close * shares }
        let low = min(values.min() ?? 0, test.amount), high = max(values.max() ?? 1, test.amount)
        let pad = max((high - low) * 0.08, 1)
        Chart {
            ForEach(test.series, id: \.date) { point in
                AreaMark(x: .value("Date", point.date), yStart: .value("Floor", low - pad), yEnd: .value("Value", point.close * shares))
                    .foregroundStyle(LinearGradient(colors: [(up ? Color.green : .red).opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", point.date), y: .value("Value", point.close * shares))
                    .foregroundStyle(up ? Color.green : .red)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            RuleMark(y: .value("Invested", test.amount))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { if let amount = value.as(Double.self) { Text(Money.compact(amount, code: currency)) } }
            }
        }
        .accessibilityLabel("Value of \(Money.whole(test.amount, code: currency)) invested since \(test.start.date.formatted(date: .abbreviated, time: .omitted)), now \(Money.text(test.value, code: currency))")
    }
}

struct PaperTradesSection: View {
    @State private var paper = PaperPortfolio.shared
    @State private var board = MarketBoard.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        let trades = paper.trades.sorted { $0.date > $1.date }
        let priced = trades.compactMap { trade in board.quotes[trade.symbol].map { (trade, $0.price) } }
        let invested = priced.reduce(0) { $0 + $1.0.amount }
        let value = priced.reduce(0) { $0 + $1.0.value(at: $1.1) }
        if !trades.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Money.text(value)).font(.title2.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
                    if invested > 0 {
                        Text("\(Money.signed(value - invested)) (\(Money.percent(value / invested - 1))) on \(Money.whole(invested))")
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(Money.tint(value - invested))
                    }
                }
                .accessibilityElement(children: .combine)
                .task(id: phase == .active ? Set(trades.map(\.symbol)) : []) {
                    guard phase == .active else { return }
                    let symbols = Array(Set(trades.map(\.symbol)))
                    while !Task.isCancelled {
                        await board.refresh(quotes: symbols, sparks: [])
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    }
                }
                ForEach(trades) { trade in
                    NavigationLink(value: MarketSymbol(id: trade.symbol)) {
                        PaperTradeRow(trade: trade, price: board.quotes[trade.symbol]?.price, showsSymbol: true)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { paper.remove(trade) }
                    }
                }
            } header: {
                Text("Paper Trades")
            } footer: {
                Text("Hypothetical positions from the What if simulator on any quote. Price return only.")
            }
        }
    }
}
