import SwiftUI

nonisolated enum HomePhase: String {
    case premarket, open, after, overnight, closed

    static func at(_ now: Date) -> HomePhase {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "-homePhase"),
           let value = CommandLine.arguments.dropFirst(index + 1).first.flatMap(HomePhase.init(rawValue:)) { return value }
        #endif
        let hour = MarketClock.calendar.component(.hour, from: now)
        guard let session = MarketClock.session(on: now) else { return MarketClock.futuresScheduled(now) ? .overnight : .closed }
        if session.contains(now) { return .open }
        if now < session.start { return hour >= 4 ? .premarket : .overnight }
        return hour < 20 ? .after : .overnight
    }

    var label: String {
        switch self {
        case .premarket: "Pre-market"
        case .open: "Market open"
        case .after: "After hours"
        case .overnight: "Overnight"
        case .closed: "Market closed"
        }
    }

    var usesFutures: Bool { self != .open }
}

enum HomeBlock: Hashable {
    case status, sinceVisit, positions, today, dashboard, outlook

    static func order(for phase: HomePhase) -> [HomeBlock] {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "-homeSkip"), let skip = CommandLine.arguments.dropFirst(index + 1).first {
            let hidden = Set(skip.split(separator: ","))
            return standard(for: phase).filter { !hidden.contains(Substring(String(describing: $0))) }
        }
        #endif
        return standard(for: phase)
    }

    private static func standard(for phase: HomePhase) -> [HomeBlock] {
        switch phase {
        case .open: [.status, .sinceVisit, .positions, .dashboard, .today, .outlook]
        case .after: [.status, .sinceVisit, .positions, .today, .dashboard, .outlook]
        case .premarket, .overnight, .closed: [.status, .sinceVisit, .today, .positions, .dashboard, .outlook]
        }
    }
}

/// The symbols the home screen treats as "yours": held positions first, then the watchlist.
enum HomeSymbols {
    static var positions: [Position] {
        #if DEBUG
        if let demo = HomeBriefingDemo.positions { return demo }
        #endif
        return PortfolioStore.shared.snapshot.positions
    }

    static var held: [String] {
        var seen = Set<String>()
        return positions.map(\.symbol).map(normalize).filter { seen.insert($0).inserted }
    }

    static var watched: [String] {
        #if DEBUG
        if let demo = HomeBriefingDemo.watched { return demo }
        #endif
        return Watchlist.shared.symbols
    }

    static var tracked: [String] {
        var seen = Set<String>()
        return (held + watched).filter { seen.insert($0).inserted }
    }

    static func normalize(_ ticker: String) -> String {
        ticker.trimmingCharacters(in: CharacterSet(charactersIn: "$ ")).uppercased()
    }

    static func stories(_ stories: [Story], limit: Int = 5) -> [Story] {
        let names = Set(tracked.map(normalize))
        guard !names.isEmpty else { return [] }
        let companies: [(String, String)] = positions.filter { $0.option == nil }.compactMap { position in
            guard let name = position.name else { return nil }
            let core = TickerNews.core(name, symbol: position.symbol).lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
            return core.count >= 4 ? (normalize(position.symbol), " \(core) ") : nil
        }
        return Array(stories.filter { story in
            if story.tickers.contains(where: { names.contains(normalize($0)) }) { return true }
            let text = "\(story.title)\n\(story.summary)"
            if TickerScanner.symbols(in: text).contains(where: { names.contains(normalize($0)) }) { return true }
            let searchable = " " + text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
            return companies.contains { searchable.contains($0.1) }
        }.prefix(limit))
    }
}

/// Remembers prices when the app goes to the background, so the next visit can say what moved while you were away.
/// Short trips out of the app keep the older baseline; otherwise every quick app switch would reset it to "nothing changed".
@Observable final class VisitLedger {
    static let shared = VisitLedger()
    private(set) var since: Date?
    private(set) var prices: [String: Double] = [:]
    @ObservationIgnored var frozen = false

    private struct Saved: Codable { let at: Date; let prices: [String: Double] }

    init() { arrive() }

    func leave(prices current: [String: Double]) {
        guard !frozen, let data = try? JSONEncoder().encode(Saved(at: .now, prices: current)) else { return }
        UserDefaults.standard.set(data, forKey: "homeVisitPending")
    }

    func arrive() {
        guard !frozen else { return }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "homeVisitPending"), let pending = try? JSONDecoder().decode(Saved.self, from: data) {
            defaults.removeObject(forKey: "homeVisitPending")
            if -pending.at.timeIntervalSinceNow > 15 * 60 || defaults.data(forKey: "homeVisitBaseline") == nil {
                defaults.set(data, forKey: "homeVisitBaseline")
            }
        }
        if let data = defaults.data(forKey: "homeVisitBaseline"), let baseline = try? JSONDecoder().decode(Saved.self, from: data) {
            since = baseline.at
            prices = baseline.prices
        }
    }

    func override(since date: Date, prices values: [String: Double]) {
        frozen = true
        since = date
        prices = values
    }
}

enum HomeFormat {
    static func percent(_ value: Double) -> String {
        String(format: "%@%.1f%%", value > 0 ? "+" : value < 0 ? "−" : "", abs(value))
    }

    static func dollars(_ value: Double, signed: Bool = true) -> String {
        let magnitude = abs(value).formatted(.currency(code: "USD").precision(.fractionLength(abs(value) >= 1000 ? 0 : 2)))
        guard signed else { return magnitude }
        return (value > 0 ? "+" : value < 0 ? "−" : "") + magnitude
    }

    static func tint(_ value: Double?) -> Color {
        guard let value, abs(value) >= 0.005 else { return .secondary }
        return value > 0 ? .green : .red
    }

    static func since(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInYesterday(date) { return "yesterday \(time)" }
        if now.timeIntervalSince(date) < 6 * 86400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func countdown(to target: Date, now: Date) -> String {
        let minutes = max(0, Int(ceil(target.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d \((minutes % 1440) / 60)h"
    }

    static func display(_ symbol: String) -> String { OptionSymbol.display(symbol) }
}

struct HomeCardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            trailing.font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minHeight: 28)
    }
}

// MARK: Market status

struct MarketStatusLine: View {
    let now: Date
    var onQuote: (String) -> Void
    @State private var board = MarketBoard.shared
    @State private var alerts = false
    @Environment(\.scenePhase) private var scenePhase

    private var phase: HomePhase { HomePhase.at(now) }

    private var symbols: [(symbol: String, label: String)] {
        phase.usesFutures
            ? [("ES=F", "S&P fut"), ("NQ=F", "Nasdaq fut"), ("RTY=F", "Russell fut"), ("^VIX", "VIX"), ("^TNX", "10Y")]
            : [("SPY", "SPY"), ("QQQ", "QQQ"), ("IWM", "IWM"), ("^VIX", "VIX"), ("^TNX", "10Y")]
    }

    private var timing: String {
        switch phase {
        case .open:
            guard let session = MarketClock.session(on: now) else { return "" }
            return "closes in \(HomeFormat.countdown(to: session.end, now: now))"
        case .closed where !MarketClock.futuresScheduled(now):
            return "futures \(MarketClock.futuresReopen(after: now).formatted(.dateTime.weekday(.abbreviated).hour()))"
        default:
            let open = MarketClock.nextOpen(after: now)
            let soon = open.timeIntervalSince(now) < 12 * 3600
            return soon ? "opens in \(HomeFormat.countdown(to: open, now: now))" : "opens \(open.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeCardHeader(title: phase.label) {
                HStack(spacing: 8) {
                    if !timing.isEmpty { Text(timing).monospacedDigit() }
                    Button { alerts = true } label: {
                        Image(systemName: "bell").font(.subheadline).frame(width: 32, height: 28).contentShape(.rect)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Market alerts")
                }
            }
            HStack(spacing: 0) {
                ForEach(symbols, id: \.symbol) { item in
                    Button { onQuote(item.symbol) } label: { chip(item.symbol, label: item.label, now: now) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .homeCard()
        .sheet(isPresented: $alerts) { SessionAlertsView() }
        .task(id: "\(phase.usesFutures)-\(scenePhase == .active)") {
            guard scenePhase == .active, !FinancialFreshnessPreview.active else { return }
            while !Task.isCancelled {
                await board.refresh(quotes: symbols.map(\.symbol) + HomeSymbols.held, sparks: [])
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private func chip(_ symbol: String, label: String, now: Date) -> some View {
        let quote = board.quotes[symbol]
        let notice = board.freshness(of: symbol, now: now)?.notice
        let value: String
        var tint = HomeFormat.tint(quote?.changePercent)
        switch symbol {
        case "^TNX":
            value = quote.map { String(format: "%.2f%%", $0.price) } ?? "—"
            tint = quote.map { $0.change > 0 ? Color.red : $0.change < 0 ? .green : .secondary } ?? .secondary
        case "^VIX":
            value = quote.map { String(format: "%.1f", $0.price) } ?? "—"
            tint = quote.map { $0.change > 0 ? Color.red : $0.change < 0 ? .green : .secondary } ?? .secondary
        default:
            value = quote.map { HomeFormat.percent($0.changePercent) } ?? "—"
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            HStack(spacing: 4) {
                Text(value).font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(quote == nil ? Color.secondary : tint).lineLimit(1).minimumScaleFactor(0.7)
                if let notice {
                    Image(systemName: notice.symbol).font(.caption2).foregroundStyle(notice.tint)
                        .accessibilityLabel(notice.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Since you were last here

struct SinceVisitCard: View {
    let now: Date
    let stories: [Story]
    var onQuote: (String) -> Void
    var onStory: (Story) -> Void
    var onAlert: (String) -> Void
    var onFindSymbols: () -> Void
    @State private var board = MarketBoard.shared
    @State private var ledger = VisitLedger.shared
    @State private var pulse = PulseStore.shared
    @State private var watchlist = Watchlist.shared
    @State private var portfolio = PortfolioStore.shared
    @Environment(\.scenePhase) private var scenePhase

    struct Item: Identifiable {
        let id: String
        let symbol: String?
        let title: String
        let value: String?
        let tint: Color
        let detail: String
        let icon: String?
        let score: Double
        var story: Story? = nil
    }

    private var items: [Item] {
        _ = (watchlist.symbols, portfolio.snapshot.updated)
        var result: [Item] = []
        let held = Set(HomeSymbols.held)
        let since = ledger.since
        let positions = HomeSymbols.positions

        for symbol in HomeSymbols.tracked {
            guard let quote = board.quotes[symbol], quote.price > 0 else { continue }
            let previous = since == nil ? nil : ledger.prices[symbol]
            let move = previous.map { (quote.price / $0 - 1) * 100 } ?? quote.changePercent
            guard abs(move) >= 1 else { continue }
            let isHeld = held.contains(symbol)
            let shares = positions.filter { $0.option == nil && HomeSymbols.normalize($0.symbol) == symbol }.reduce(0) { $0 + $1.quantity }
            let story = stories.first { story in
                story.tickers.contains { HomeSymbols.normalize($0) == symbol } && story.receivedAt > (since ?? now.addingTimeInterval(-86400))
            }
            let base = previous ?? (quote.price - quote.change)
            let impact = isHeld && shares > 0 ? HomeFormat.dollars(shares * (quote.price - base)) : nil
            let detail: String
            if let story { detail = [impact, story.title].compactMap { $0 }.joined(separator: " · ") }
            else if let impact { detail = "\(impact) on your \(shares.formatted(.number.precision(.fractionLength(0...2)))) shares" }
            else { detail = isHeld ? "Your position" : "On your watchlist" }
            result.append(Item(id: "move-\(symbol)", symbol: symbol, title: HomeFormat.display(symbol), value: HomeFormat.percent(move),
                               tint: HomeFormat.tint(move), detail: detail, icon: nil,
                               score: abs(move) * (isHeld ? 2 : 1) + (story == nil ? 0 : 1.5), story: story))
        }

        for position in positions {
            guard let option = position.option, (0...3).contains(option.daysLeft) else { continue }
            let underlying = HomeSymbols.normalize(position.symbol)
            var parts = [option.daysLeft == 0 ? "Expires today" : "\(option.daysLeft) DTE"]
            if let price = board.quotes[underlying]?.price {
                let distance = (price - option.strike) / option.strike * 100 * (option.isCall ? 1 : -1)
                parts.append(String(format: "%.1f%% %@", abs(distance), distance >= 0 ? "ITM" : "OTM"))
            }
            if let gain = position.gainPercent { parts.append("\(HomeFormat.percent(gain * 100)) total") }
            result.append(Item(id: "option-\(position.id)", symbol: underlying, title: "\(HomeFormat.display(underlying)) \(option.title)",
                               value: nil, tint: .orange, detail: parts.joined(separator: " · "), icon: "hourglass",
                               score: 8 - Double(option.daysLeft)))
        }

        if let event = pulse.current?.comingUp?.first(where: { $0.at > now && $0.at.timeIntervalSince(now) < 18 * 3600 }) {
            result.append(Item(id: "event-\(event.id)", symbol: nil, title: event.title, value: nil, tint: .secondary,
                               detail: event.at.formatted(.dateTime.weekday(.abbreviated).hour().minute()),
                               icon: "calendar", score: 4))
        }
        return Array(result.sorted { $0.score > $1.score }.prefix(5))
    }

    private var newHeadlines: Int {
        guard let since = ledger.since else { return 0 }
        return stories.filter { $0.receivedAt > since }.count
    }

    var body: some View {
        let items = items
        let showsCard = HomeSymbols.tracked.isEmpty || !items.isEmpty
        Group {
            if showsCard {
                VStack(alignment: .leading, spacing: 6) {
                    HomeCardHeader(title: ledger.since.map { "Since \(HomeFormat.since($0, now: now))" } ?? "Today") {
                        if newHeadlines > 0 {
                            Text("\(newHeadlines) new headlines")
                        }
                    }
                    if HomeSymbols.tracked.isEmpty {
                        Button(action: onFindSymbols) {
                            Text("Star a few symbols or link a brokerage, and this will show what moved in your names while you were away.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain).padding(.top, 4)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                row(item)
                                if item.id != items.last?.id { Divider() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .homeCard()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                let tracked = Set(HomeSymbols.tracked)
                ledger.leave(prices: board.quotes.filter { tracked.contains($0.key) }.mapValues(\.price))
            }
            if phase == .active { ledger.arrive() }
        }
        .task(id: "\(HomeSymbols.tracked)-\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            await board.refresh(quotes: HomeSymbols.tracked, sparks: [])
        }
    }

    private func row(_ item: Item) -> some View {
        Menu {
            if let story = item.story { Button("Read Story", systemImage: "newspaper") { onStory(story) } }
            if let symbol = item.symbol {
                Button("Open \(HomeFormat.display(symbol))", systemImage: "chart.xyaxis.line") { onQuote(symbol) }
                Button("Set Price Alert…", systemImage: "bell.badge") { onAlert(symbol) }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if let icon = item.icon {
                    Image(systemName: icon).font(.subheadline).foregroundStyle(item.tint).frame(width: 18).padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let value = item.value {
                            Text(value).font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit().foregroundStyle(item.tint)
                        }
                    }
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        } primaryAction: {
            if let story = item.story { onStory(story) } else if let symbol = item.symbol { onQuote(symbol) }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Positions

struct PositionMoversCard: View {
    var onQuote: (String) -> Void
    var onAlert: (String) -> Void
    var openPortfolio: () -> Void
    @State private var board = MarketBoard.shared
    @State private var portfolio = PortfolioStore.shared
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Row: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let percent: Double?
        let dollars: Double?
        let urgent: Bool
    }

    private var rows: [Row] {
        _ = portfolio.snapshot.updated
        var stocks: [String: Double] = [:]
        var result: [Row] = []
        for position in HomeSymbols.positions {
            let symbol = HomeSymbols.normalize(position.symbol)
            if let option = position.option {
                guard option.daysLeft >= 0 else { continue }
                var parts = ["\(option.daysLeft) DTE"]
                let quote = board.quotes[symbol]
                if let price = quote?.price {
                    let distance = (price - option.strike) / option.strike * 100 * (option.isCall ? 1 : -1)
                    parts.append(String(format: "%.1f%% %@", abs(distance), distance >= 0 ? "ITM" : "OTM"))
                }
                if let gain = position.gainPercent { parts.append("\(HomeFormat.percent(gain * 100)) total") }
                result.append(Row(id: position.id, symbol: symbol, title: "\(HomeFormat.display(symbol)) \(option.title)",
                                  detail: parts.joined(separator: " · "), percent: quote?.changePercent, dollars: nil, urgent: option.daysLeft <= 7))
            } else {
                stocks[symbol, default: 0] += position.quantity
            }
        }
        for (symbol, quantity) in stocks {
            let quote = board.quotes[symbol]
            let shares = "\(quantity.formatted(.number.precision(.fractionLength(0...2)))) sh"
            let detail = [quote.map { "\(shares) · \(HomeFormat.dollars($0.price * quantity, signed: false))" } ?? shares, quote?.earnings.flatMap(earningsNote)]
                .compactMap { $0 }.joined(separator: " · ")
            result.append(Row(id: symbol, symbol: symbol, title: HomeFormat.display(symbol), detail: detail,
                              percent: quote?.changePercent, dollars: quote.map { $0.change * quantity }, urgent: false))
        }
        return result.sorted { a, b in
            if a.urgent != b.urgent { return a.urgent }
            return abs(a.dollars ?? 0) > abs(b.dollars ?? 0)
        }
    }

    private func earningsNote(_ date: Date) -> String? {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)).day ?? 99
        guard (0...7).contains(days) else { return nil }
        return days == 0 ? "Earnings today" : days == 1 ? "Earnings tomorrow" : "Earnings \(date.formatted(.dateTime.weekday(.abbreviated)))"
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            let total = rows.compactMap(\.dollars).reduce(0, +)
            let shown = expanded ? rows : Array(rows.prefix(4))
            VStack(alignment: .leading, spacing: 6) {
                HomeCardHeader(title: "Positions") {
                    HStack(spacing: 12) {
                        if rows.contains(where: { $0.dollars != nil }) {
                            Text("\(HomeFormat.dollars(total)) today").fontWeight(.semibold).monospacedDigit().foregroundStyle(HomeFormat.tint(total))
                        }
                        Button("All", action: openPortfolio).fontWeight(.medium).tint(.wireAccent)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(shown) { row in
                        line(row)
                        if row.id != shown.last?.id { Divider() }
                    }
                }
                if rows.count > 4 {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? "Show less" : "\(rows.count - 4) more")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold))
                        }.font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .homeCard()
        }
    }

    private func line(_ row: Row) -> some View {
        Menu {
            Button("Open \(HomeFormat.display(row.symbol))", systemImage: "chart.xyaxis.line") { onQuote(row.symbol) }
            Button("Set Price Alert…", systemImage: "bell.badge") { onAlert(row.symbol) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if row.urgent { Image(systemName: "hourglass").font(.caption2).foregroundStyle(.orange) }
                    }
                    Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.dollars.map { HomeFormat.dollars($0) } ?? row.percent.map(HomeFormat.percent) ?? "—")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(HomeFormat.tint(row.dollars ?? row.percent))
                    if row.dollars != nil, let percent = row.percent {
                        Text(HomeFormat.percent(percent)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else if row.dollars == nil, row.percent != nil {
                        Text("underlying").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        } primaryAction: { onQuote(row.symbol) }
        .buttonStyle(.plain)
    }
}

// MARK: Coming up

struct TodayEventsCard: View {
    let now: Date
    var onQuote: (String) -> Void
    @State private var board = MarketBoard.shared
    @State private var pulse = PulseStore.shared
    @State private var watchlist = Watchlist.shared

    struct Event: Identifiable {
        let id: String
        let at: Date
        let title: String
        let detail: String?
        let symbol: String?
    }

    private var events: [Event] {
        _ = watchlist.symbols
        var result: [Event] = []
        for item in pulse.current?.comingUp ?? [] where item.at > now.addingTimeInterval(-3 * 3600) && item.at < now.addingTimeInterval(36 * 3600) {
            result.append(Event(id: item.id, at: item.at, title: item.title, detail: item.timing ?? item.detail, symbol: nil))
        }
        let held = Set(HomeSymbols.held)
        let start = Calendar.current.startOfDay(for: now)
        for symbol in HomeSymbols.tracked {
            guard let quote = board.quotes[symbol], let date = quote.earnings, date >= start, date < now.addingTimeInterval(4 * 86400) else { continue }
            result.append(Event(id: "earnings-\(symbol)", at: date, title: "\(HomeFormat.display(symbol)) earnings",
                                detail: [held.contains(symbol) ? "You hold this" : "Watchlist", quote.earningsEstimated ? "date estimated" : nil].compactMap { $0 }.joined(separator: " · "),
                                symbol: symbol))
        }
        return Array(result.sorted { $0.at < $1.at }.prefix(5))
    }

    var body: some View {
        let events = events
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HomeCardHeader(title: "Coming up") { EmptyView() }
                VStack(spacing: 0) {
                    ForEach(events) { event in
                        Button { if let symbol = event.symbol { onQuote(symbol) } } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(timeLabel(event.at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    if let detail = event.detail, !detail.isEmpty {
                                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7)
                            .opacity(event.at < now ? 0.45 : 1)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(event.symbol == nil)
                        if event.id != events.last?.id { Divider().padding(.leading, 78) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .homeCard()
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let hasTime = calendar.component(.hour, from: date) != 0 || calendar.component(.minute, from: date) != 0
        if calendar.isDate(date, inSameDayAs: now) { return hasTime ? date.formatted(.dateTime.hour().minute()) : "Today" }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!) {
            return hasTime ? "Tmrw \(date.formatted(.dateTime.hour()))" : "Tomorrow"
        }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}

// MARK: Outlook

struct OutlookLine: View {
    var now: Date?
    @State private var store = PulseStore.shared
    @State private var macro = MacroStore.shared
    @State private var showing = false
    @State private var hitRate: Double?
    @State private var graded = 0
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Button { showing = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HomeCardHeader(title: "Outlook · \(PulseStore.names[store.symbol] ?? store.symbol)") {
                    HStack(spacing: 6) {
                        if let hitRate, graded > 0 {
                            Text("\(Int((hitRate * 100).rounded()))% right · \(graded) graded").monospacedDigit()
                        } else {
                            Text("Not yet graded")
                        }
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                if let pulse = store.current {
                    TimelineView(.everyMinute) { context in
                        let note = pulse.outlookNote(at: now ?? context.date, refreshFailed: store.failed, fetchedAt: store.fetchedAt(store.symbol))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pulse.call?.headline ?? "Outlook unavailable").font(.subheadline)
                                .foregroundStyle(note.standing == .current ? pulse.tint : Color.secondary).lineLimit(1)
                            Text(note.text).font(.caption2)
                                .foregroundStyle(note.refreshFailed || note.standing == .expired ? Color.orange : Color.secondary)
                                .lineLimit(2)
                        }
                    }
                } else {
                    Text(store.failed ? "Outlook unavailable" : "Loading outlook…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(PressSpringStyle())
        .homeCard()
        .accessibilityHint("Shows what is moving the market")
        .sheet(isPresented: $showing) { PulseDetail() }
        .task(id: "\(store.symbol)-\(phase == .active)") {
            guard phase == .active, !FinancialFreshnessPreview.active else { return }
            await macro.refresh()
            await loadRecord()
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private func loadRecord() async {
        guard let baseURL = NewswireAPI.validatedURL(FeedStore.shared.serverURL),
              let response = try? await NewswireAPI(baseURL: baseURL).marketResearch(symbol: store.symbol),
              !Task.isCancelled else { return }
        let directional = response.recent.filter { $0.horizon == "opening_gap" && ["up", "down"].contains($0.tilt) && ($0.outcome?.direction ?? 0) != 0 }
        guard !directional.isEmpty else {
            if let overall = response.agent?.performance.overall { hitRate = overall.hitRate; graded = overall.scored }
            return
        }
        hitRate = Double(directional.filter { $0.outcome?.direction == ($0.tilt == "up" ? 1 : -1) }.count) / Double(directional.count)
        graded = directional.count
    }
}

#if DEBUG
struct FinancialFreshnessPreviewScreen: View {
    init() {
        MarketBoard.shared.seedFreshnessPreview(now: FinancialFreshnessPreview.now)
        PulseStore.shared.seedFreshnessPreview(now: FinancialFreshnessPreview.now, expired: FinancialFreshnessPreview.expired)
    }

    var body: some View {
        let now = FinancialFreshnessPreview.now
        ScrollView {
            VStack(spacing: 12) {
                MarketStatusLine(now: now, onQuote: { _ in })
                OutlookLine(now: now)
                VStack(spacing: 0) {
                    CompactWatchlistQuote(symbol: "SPY", quote: MarketBoard.shared.quotes["SPY"], now: now)
                    CompactWatchlistQuote(symbol: "QQQ", quote: MarketBoard.shared.quotes["QQQ"], now: now)
                    CompactWatchlistQuote(symbol: "NVDA", quote: MarketBoard.shared.quotes["NVDA"], now: now)
                    CompactWatchlistQuote(symbol: "IWM", quote: nil, now: now)
                    CompactWatchlistQuote(symbol: "^VIX", quote: MarketBoard.shared.quotes["^VIX"], now: now)
                }
                .homeCard()
            }
            .padding(16)
        }
    }
}
#endif

// MARK: Price alert

struct PriceAlertComposer: View {
    let symbol: String
    @Environment(\.dismiss) private var dismiss
    @State private var board = MarketBoard.shared
    @State private var target = ""
    @State private var saving = false
    @State private var error: String?

    private var price: Double? { board.quotes[symbol]?.price }
    private var targetValue: Double? { Double(target.replacingOccurrences(of: ",", with: "")).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Last price")
                        Spacer()
                        Text(price.map { $0.formatted(.currency(code: "USD")) } ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                    TextField("Target price", text: $target).keyboardType(.decimalPad).monospacedDigit()
                } footer: {
                    if let price, let targetValue {
                        Text("Alerts when \(HomeFormat.display(symbol)) moves \(targetValue >= price ? "above" : "below") \(targetValue.formatted(.currency(code: "USD"))), \(HomeFormat.percent((targetValue / price - 1) * 100)) from here.")
                    }
                }
                if let price {
                    Section("Quick targets") {
                        HStack(spacing: 8) {
                            ForEach([-5.0, -2.0, 2.0, 5.0], id: \.self) { step in
                                Button(String(format: "%@%.0f%%", step > 0 ? "+" : "−", abs(step))) {
                                    target = String(format: "%.2f", price * (1 + step / 100))
                                }
                                .buttonStyle(.bordered).tint(step < 0 ? .red : .green).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Alert · \(HomeFormat.display(symbol))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(targetValue == nil || saving)
                }
            }
            .task { await board.refresh(quotes: [symbol], sparks: []) }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        guard let targetValue else { return }
        saving = true
        defer { saving = false }
        do {
            try await PriceWatchStore.shared.add(symbol: symbol, target: targetValue, direction: targetValue >= (price ?? targetValue) ? "above" : "below")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct HomeListHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
enum HomeBriefingDemo {
    static let active = CommandLine.arguments.contains("-briefingDemo")
    nonisolated(unsafe) static var watched: [String]?
    nonisolated(unsafe) static var positions: [Position]?

    static func install(stories: [Story]) async {
        guard active, positions == nil else { return }
        var fromNews: [String] = []
        for ticker in stories.flatMap(\.tickers).map(HomeSymbols.normalize)
        where !fromNews.contains(ticker) && ticker.range(of: "^[A-Z]{1,5}$", options: .regularExpression) != nil && !["AAPL", "NVDA", "MSFT"].contains(ticker) {
            fromNews.append(ticker)
        }
        watched = Array((fromNews.prefix(3) + ["TSLA", "AMD"]).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(5))
        let board = MarketBoard.shared
        await board.refresh(quotes: ["AAPL", "NVDA", "MSFT"] + (watched ?? []), sparks: [])
        let aapl = board.quotes["AAPL"]?.price ?? 250
        positions = [
            Position(id: "demo|aapl", itemID: "demo", institution: "Demo", account: "Individual", symbol: "AAPL", name: "Apple", option: nil, quantity: 60, price: aapl, value: aapl * 60, reportedCost: 60 * aapl * 0.82),
            Position(id: "demo|nvda", itemID: "demo", institution: "Demo", account: "Individual", symbol: "NVDA", name: "NVIDIA", option: nil, quantity: 40, price: nil, value: nil, reportedCost: nil),
            Position(id: "demo|msft", itemID: "demo", institution: "Demo", account: "Individual", symbol: "MSFT", name: "Microsoft", option: nil, quantity: 15, price: nil, value: nil, reportedCost: nil),
            Position(id: "demo|aapl-call", itemID: "demo", institution: "Demo", account: "Individual", symbol: "AAPL", name: "Apple Call",
                     option: OptionDetail(isCall: true, strike: (aapl / 5).rounded() * 5, expiration: Calendar.current.date(byAdding: .day, value: 2, to: .now)!, contracts: 2),
                     quantity: 200, price: 3.1, value: 620, reportedCost: 450),
        ]
        let offsets: [String: Double] = ["NVDA": 1.043, "AAPL": 0.988, "MSFT": 0.996]
        var prices: [String: Double] = [:]
        for symbol in HomeSymbols.tracked {
            guard let price = board.quotes[symbol]?.price else { continue }
            prices[symbol] = price * (offsets[symbol] ?? (watched?.first == symbol ? 0.975 : 0.998))
        }
        VisitLedger.shared.override(since: Calendar.current.date(byAdding: .hour, value: -15, to: .now)!, prices: prices)
    }
}
#endif
