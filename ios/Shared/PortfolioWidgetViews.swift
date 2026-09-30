import Charts
import SwiftUI
import WidgetKit

struct PortfolioWidgetView: View {
    let portfolio: WidgetPortfolio?
    let family: WidgetFamily

    var body: some View {
        if let portfolio {
            switch family {
            case .accessoryInline: InlinePortfolio(portfolio: portfolio)
            case .accessoryCircular: CircularPortfolio(portfolio: portfolio)
            case .accessoryRectangular: RectangularPortfolio(portfolio: portfolio)
            case .systemMedium: MediumPortfolio(portfolio: portfolio)
            case .systemLarge: LargePortfolio(portfolio: portfolio)
            case .systemExtraLarge: ExtraLargePortfolio(portfolio: portfolio)
            default: SmallPortfolio(portfolio: portfolio)
            }
        } else {
            EmptyPortfolio(family: family)
        }
    }
}

private extension WidgetPortfolio {
    var direction: Double { dayChange ?? 0 }
    var tint: Color { Money.tint(direction) }
    var arrow: String { direction >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill" }
    var dayPercentText: String { dayPercent.map(Money.percent2) ?? "—" }
    var stamp: Date { fetched ?? updated }
}

private struct DayChangeBadge: View {
    let portfolio: WidgetPortfolio
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: portfolio.arrow).font(.system(size: 8, weight: .bold)).baselineOffset(1)
            Text(portfolio.dayPercentText)
        }
        .font(font.monospacedDigit())
        .foregroundStyle(portfolio.tint)
    }
}

private struct UpdatedLabel: View {
    let date: Date

    var body: some View {
        Text(Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month(.abbreviated).day()))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
    }
}

struct ValueChart: View {
    let points: [WidgetPoint]
    let baseline: Double?
    var tint: Color
    var baselineRule = false
    var marksLast = false
    var axes = false
    var lineWidth: CGFloat = 1.6

    var body: some View {
        let values = points.map(\.value) + (baselineRule ? [baseline].compactMap { $0 } : [])
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.1, 0.01)
        if points.count > 1 {
            Chart {
                ForEach(points, id: \.date) { point in
                    AreaMark(x: .value("Time", point.date), yStart: .value("Low", low - pad), yEnd: .value("Value", point.value))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.26), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.date), y: .value("Value", point.value))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
                if baselineRule, let baseline {
                    RuleMark(y: .value("Previous close", baseline))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [2, 3]))
                }
                if marksLast, let last = points.last {
                    PointMark(x: .value("Time", last.date), y: .value("Value", last.value)).foregroundStyle(tint).symbolSize(22)
                }
            }
            .chartXScale(domain: (points.first?.date ?? .now)...(points.last?.date ?? .now))
            .chartYScale(domain: (low - pad)...(high + pad))
            .chartXAxis {
                if axes {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        AxisValueLabel(format: .dateTime.hour(), collisionResolution: .greedy).font(.caption2)
                    }
                }
            }
            .chartYAxis {
                if axes {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        AxisValueLabel { if let amount = value.as(Double.self) { Text(Money.compact(amount)).font(.caption2) } }
                    }
                }
            }
            .chartLegend(.hidden)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.1))
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    let baseline: Double?
    let tint: Color

    var body: some View {
        let all = values + [baseline].compactMap { $0 }
        let low = all.min() ?? 0, high = all.max() ?? 1
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("Time", index), y: .value("Value", value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            if let baseline {
                RuleMark(y: .value("Previous close", baseline))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [1.5, 2]))
            }
        }
        .chartXScale(domain: 0...max(values.count - 1, 1))
        .chartYScale(domain: low...(high > low ? high : low + 0.01))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

private struct HoldingRow: View {
    let holding: WidgetHolding
    let total: Double
    var showsName = false

    var body: some View {
        let change = holding.dayPercent ?? 0
        Link(destination: URL(string: "newswire://quote/\(holding.symbol)")!) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(holding.symbol).font(.subheadline.weight(.semibold))
                    Text(showsName ? (holding.name ?? weight) : weight)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: showsName ? .infinity : 74, alignment: .leading)
                if holding.spark.count > 1 {
                    Sparkline(values: holding.spark, baseline: holding.previousClose, tint: Money.tint(change))
                        .frame(width: 54, height: 20)
                }
                if !showsName { Spacer(minLength: 0) }
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Money.whole(holding.value)).font(.subheadline.monospacedDigit())
                    Text(holding.dayPercent.map(Money.percent2) ?? "—")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(holding.dayPercent == nil ? Color.secondary : Money.tint(change))
                }
                .frame(minWidth: 72, alignment: .trailing)
            }
        }
        .tint(.primary)
    }

    private var weight: String {
        total == 0 ? "" : (holding.value / total).formatted(.percent.precision(.fractionLength(0))) + " of total"
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Lock Screen

private struct InlinePortfolio: View {
    let portfolio: WidgetPortfolio

    var body: some View {
        Label {
            Text("\(Money.compact(portfolio.value))  \(portfolio.dayPercentText)")
        } icon: {
            Image(systemName: portfolio.direction >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
        }
    }
}

private struct CircularPortfolio: View {
    let portfolio: WidgetPortfolio

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: portfolio.arrow).font(.system(size: 9, weight: .bold))
                Text(portfolio.dayPercent.map { abs($0).formatted(.percent.precision(.fractionLength(1))) } ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .widgetAccentable()
                Text(Money.compact(portfolio.value))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Portfolio \(Money.text(portfolio.value)), \(portfolio.dayPercentText) today")
    }
}

private struct RectangularPortfolio: View {
    let portfolio: WidgetPortfolio

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("Portfolio").font(.caption2.weight(.semibold))
                Spacer(minLength: 0)
                DayChangeBadge(portfolio: portfolio, font: .caption2.weight(.bold))
            }
            Text(Money.whole(portfolio.value))
                .font(.system(.headline, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
                .widgetAccentable()
            ValueChart(points: portfolio.day, baseline: portfolio.dayBaseline, tint: .primary, baselineRule: true, lineWidth: 1.4)
                .frame(minHeight: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Portfolio \(Money.text(portfolio.value)), \(portfolio.dayPercentText) today")
    }
}

// MARK: Home Screen

private struct SmallPortfolio: View {
    let portfolio: WidgetPortfolio

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Portfolio").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "briefcase.fill").font(.caption2).foregroundStyle(.tertiary)
            }
            Text(Money.whole(portfolio.value))
                .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.5)
                .widgetAccentable()
            DayChangeBadge(portfolio: portfolio)
            Spacer(minLength: 6)
            ValueChart(points: portfolio.day, baseline: portfolio.dayBaseline, tint: portfolio.tint)
        }
    }
}

private struct MediumPortfolio: View {
    let portfolio: WidgetPortfolio

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Portfolio").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(Money.text(portfolio.value))
                    .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .widgetAccentable()
                DayChangeBadge(portfolio: portfolio)
                if let change = portfolio.dayChange {
                    Text("\(Money.signed(change)) today")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let gain = portfolio.totalGain {
                    HStack(spacing: 4) {
                        Text("Total").foregroundStyle(.secondary)
                        Text(Money.signed(gain)).foregroundStyle(Money.tint(gain))
                    }
                    .font(.caption2.weight(.medium).monospacedDigit())
                }
                UpdatedLabel(date: portfolio.stamp)
            }
            .frame(width: 138, alignment: .leading)
            ValueChart(points: portfolio.day, baseline: portfolio.dayBaseline, tint: portfolio.tint, baselineRule: true, marksLast: true)
        }
    }
}

private struct LargePortfolio: View {
    let portfolio: WidgetPortfolio

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Portfolio").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(Money.text(portfolio.value))
                        .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .widgetAccentable()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    DayChangeBadge(portfolio: portfolio)
                    if let change = portfolio.dayChange {
                        Text(Money.signed(change)).font(.caption.monospacedDigit()).foregroundStyle(portfolio.tint)
                    }
                    UpdatedLabel(date: portfolio.stamp)
                }
            }
            ValueChart(points: portfolio.day, baseline: portfolio.dayBaseline, tint: portfolio.tint, baselineRule: true, marksLast: true)
                .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Stat(title: "Day range", value: range)
                if let percent = portfolio.monthPercent {
                    Stat(title: "1 month", value: Money.percent(percent), tint: Money.tint(percent))
                }
                if let gain = portfolio.totalGain {
                    Stat(title: "Total gain", value: Money.signedCompact(gain), tint: Money.tint(gain))
                }
                Stat(title: "Cash", value: Money.compact(portfolio.cash))
            }
            Divider()
            VStack(spacing: 6) {
                ForEach(portfolio.byValue.prefix(4)) { HoldingRow(holding: $0, total: portfolio.value) }
            }
        }
    }

    private var range: String {
        guard let low = portfolio.dayLow, let high = portfolio.dayHigh else { return "—" }
        return "\(Money.compact(low))–\(Money.compact(high))"
    }
}

private struct ExtraLargePortfolio: View {
    let portfolio: WidgetPortfolio

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Money.text(portfolio.value))
                        .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .widgetAccentable()
                    DayChangeBadge(portfolio: portfolio, font: .title3.weight(.semibold))
                    Spacer()
                    UpdatedLabel(date: portfolio.stamp)
                }
                HStack(spacing: 12) {
                    if let change = portfolio.dayChange {
                        Stat(title: "Today", value: Money.signed(change), tint: Money.tint(change))
                    }
                    if let change = portfolio.monthChange, let percent = portfolio.monthPercent {
                        Stat(title: "1 month", value: "\(Money.signed(change)) (\(Money.percent(percent)))", tint: Money.tint(change))
                    }
                    if let gain = portfolio.totalGain {
                        Stat(title: "Total gain", value: Money.signed(gain), tint: Money.tint(gain))
                    }
                }
                ValueChart(points: portfolio.day, baseline: portfolio.dayBaseline, tint: portfolio.tint, baselineRule: true, marksLast: true, axes: true)
                    .frame(maxHeight: .infinity)
                movers
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Holdings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(portfolio.byValue.prefix(5)) { HoldingRow(holding: $0, total: portfolio.value, showsName: true) }
                Spacer(minLength: 0)
                AllocationBar(portfolio: portfolio)
            }
            .frame(width: 300)
        }
    }

    @ViewBuilder
    private var movers: some View {
        let ranked = portfolio.holdings.filter { $0.dayPercent != nil }.sorted { $0.dayPercent! > $1.dayPercent! }
        if let best = ranked.first, let worst = ranked.last, ranked.count > 1 {
            HStack(spacing: 14) {
                mover("Leader", best)
                mover("Laggard", worst)
                Spacer(minLength: 0)
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func mover(_ title: String, _ holding: WidgetHolding) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(holding.symbol).fontWeight(.semibold)
            Text(Money.percent2(holding.dayPercent ?? 0)).foregroundStyle(Money.tint(holding.dayPercent ?? 0))
        }
    }
}

private struct AllocationBar: View {
    let portfolio: WidgetPortfolio
    private static let palette: [Color] = [.blue, .teal, .indigo, .orange, .pink]

    private var slices: [(label: String, value: Double, color: Color)] {
        let top = portfolio.byValue.prefix(Self.palette.count)
        var slices = top.enumerated().map { ($0.element.symbol, $0.element.value, Self.palette[$0.offset]) }
        let rest = portfolio.byValue.dropFirst(Self.palette.count).reduce(portfolio.other) { $0 + $1.value }
        if rest > 0 { slices.append(("Other", rest, .purple)) }
        if portfolio.cash > 0 { slices.append(("Cash", portfolio.cash, .gray)) }
        return slices.filter { $0.1 > 0 }
    }

    var body: some View {
        let slices = slices
        let total = slices.reduce(0) { $0 + $1.value }
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                HStack(spacing: 1.5) {
                    ForEach(slices, id: \.label) { slice in
                        Rectangle().fill(slice.color.gradient)
                            .frame(width: max(2, (geometry.size.width - 1.5 * Double(slices.count - 1)) * slice.value / max(total, 1)))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 7)
            HStack(spacing: 8) {
                ForEach(slices.prefix(5), id: \.label) { slice in
                    HStack(spacing: 3) {
                        Circle().fill(slice.color).frame(width: 5, height: 5)
                        Text("\(slice.label) \((slice.value / max(total, 1)).formatted(.percent.precision(.fractionLength(0))))")
                    }
                }
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

private struct EmptyPortfolio: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("Connect a brokerage", systemImage: "briefcase")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "briefcase").font(.title3)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Portfolio").font(.headline)
                Text("Open Newswire to connect a brokerage").font(.caption).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "briefcase.fill").font(.title2).foregroundStyle(.secondary)
                Spacer()
                Text("Portfolio").font(.headline)
                Text("Open Newswire and connect a brokerage to see performance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
