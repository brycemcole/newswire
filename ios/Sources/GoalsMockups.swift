#if DEBUG
import Charts
import SwiftUI

/// Design-exploration screens for Portfolio Goals and Ideas, rendered from fixtures. Launch with `-goalsMockup N`.
struct GoalsMockupGallery: View {
    var body: some View {
        let args = CommandLine.arguments
        let number = args.firstIndex(of: "-goalsMockup").flatMap { args.dropFirst($0 + 1).first }.flatMap(Int.init) ?? 1
        Group { screen(number) }
            .preferredColorScheme(args.contains("-goalsLight") ? .light : nil)
    }

    @ViewBuilder private func screen(_ number: Int) -> some View {
        switch number {
        case 1, 10: MPortfolio { MEntryLine() }
        case 2, 11: MPortfolio(page: AnyView(MGoalDetail()), entry: { MEntryLine() })
        case 3: MPortfolio(page: AnyView(MIdeaDetail()), entry: { MEntryLine() })
        case 4: MPortfolio(sheet: AnyView(MCreateGoal()), entry: { MEntryLine() })
        case 5: MPortfolio { MEmptyEntry() }
        case 6: MPortfolio(page: AnyView(MGoalsScreen()), entry: { MEntryLine() })
        case 7: MShell(tab: 0) { MToday() }
        case 8: MPortfolio(page: AnyView(MBalance()), entry: { MEntryLine() })
        case 9: MPortfolio(sheet: AnyView(MPriorityIdeaSheet()), detents: [.fraction(0.64)], entry: { MEntryLine() })
        default: MPortfolio { MEntryLine() }
        }
    }
}

// MARK: Fixtures

private enum MF {
    static let count = 30
    static let days: [Date] = (0..<count).map { Calendar.current.date(byAdding: .day, value: $0 - (count - 1), to: .now)! }

    static func curve(_ anchors: [Double], wiggle: Double, seed: Double) -> [Double] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1) * Double(anchors.count - 1)
            let a = min(Int(t), anchors.count - 1), f = t - Double(a)
            let b = min(a + 1, anchors.count - 1)
            if i == count - 1 { return anchors[anchors.count - 1] }
            return anchors[a] * (1 - f) + anchors[b] * f + sin(Double(i) * 1.3 + seed) * wiggle
        }
    }

    static let aapl = curve([4.7, 4.8, 5.0, 5.2, 5.5, 5.7, 5.9], wiggle: 0.05, seed: 0)
    static let nvda = curve([4.6, 4.7, 4.6, 4.9, 5.0, 5.2, 5.3], wiggle: 0.06, seed: 2)
    static let amd = curve([4.9, 5.0, 4.8, 4.9, 5.2, 5.0, 5.1], wiggle: 0.05, seed: 4)
    static let portfolio = curve([76.2, 77.0, 76.4, 78.1, 79.0, 78.4, 80.14], wiggle: 0.4, seed: 1)

    struct Holding { let symbol: String; let name: String; let shares: String; let value: String; let day: String; let up: Bool }
    static let holdings = [
        Holding(symbol: "VOO", name: "Vanguard S&P 500 ETF", shares: "38 shares", value: "$21,640", day: "+0.4%", up: true),
        Holding(symbol: "VTI", name: "Vanguard Total Stock Market", shares: "58 shares", value: "$17,310", day: "+0.3%", up: true),
        Holding(symbol: "AAPL", name: "Apple", shares: "20 shares", value: "$4,728", day: "-0.6%", up: false),
        Holding(symbol: "NVDA", name: "NVIDIA", shares: "24 shares", value: "$4,248", day: "+2.1%", up: true),
        Holding(symbol: "AMD", name: "Advanced Micro Devices", shares: "19 shares", value: "$4,087", day: "+0.9%", up: true),
        Holding(symbol: "MSFT", name: "Microsoft", shares: "8 shares", value: "$3,686", day: "-0.2%", up: false),
    ]

    struct Idea: Identifiable { let id: Int; let title: String; let detail: String; let symbol: String; let group: String }
    static let ideas = [
        Idea(id: 1, title: "I can show how to bring AAPL back under your 5% limit", detail: "It has been above 5% for two weeks and is now 5.9% of your portfolio. Trimming about $720 would fix it.", symbol: "AAPL", group: "Balance"),
        Idea(id: 2, title: "I noticed three stories on NVDA since yesterday", detail: "Two are about export rules and one about a new data center deal. NVDA is 5.3% of your portfolio.", symbol: "NVDA", group: "News"),
        Idea(id: 3, title: "AMD reports earnings on Tuesday", detail: "It is 5.1% of your portfolio, so a large move would shift your balance.", symbol: "AMD", group: "News"),
    ]
}

private let gutter: CGFloat = 20

// MARK: Chart

private struct MLine: Identifiable {
    let id: String
    let values: [Double]
    var color: Color = .primary
    var strong = true
}

private struct MChart: View {
    var lines: [MLine]
    var limit: Double?
    var height: CGFloat = 200
    var compact = false
    var endLabels = false
    var shade = false

    var body: some View {
        let all = lines.flatMap(\.values) + (limit.map { [$0] } ?? [])
        let low = (all.min() ?? 0) - (compact ? 0.15 : 0.3), high = (all.max() ?? 1) + (compact ? 0.15 : 0.45)
        Chart {
            if shade, let limit, let first = lines.first {
                ForEach(Array(first.values.enumerated()), id: \.offset) { index, value in
                    AreaMark(x: .value("Day", MF.days[index]), yStart: .value("Limit", limit), yEnd: .value("Share", max(value, limit)))
                        .foregroundStyle(.orange.opacity(0.3))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(lines) { line in
                ForEach(Array(line.values.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("Day", MF.days[index]), y: .value("Share", value), series: .value("Holding", line.id))
                        .foregroundStyle(line.color.opacity(line.strong ? 1 : 0.4))
                        .lineStyle(StrokeStyle(lineWidth: compact ? 1.75 : (line.strong ? 2.5 : 1.5), lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                if !compact, let last = line.values.last {
                    PointMark(x: .value("Day", MF.days[MF.count - 1]), y: .value("Share", last))
                        .symbolSize(line.strong ? 40 : 0)
                        .foregroundStyle(line.color)
                        .annotation(position: .trailing, spacing: 6, overflowResolution: .init(x: .disabled, y: .disabled)) {
                            if endLabels { Text(line.id).font(.caption2.weight(line.strong ? .semibold : .regular)).foregroundStyle(line.strong ? .primary : .secondary) }
                        }
                }
            }
            if let limit {
                RuleMark(y: .value("Limit", limit))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading, spacing: 3) {
                        if !compact { Text("\(limit.formatted(.number.precision(.fractionLength(0...1))))% limit").font(.caption2).foregroundStyle(.secondary) }
                    }
            }
        }
        .chartYScale(domain: low...high)
        .chartYAxis {
            if compact { AxisMarks { _ in } } else {
                AxisMarks(position: endLabels ? .leading : .trailing, values: .automatic(desiredCount: 3)) { mark in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel { if let value = mark.as(Double.self) { Text("\(value.formatted(.number.precision(.fractionLength(0...1))))%") } }
                }
            }
        }
        .chartXAxis {
            if compact { AxisMarks { _ in } } else {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
        }
        .chartPlotStyle { $0.padding(.trailing, endLabels ? 48 : 0) }
        .frame(height: height)
    }
}

private struct MSpark: View {
    let values: [Double]
    var limit: Double? = 5
    var body: some View {
        MChart(lines: [MLine(id: "x", values: values, color: .orange)], limit: limit, height: 34, compact: true)
    }
}

// MARK: Shell

private struct MShell<Content: View>: View {
    var tab = 1
    @ViewBuilder var content: () -> Content

    var body: some View {
        TabView(selection: .constant(tab)) {
            Tab("Today", systemImage: "newspaper", value: 0) { if tab == 0 { content() } else { Color.clear } }
            Tab("Portfolio", systemImage: "briefcase", value: 1) { if tab == 1 { content() } else { Color.clear } }
            Tab("Ask", systemImage: "message", value: 2) { Color.clear }
        }
    }
}

private struct MPortfolio<Entry: View>: View {
    var page: AnyView?
    var sheet: AnyView?
    var detents: Set<PresentationDetent> = [.large]
    @ViewBuilder var entry: () -> Entry
    @State private var pushed = true
    @State private var sheeted = true

    var body: some View {
        MShell {
            NavigationStack {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total value").font(.subheadline).foregroundStyle(.secondary)
                            Text("$80,140").font(.system(size: 40, weight: .bold)).monospacedDigit()
                            Text("+$412 today").font(.subheadline).foregroundStyle(.green)
                        }
                        .listRowSeparator(.hidden)
                        Chart {
                            ForEach(Array(MF.portfolio.enumerated()), id: \.offset) { index, value in
                                LineMark(x: .value("Day", MF.days[index]), y: .value("Value", value))
                                    .foregroundStyle(.green).interpolationMethod(.monotone)
                                AreaMark(x: .value("Day", MF.days[index]), yStart: .value("Base", 75), yEnd: .value("Value", value))
                                    .foregroundStyle(.linearGradient(colors: [.green.opacity(0.25), .green.opacity(0)], startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.monotone)
                            }
                        }
                        .chartYScale(domain: 75...81).chartXAxis(.hidden).chartYAxis(.hidden)
                        .frame(height: 120)
                        .listRowSeparator(.hidden)
                        Picker("Range", selection: .constant("1M")) {
                            ForEach(["1D", "1W", "1M", "3M", "1Y", "All"], id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section { entry() }
                    Section {
                        ForEach(MF.holdings, id: \.symbol) { holding in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(holding.symbol).font(.headline)
                                    Text(holding.shares).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(holding.value).font(.headline).monospacedDigit()
                                    Text(holding.day).font(.subheadline).foregroundStyle(holding.up ? .green : .red).monospacedDigit()
                                }
                            }
                        }
                    } header: { Text("Holdings") }
                }
                .navigationTitle("Portfolio")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Menu("All accounts") { Button("All accounts") {} } }
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
                .navigationDestination(isPresented: Binding(get: { pushed && page != nil }, set: { pushed = $0 })) { page }
            }
            .sheet(isPresented: Binding(get: { sheeted && sheet != nil }, set: { sheeted = $0 })) {
                sheet.presentationDetents(detents)
            }
        }
    }
}

// MARK: Portfolio entries

/// A single plain sentence from the AI under the overview, with a tiny day-by-day line of the item it is about.
private struct MEntryLine: View {
    var body: some View {
        NavigationLink {} label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple is over your 5% limit").font(.headline)
                    Text("NVIDIA and AMD are just over it too. I can show you how.")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                MSpark(values: MF.aapl).frame(width: 72)
            }
            .padding(.vertical, 2)
        }
        NavigationLink {} label: {
            HStack {
                Text("Goals and ideas")
                Spacer()
                Text("3 goals, 2 ideas").foregroundStyle(.secondary)
            }
        }
    }
}

private struct MEmptyEntry: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tell me what you want from this portfolio").font(.headline)
            Text("I'll watch your holdings and the news against it. For example, \"no single position above 5%\" or \"tell me when news hits what I own\".")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Write a goal") {}.buttonStyle(.glass).padding(.top, 2)
        }
        .padding(.vertical, 6)
    }
}

// MARK: Detail pages

private struct MHero: View {
    let caption: String
    let value: String
    let sentence: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 64, weight: .bold)).monospacedDigit()
            Text(sentence).font(.title3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MFootnote: View {
    var body: some View {
        Text("Last 30 days, estimated from today's holdings at each day's closing price. Prices as of 4:00 PM yesterday.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct MGoalDetail: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MHero(caption: "Apple's share of your portfolio", value: "5.9%", sentence: "Over your 5% limit for two weeks.")
                VStack(alignment: .leading, spacing: 10) {
                    MChart(lines: [
                        MLine(id: "AAPL", values: MF.aapl),
                        MLine(id: "NVDA", values: MF.nvda, color: .blue, strong: false),
                        MLine(id: "AMD", values: MF.amd, color: .indigo, strong: false),
                    ], limit: 5, height: 230, endLabels: true, shade: true)
                    MFootnote()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trim AAPL from 5.9% to 5%").font(.title3.weight(.semibold))
                    Text("That is about $720, or three shares. NVIDIA (5.3%) and AMD (5.1%) crossed the line more recently, and both are small enough that a few shares would settle it. I would start with Apple, since it has been over the longest.")
                        .foregroundStyle(.secondary)
                    Text("I don't trade for you. These are suggestions.").font(.footnote).foregroundStyle(.tertiary).padding(.top, 2)
                }
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button("Ask about this") {}.buttonStyle(.glassProminent)
                        Button("Snooze for a week") {}.buttonStyle(.glass)
                    }
                }
            }
            .padding(.horizontal, gutter)
            .padding(.bottom, 24)
        }
        .navigationTitle("No single position above 5%")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct MIdeaDetail: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("I noticed three stories on NVDA since yesterday")
                    .font(.title.weight(.bold))
                VStack(alignment: .leading, spacing: 4) {
                    Text("NVIDIA's share of your portfolio").font(.subheadline).foregroundStyle(.secondary)
                    Text("5.3%").font(.system(size: 44, weight: .bold)).monospacedDigit()
                    Text("Up from 4.6% a month ago.").font(.body).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    MChart(lines: [MLine(id: "NVDA", values: MF.nvda, color: .blue)], height: 140)
                    MFootnote()
                }
                Text("Two of them are about export rules for advanced chips, and one is about a new data center deal. The stock is up 2.1% today, which is why its share keeps climbing. Nothing here is a reason to sell, but it is the third-largest position you hold, so the news matters more than it would for a small one.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach([("Nvidia wins approval to ship new chips to Gulf customers", "Reuters, 2 hours ago"),
                             ("Data center demand keeps analysts raising estimates", "Bloomberg, 6 hours ago"),
                             ("Export rules tighten for advanced accelerators", "WSJ, yesterday")], id: \.0) { story in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(story.0).font(.body.weight(.medium))
                            Text(story.1).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Ask about NVDA") {}.buttonStyle(.glassProminent)
            }
            .padding(.horizontal, gutter)
            .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct MCreateGoal: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("No single position above 5%")
                        .font(.system(size: 30, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("I'll check your weights every day and tell you when one crosses 5%.")
                        .font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        MChart(lines: [
                            MLine(id: "AAPL", values: MF.aapl),
                            MLine(id: "NVDA", values: MF.nvda, color: .blue),
                            MLine(id: "AMD", values: MF.amd, color: .indigo),
                        ], limit: 5, height: 150, endLabels: true)
                        Text("Today, Apple (5.9%), NVIDIA (5.3%) and AMD (5.1%) would already be over.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Or start from").font(.footnote).foregroundStyle(.secondary).padding(.bottom, 6)
                        ForEach(["Keep my portfolio balanced", "Find stocks worth buying", "Tell me when news hits my holdings", "Tell me before earnings for what I own"], id: \.self) { text in
                            VStack(spacing: 0) {
                                Divider()
                                Text(text).font(.body).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, gutter)
                .padding(.top, 8)
            }
            .navigationTitle("New goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                ToolbarItem(placement: .confirmationAction) { Button("Add") {}.buttonStyle(.glassProminent) }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
        }
    }
}

private struct MGoalsScreen: View {
    private let goals: [(String, String, String?)] = [
        ("No single position above 5%", "Apple is at 5.9%, NVIDIA at 5.3% and AMD at 5.1%. Apple has been over for two weeks, so I would trim that first.", "Needs a decision"),
        ("Keep my portfolio balanced", "Your two index funds are 48% of the total and the rest is spread across four stocks. Nothing has drifted more than a point this month.", nil),
        ("Tell me when news hits my holdings", "Three stories on NVIDIA since yesterday, none on the others. I will say something when it moves your numbers.", "Worth a look"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(goals, id: \.0) { goal in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(goal.0).font(.headline)
                            Spacer(minLength: 8)
                            Text(goal.2 ?? "On track").font(.subheadline).foregroundStyle(goal.2 == "Needs a decision" ? Color.orange : .secondary)
                        }
                        Text(goal.1).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 14)
                    Divider()
                }
                Text("Create a goal").foregroundStyle(.tint).padding(.vertical, 14)

                Text("Ideas").font(.title.weight(.bold)).padding(.top, 28).padding(.bottom, 4)
                ForEach(["Balance", "News"], id: \.self) { group in
                    Text(group).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 4)
                    ForEach(MF.ideas.filter { $0.group == group }) { idea in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(idea.title).font(.body.weight(.semibold))
                            Text(idea.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                        Divider()
                    }
                }
                Text("I can write a full review of your portfolio").foregroundStyle(.tint).padding(.vertical, 14)
            }
            .padding(.horizontal, gutter)
        }
        .navigationTitle("Goals")
        .navigationBarTitleDisplayMode(.large)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct MBalance: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                MHero(caption: "Your largest stocks, share of portfolio", value: "5.9%", sentence: "Apple leads. Three stocks are over 5%.")
                VStack(alignment: .leading, spacing: 10) {
                    MChart(lines: [
                        MLine(id: "AAPL", values: MF.aapl),
                        MLine(id: "NVDA", values: MF.nvda, color: .blue),
                        MLine(id: "AMD", values: MF.amd, color: .indigo),
                    ], limit: 5, height: 270, endLabels: true)
                    MFootnote()
                }
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No single position above 5%").font(.headline)
                        Text("All three crossed the line within the last three weeks, Apple first. A trim of about $720 in Apple and a few shares of each of the others would bring you back.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keep my portfolio balanced").font(.headline)
                        Text("The rest of the portfolio has barely moved. Index funds are still close to half.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, gutter)
            .padding(.bottom, 24)
        }
        .navigationTitle("Balance")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

// MARK: Sheet

private struct MPriorityIdeaSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("I can show how to bring AAPL back under your 5% limit")
                .font(.title2.weight(.bold))
                .padding(.top, 28)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("5.9%").font(.system(size: 44, weight: .bold)).monospacedDigit()
                Text("of your portfolio, over for two weeks").font(.subheadline).foregroundStyle(.secondary)
            }
            MChart(lines: [MLine(id: "AAPL", values: MF.aapl)], limit: 5, height: 130, shade: true)
            Text("Trimming about $720 would fix it. NVIDIA and AMD are a little over as well.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Show me") {}.buttonStyle(.glassProminent)
                    Button("All goals and ideas") {}.buttonStyle(.glass)
                }
            }
        }
        .padding(.horizontal, gutter)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Today

private struct MToday: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 12) {
                        ForEach([("S&P 500", "6,842", "+0.4%", [1.0, 1.4, 1.2, 1.9, 1.7, 2.3]), ("Nasdaq", "23,118", "+0.8%", [1.0, 0.8, 1.5, 1.4, 2.2, 2.6])], id: \.0) { index in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(index.0).font(.subheadline).foregroundStyle(.secondary)
                                Text(index.1).font(.title2.weight(.bold)).monospacedDigit()
                                Text(index.2).font(.subheadline).foregroundStyle(.green)
                                Chart(Array(index.3.enumerated()), id: \.offset) { point in
                                    LineMark(x: .value("t", point.offset), y: .value("v", point.element)).foregroundStyle(.green).interpolationMethod(.monotone)
                                }
                                .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 28)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
                        }
                    }
                    .padding(.horizontal, gutter)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("For your portfolio").font(.title3.weight(.bold)).padding(.horizontal, gutter)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(MF.ideas) { idea in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(idea.title).font(.title3.weight(.semibold)).lineLimit(3)
                                        Text(idea.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                        Spacer(minLength: 0)
                                        let values = idea.symbol == "AAPL" ? MF.aapl : (idea.symbol == "NVDA" ? MF.nvda : MF.amd)
                                        MChart(lines: [MLine(id: idea.symbol, values: values)], limit: idea.id == 1 ? 5 : nil, height: 64, compact: true, shade: idea.id == 1)
                                    }
                                    .padding(18)
                                    .frame(width: 310, height: 235, alignment: .topLeading)
                                    .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .contentMargins(.horizontal, gutter)
                        .scrollTargetBehavior(.viewAligned)
                        HStack(spacing: 6) {
                            ForEach(0..<3, id: \.self) { Circle().fill(.primary.opacity($0 == 0 ? 0.8 : 0.2)).frame(width: 6, height: 6) }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Top stories").font(.title3.weight(.bold))
                        ForEach([("Fed officials signal patience on rate cuts", "Reuters, 1 hour ago"), ("Oil slips as inventories build for a third week", "Bloomberg, 3 hours ago")], id: \.0) { story in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(story.0).font(.headline)
                                Text(story.1).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, gutter)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Today")
            .scrollEdgeEffectStyle(.soft, for: .all)
        }
    }
}
#endif
