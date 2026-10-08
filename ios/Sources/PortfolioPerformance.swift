import Charts
import SwiftUI

nonisolated struct PerformancePoint: Identifiable, Hashable, Sendable {
    let id: Int
    let date: Date
    let value: Double
    var gain: Double?
    var rate: Double?
}

nonisolated struct PerformanceSeries: Sendable {
    let points: [PerformancePoint]
    let baseline: Double
    var transactionBased = false
    var last: Double { points.last?.value ?? baseline }
    var change: Double { points.last?.gain ?? (last - baseline) }
    var percent: Double? { transactionBased ? points.last?.rate : (baseline > 0 ? change / baseline : nil) }
    func change(at point: PerformancePoint) -> Double { point.gain ?? (point.value - baseline) }
    func percent(at point: PerformancePoint) -> Double? { transactionBased ? point.rate : (baseline > 0 ? change(at: point) / baseline : nil) }
}

@Observable final class PortfolioPerformance {
    static let shared = PortfolioPerformance()
    static let ranges: [ChartRange] = [.day, .week, .month, .sixMonths, .ytd, .year]

    var range = ChartRange(rawValue: UserDefaults.standard.string(forKey: "portfolioRange") ?? "") ?? .day {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "portfolioRange") }
    }
    private(set) var series: [ChartRange: PerformanceSeries] = [:]
    private var fetchedAt: [ChartRange: Date] = [:]
    private var signature: Data?
    private(set) var errors: [ChartRange: String] = [:]
    private let publishesWidgets: Bool

    init(publishesWidgets: Bool = true) { self.publishesWidgets = publishesWidgets }

    #if DEBUG
    func previewFailure(_ range: ChartRange, message: String) {
        series[range] = nil
        errors[range] = message
    }

    func preview(_ range: ChartRange, series: PerformanceSeries) {
        self.series[range] = series
    }
    #endif

    func refresh(_ snapshot: PortfolioSnapshot) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = try? encoder.encode(snapshot)
        var changed = key != signature
        if changed {
            signature = key
            series = [:]
            errors = [:]
            fetchedAt = [:]
        }
        for wanted in Set([ChartRange.day, range]) {
            if let stamp = fetchedAt[wanted], Date.now.timeIntervalSince(stamp) < 300 { continue }
            do {
                let built = try await Self.build(snapshot: snapshot, range: wanted)
                guard key == signature else { return }
                series[wanted] = built
                errors[wanted] = nil
            } catch {
                guard key == signature else { return }
                series[wanted] = nil
                errors[wanted] = error.localizedDescription
            }
            fetchedAt[wanted] = .now
            if wanted == .day { changed = true }
        }
        if changed && publishesWidgets { WidgetFeed.publish(snapshot, day: series[.day]) }
    }

    @concurrent private static func build(snapshot: PortfolioSnapshot, range: ChartRange) async throws -> PerformanceSeries {
        let ledger = try PortfolioLedger(snapshot: snapshot, start: PortfolioLedger.start(for: range, at: .now))
        let prices = try await withThrowingTaskGroup(of: (String, [HistoryPoint]).self) { group in
            for symbol in ledger.symbols {
                group.addTask { (symbol, try await MarketClient.portfolioHistory(symbol, from: ledger.start.addingTimeInterval(-7 * 86400))) }
            }
            var found: [String: [HistoryPoint]] = [:]
            for try await (symbol, points) in group { found[symbol] = points }
            return found
        }
        return try ledger.build(prices: prices)
    }
}

struct PortfolioCard: View {
    var compact = false
    let expanded: Bool
    let setExpanded: (Bool) -> Void
    let open: () -> Void
    @State private var store = PortfolioStore.shared
    @State private var performance = PortfolioPerformance.shared
    @State private var selected: PerformancePoint?
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var connected: Bool { !store.snapshot.positions.isEmpty || !(store.snapshot.accountBalances ?? []).isEmpty }
    private var shown: ChartRange { expanded ? performance.range : .day }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                HomeSectionHeader("Portfolio", action: connected ? "Details" : nil, perform: open)
                    .transition(.cardSwap)
            }
            ZStack(alignment: .topLeading) {
                if compact { compactBody.transition(.cardSwap) } else { fullBody.transition(.cardSwap) }
            }
            .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .topLeading)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .homeCard()
        }
        .task(id: phase == .active) {
            guard phase == .active else { return }
            if store.credentials.isComplete, !store.activeItems.isEmpty,
               ((store.snapshot.updated ?? .distantPast).timeIntervalSinceNow < -1800 || store.snapshot.histories?.contains(where: { $0.version != 1 }) != false) {
                await store.sync()
            }
            while !Task.isCancelled {
                await performance.refresh(store.snapshot)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onChange(of: performance.range) { selected = nil }
        .onChange(of: store.snapshot.updated) { selected = nil }
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
                            Text(today.percent.map(Money.percent) ?? "—").foregroundStyle(Money.tint(today.change))
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
                changeLine(current.change(at: selected), percent: current.percent(at: selected), label: shown == .day ? "Today" : shown.caption)
            } else {
                if let today { changeLine(today.change, percent: today.percent, label: "Today") }
                if shown != .day, let current {
                    changeLine(current.change, percent: current.percent, label: shown.caption)
                }
                if today == nil { Text(performance.errors[shown] ?? "Loading performance…").font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func changeLine(_ change: Double, percent: Double?, label: String) -> some View {
        HStack(spacing: 6) {
            Text(Money.signed(change) + (percent.map { " (" + Money.percent($0) + ")" } ?? ""))
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
            if let error = performance.errors[shown] {
                Text(compact ? "Performance unavailable" : error)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: compact ? 54 : 86)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.08)).frame(height: compact ? 54 : 86)
                    .redacted(reason: .placeholder)
            }
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
    /// The outgoing contents leave at once so two layouts never overlap; the new contents fade in.
    static var cardSwap: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22)), removal: .identity)
    }
}
