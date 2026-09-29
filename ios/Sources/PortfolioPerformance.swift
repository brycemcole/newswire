import Charts
import SwiftUI

nonisolated struct PerformancePoint: Identifiable, Hashable, Sendable {
    let id: Int
    let date: Date
    let value: Double
}

nonisolated struct PerformanceSeries: Sendable {
    let points: [PerformancePoint]
    let baseline: Double
    var last: Double { points.last?.value ?? baseline }
    var change: Double { last - baseline }
    var percent: Double { baseline == 0 ? 0 : change / baseline }
}

@Observable final class PortfolioPerformance {
    static let shared = PortfolioPerformance()
    static let ranges: [ChartRange] = [.day, .week, .month, .sixMonths, .ytd, .year]

    var range = ChartRange(rawValue: UserDefaults.standard.string(forKey: "portfolioRange") ?? "") ?? .day {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "portfolioRange") }
    }
    private(set) var series: [ChartRange: PerformanceSeries] = [:]
    private var fetchedAt: [ChartRange: Date] = [:]
    private var signature = ""

    func refresh(_ snapshot: PortfolioSnapshot) async {
        let holdings = Dictionary(grouping: snapshot.positions.filter { $0.option == nil }, by: \.symbol)
            .mapValues { $0.reduce(0) { $0 + $1.quantity } }
        let fixed = snapshot.cash + snapshot.positions.filter { $0.option != nil }.compactMap(\.value).reduce(0, +)
        let key = holdings.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",") + "|\(fixed)"
        if key != signature {
            signature = key
            series = [:]
            fetchedAt = [:]
        }
        for wanted in Set([ChartRange.day, range]) {
            let limit: TimeInterval = wanted.intraday ? 60 : 900
            if let stamp = fetchedAt[wanted], Date.now.timeIntervalSince(stamp) < limit { continue }
            guard let built = await Self.build(holdings: holdings, snapshot: snapshot, fixed: fixed, range: wanted), key == signature else { continue }
            series[wanted] = built
            fetchedAt[wanted] = .now
        }
    }

    @concurrent private static func build(holdings: [String: Double], snapshot: PortfolioSnapshot, fixed: Double, range: ChartRange) async -> PerformanceSeries? {
        let charts = await withTaskGroup(of: (String, MarketChart?).self) { group in
            for symbol in holdings.keys { group.addTask { (symbol, try? await MarketClient.chart(symbol, range: range)) } }
            var found: [String: MarketChart] = [:]
            for await (symbol, chart) in group { if let chart, !chart.points.isEmpty { found[symbol] = chart } }
            return found
        }
        var constant = fixed
        for symbol in holdings.keys where charts[symbol] == nil {
            constant += snapshot.positions(for: symbol).filter { $0.option == nil }.compactMap(\.value).reduce(0, +)
        }
        guard let axis = charts.values.max(by: { $0.points.count < $1.points.count })?.points else {
            return constant == 0 ? nil : PerformanceSeries(points: [], baseline: constant)
        }
        let tracks = charts.map { (quantity: holdings[$0.key] ?? 0, points: $0.value.points) }
        var cursors = Array(repeating: 0, count: tracks.count)
        var points: [PerformancePoint] = []
        points.reserveCapacity(axis.count)
        for (index, tick) in axis.enumerated() {
            var total = constant
            for (slot, track) in tracks.enumerated() {
                while cursors[slot] + 1 < track.points.count && track.points[cursors[slot] + 1].date <= tick.date { cursors[slot] += 1 }
                total += track.quantity * track.points[cursors[slot]].close
            }
            points.append(PerformancePoint(id: index, date: tick.date, value: total))
        }
        let baseline: Double
        if range == .day {
            baseline = constant + charts.reduce(0) { sum, entry in
                sum + (holdings[entry.key] ?? 0) * (entry.value.previousClose ?? entry.value.points.first?.close ?? 0)
            }
        } else {
            baseline = points.first?.value ?? constant
        }
        return PerformanceSeries(points: points, baseline: baseline)
    }
}

struct PortfolioCard: View {
    var compact = false
    let expanded: Bool
    var contentHidden = false
    let setExpanded: (Bool) -> Void
    let open: () -> Void
    @State private var store = PortfolioStore.shared
    @State private var performance = PortfolioPerformance.shared
    @State private var selected: PerformancePoint?
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var connected: Bool { !store.snapshot.positions.isEmpty || store.snapshot.cash != 0 }
    private var shown: ChartRange { expanded ? performance.range : .day }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                HomeSectionHeader("Portfolio", action: connected ? "Details" : nil, perform: open)
                    .opacity(contentHidden ? 0 : 1)
                    .transition(.cardSwap)
            }
            ZStack(alignment: .topLeading) {
                if compact { compactBody.transition(.cardSwap) } else { fullBody.transition(.cardSwap) }
            }
            .opacity(contentHidden ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .topLeading)
            .homeCard()
        }
        .task(id: phase == .active) {
            guard phase == .active else { return }
            if store.credentials.isComplete, !store.activeItems.isEmpty,
               (store.snapshot.updated ?? .distantPast).timeIntervalSinceNow < -1800 {
                await store.sync()
            }
            while !Task.isCancelled {
                await performance.refresh(store.snapshot)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .task(id: performance.range) { await performance.refresh(store.snapshot) }
        .task(id: store.snapshot.updated) { await performance.refresh(store.snapshot) }
    }

    private var compactBody: some View {
        let today = performance.series[.day]
        return Button {
            if connected {
                setExpanded(true)
            } else { open() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Portfolio").font(.headline)
                if connected {
                    Text(Money.text(today?.last ?? store.snapshot.totalValue))
                        .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    if let today {
                        HStack(spacing: 4) {
                            Text(Money.percent(today.percent)).foregroundStyle(Money.tint(today.change))
                            Text("Today").foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    Spacer(minLength: 0)
                    chart
                } else {
                    Text(store.credentials.isComplete ? "Connect a brokerage to see performance." : "Add Plaid keys to see performance.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(connected ? "Shows performance ranges" : "Opens portfolio")
    }

    private var fullBody: some View {
            Group {
                if connected {
                    VStack(alignment: .leading, spacing: 12) {
                        summary
                        chart
                        if expanded {
                            rangePicker.transition(.opacity)
                        }
                    }
                    .padding(16)
                    .contentShape(.rect)
                    .onTapGesture {
                        setExpanded(!expanded)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(expanded ? "Hides time ranges" : "Shows time ranges")
                } else {
                    Button(action: open) {
                        Text(store.credentials.isComplete ? "Connect a brokerage to see performance." : "Add your Plaid keys to see performance.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .padding(.horizontal, 16)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
    }

    private var summary: some View {
        let today = performance.series[.day]
        let current = performance.series[shown]
        let value = selected?.value ?? today?.last ?? store.snapshot.totalValue
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(Money.text(value))
                    .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.15), value: value)
                Spacer()
                if let selected {
                    Text(selected.date.formatted(shown.intraday ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.month(.abbreviated).day().year()))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if let selected, let current {
                changeLine(selected.value - current.baseline, base: current.baseline, label: shown == .day ? "Today" : shown.caption)
            } else {
                if let today { changeLine(today.change, base: today.baseline, label: "Today") }
                if shown != .day, let current {
                    changeLine(current.change, base: current.baseline, label: shown.caption)
                }
                if today == nil { Text("Loading performance…").font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func changeLine(_ change: Double, base: Double, label: String) -> some View {
        HStack(spacing: 6) {
            Text(Money.signed(change) + " (" + Money.percent(base == 0 ? 0 : change / base) + ")")
                .foregroundStyle(Money.tint(change))
            Text(label).foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .contentTransition(.numericText())
    }

    @ViewBuilder
    private var chart: some View {
        if let current = performance.series[shown], current.points.count > 1 {
            let tint = Money.tint(current.change)
            let values = current.points.map(\.value) + [current.baseline]
            let low = values.min() ?? 0, high = values.max() ?? 1
            let pad = max((high - low) * 0.08, 0.01)
            Chart {
                ForEach(current.points) { point in
                    AreaMark(x: .value("Time", point.id), yStart: .value("Low", low - pad), yEnd: .value("Value", point.value))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.id), y: .value("Value", point.value))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
                RuleMark(y: .value("Baseline", current.baseline))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [2, 3]))
                if let selected {
                    RuleMark(x: .value("Selected", selected.id)).foregroundStyle(.secondary.opacity(0.6))
                    PointMark(x: .value("Selected", selected.id), y: .value("Value", selected.value)).foregroundStyle(tint).symbolSize(40)
                } else if let last = current.points.last {
                    PointMark(x: .value("Time", last.id), y: .value("Value", last.value)).foregroundStyle(tint).symbolSize(28)
                }
            }
            .chartXScale(domain: 0...max(current.points.count - 1, 1))
            .chartYScale(domain: (low - pad)...(high + pad))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: compact ? 54 : 86)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(.rect).allowsHitTesting(!compact)
                        .gesture(
                            LongPressGesture(minimumDuration: 0.15)
                                .sequenced(before: DragGesture(minimumDistance: 0))
                                .onChanged { value in
                                    guard case .second(true, let drag?) = value, let frame = proxy.plotFrame else { return }
                                    let x = drag.location.x - geometry[frame].origin.x
                                    guard let index: Int = proxy.value(atX: x) else { return }
                                    let point = current.points[min(max(index, 0), current.points.count - 1)]
                                    if point != selected { selected = point }
                                }
                                .onEnded { _ in selected = nil }
                        )
                }
            }
            .sensoryFeedback(.selection, trigger: selected?.id) { _, new in new != nil }
            .accessibilityLabel("Portfolio value chart, \(shown.caption)")
        } else {
            RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.08)).frame(height: compact ? 54 : 86)
                .redacted(reason: .placeholder)
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $performance.range) {
            ForEach(PortfolioPerformance.ranges) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .sensoryFeedback(.selection, trigger: performance.range)
    }
}

struct HomeSectionHeader: View {
    let title: String
    let action: String?
    let perform: () -> Void

    init(_ title: String, action: String? = nil, perform: @escaping () -> Void = {}) {
        self.title = title
        self.action = action
        self.perform = perform
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            if let action {
                Button(action, action: perform)
                    .font(.subheadline)
                    .foregroundStyle(Color.wireAccent)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    @ViewBuilder
    func homeCard(id: String? = nil, in namespace: Namespace.ID? = nil) -> some View {
        if let id, let namespace {
            glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
                .glassEffectID(id, in: namespace)
        } else {
            glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        }
    }
}

extension AnyTransition {
    static var cardSwap: AnyTransition {
        .opacity
    }
}

extension Animation {
    static func dashboard(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.45, bounce: 0.12)
    }
}
