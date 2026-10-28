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

/// The sections of the home card. One shows at a time so the dashboard stays within half the screen.
enum HomeTab: String, CaseIterable, Identifiable {
    case moves, positions, watchlist, next

    var id: Self { self }

    var title: String {
        switch self {
        case .moves: "Moves"
        case .positions: "Positions"
        case .watchlist: "Watchlist"
        case .next: "Next"
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

    static func arrivals(since date: Date?, in stories: [Story], now: Date = .now) -> String? {
        guard let date else { return nil }
        let count = Self.stories(stories.filter { $0.receivedAt > date }, limit: .max).count
        return count == 0 ? nil : "\(count) new since \(HomeFormat.since(date, now: now))"
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
        return Array(stories.lazy.filter { story in
            if story.tickers.contains(where: { names.contains(normalize($0)) }) { return true }
            if story.textSymbols.contains(where: { names.contains(normalize($0)) }) { return true }
            guard !companies.isEmpty else { return false }
            let searchable = " " + "\(story.title)\n\(story.summary)".lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
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

    static func whole(_ value: Double) -> String {
        abs(value).formatted(.currency(code: "USD").precision(.fractionLength(abs(value) >= 100 ? 0 : 2)))
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
        .frame(minHeight: 24)
    }
}

// MARK: Market status

struct MarketStatusLine: View {
    let now: Date
    var onQuote: (String) -> Void
    @State private var board = MarketBoard.shared
    @Environment(\.scenePhase) private var scenePhase

    private var phase: HomePhase { HomePhase.at(now) }

    static func status(at now: Date) -> String {
        let timing = timing(at: now)
        return timing.isEmpty ? HomePhase.at(now).label : "\(HomePhase.at(now).label) · \(timing)"
    }

    private var symbols: [(symbol: String, label: String)] {
        phase.usesFutures
            ? [("ES=F", "S&P fut"), ("NQ=F", "Nasdaq fut"), ("RTY=F", "Russell fut"), ("^VIX", "VIX"), ("^TNX", "10Y")]
            : [("SPY", "SPY"), ("QQQ", "QQQ"), ("IWM", "IWM"), ("^VIX", "VIX"), ("^TNX", "10Y")]
    }

    private static func timing(at now: Date) -> String {
        switch HomePhase.at(now) {
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
        HStack(spacing: 0) {
            ForEach(symbols, id: \.symbol) { item in
                Button { onQuote(item.symbol) } label: { chip(item.symbol, label: item.label, now: now) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .homeCard()
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
    @State private var watchlist = Watchlist.shared
    @State private var portfolio = PortfolioStore.shared

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
        /// The few words a chip keeps from the detail: the dollar impact or days to expiry.
        var brief: String? = nil
    }

    private var items: [Item] {
        _ = (watchlist.symbols, portfolio.snapshot.updated)
        var result: [Item] = []
        let held = Set(HomeSymbols.held)
        let since = ledger.since
        let positions = HomeSymbols.positions

        for symbol in HomeSymbols.tracked {
            guard let quote = board.quotes[symbol], quote.price > 0 else { continue }
            // With a "Since <time>" header every row must be measured from that visit. A symbol with no recorded
            // price (added after the baseline, or never quoted then) has no baseline, so it is omitted rather than
            // shown with its day change under a "Since" label.
            let previous = since == nil ? nil : ledger.prices[symbol]
            if since != nil, previous == nil || previous! <= 0 { continue }
            switch board.freshness(of: symbol, now: now) {
            case .unavailable?, .delayed?: continue
            default: break
            }
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
                               score: abs(move) * (isHeld ? 2 : 1) + (story == nil ? 0 : 1.5), story: story, brief: impact))
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
                               score: 8 - Double(option.daysLeft), brief: parts[0]))
        }
        return Array(result.sorted { $0.score > $1.score }.prefix(5))
    }

    var body: some View {
        let items = items
        if HomeSymbols.tracked.isEmpty {
            Button(action: onFindSymbols) {
                Text("Star a few symbols or link a brokerage to see what moved while you were away.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain)
        } else {
            FlowLayout(spacing: 6) {
                Text(ledger.since.map { "Since \(HomeFormat.since($0, now: now))" } ?? "Today")
                    .font(.subheadline.weight(.semibold)).frame(height: 30).accessibilityAddTraits(.isHeader)
                ForEach(items) { chip($0) }
                if items.isEmpty {
                    Text("Nothing moved 1% or more").font(.subheadline).foregroundStyle(.secondary).frame(height: 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ item: Item) -> some View {
        Menu {
            Section(item.detail) {
                if let story = item.story { Button("Read Story", systemImage: "newspaper") { onStory(story) } }
                if let symbol = item.symbol {
                    Button("Open \(HomeFormat.display(symbol))", systemImage: "chart.xyaxis.line") { onQuote(symbol) }
                    Button("Set Price Alert…", systemImage: "bell.badge") { onAlert(symbol) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let icon = item.icon { Image(systemName: icon).font(.caption).foregroundStyle(item.tint) }
                Text(item.title).font(.subheadline.weight(.semibold))
                if let value = item.value {
                    Text(value).font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit().foregroundStyle(item.tint)
                }
                if let brief = item.brief { Text(brief).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                if item.story != nil { Image(systemName: "newspaper").font(.caption2).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.primary.opacity(0.07), in: .capsule)
            .contentShape(.capsule)
            .accessibilityElement(children: .combine)
            .accessibilityHint(item.detail)
        } primaryAction: {
            if let story = item.story { onStory(story) } else if let symbol = item.symbol { onQuote(symbol) }
        }
        .buttonStyle(.plain)
    }
}

/// Records the visit baseline and refreshes tracked quotes from a view that is always on screen.
/// The Since card hides when nothing moved, and a hidden card's lifecycle modifiers never run.
struct VisitTracking: ViewModifier {
    @State private var board = MarketBoard.shared
    @State private var ledger = VisitLedger.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    let tracked = Set(HomeSymbols.tracked)
                    // Only record prices that were current when leaving; a stale quote would become a false baseline.
                    ledger.leave(prices: board.quotes.filter { key, quote in
                        guard tracked.contains(key), quote.price > 0 else { return false }
                        switch board.freshness(of: key, now: .now) {
                        case .unavailable?, .delayed?: return false
                        default: return true
                        }
                    }.mapValues(\.price))
                }
                if phase == .active { ledger.arrive() }
            }
            .task(id: "\(HomeSymbols.tracked)-\(scenePhase == .active)") {
                guard scenePhase == .active else { return }
                await board.refresh(quotes: HomeSymbols.tracked, sparks: [])
            }
    }
}

// MARK: Positions

struct PositionMoversCard: View {
    var onQuote: (String) -> Void
    var onAlert: (String) -> Void
    var openPortfolio: () -> Void
    @State private var board = MarketBoard.shared
    @State private var portfolio = PortfolioStore.shared
    @State private var optionQuotes: [String: OptionQuote] = [:]
    @Environment(\.scenePhase) private var scenePhase

    struct Row: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        /// Today's change in dollars, nil when unavailable rather than zero.
        let dollars: Double?
        let percent: Double?
        /// Market value, used to order the list so options rank by what the contracts are worth.
        let value: Double?
        /// What the right column shows when today's change is unavailable.
        var fallback: (text: String, caption: String, tint: Double?)? = nil
        let urgent: Bool
    }

    /// The contract's move in the current regular session, per share. Before the open, or until the contract trades,
    /// Yahoo's change still describes the previous session, so it is unavailable rather than today's move.
    static func sessionChange(_ quote: OptionQuote, now: Date) -> Double? {
        guard let change = quote.change, let traded = quote.lastTrade,
              let session = MarketClock.session(on: now), now >= session.start, traded >= session.start else { return nil }
        return change
    }

    static func rows(positions: [Position], quotes: [String: MarketQuote], options: [String: OptionQuote], now: Date) -> [Row] {
        var stocks: [String: (quantity: Double, value: Double?)] = [:]
        var result: [Row] = []
        for position in positions {
            let symbol = HomeSymbols.normalize(position.symbol)
            if let option = position.option {
                guard option.daysLeft >= 0 else { continue }
                let multiplier = 100 * option.contracts
                let contract = options[position.id]
                let move = contract.flatMap { sessionChange($0, now: now) }
                let value = contract.flatMap { $0.liveMarket ? $0.mark * multiplier : nil } ?? position.value
                var parts = ["\(abs(option.contracts).formatted(.number.precision(.fractionLength(0...2)))) ct"]
                if let value { parts.append(HomeFormat.whole(value)) }
                parts.append("\(option.daysLeft) DTE")
                let previous = contract.map { $0.last - (move ?? 0) }
                let fallback: (String, String, Double?)? = position.gain.map { (HomeFormat.dollars($0), "total", $0) }
                    ?? quotes[symbol].map { (HomeFormat.percent($0.changePercent), "underlying", $0.changePercent) }
                result.append(Row(id: position.id, symbol: symbol, title: "\(HomeFormat.display(symbol)) \(option.title)",
                                  detail: parts.joined(separator: " · "), dollars: move.map { $0 * multiplier },
                                  percent: move.flatMap { move in previous.flatMap { $0 > 0 ? move / $0 * 100 : nil } },
                                  value: value, fallback: fallback, urgent: option.daysLeft <= 7))
            } else {
                let lots = stocks[symbol]
                stocks[symbol] = (quantity: (lots?.quantity ?? 0) + position.quantity,
                                  value: lots == nil ? position.value : lots!.value.flatMap { total in position.value.map { total + $0 } })
            }
        }
        for (symbol, holding) in stocks {
            let quote = quotes[symbol]
            let shares = "\(holding.quantity.formatted(.number.precision(.fractionLength(0...2)))) sh"
            let value = quote.map { $0.price * holding.quantity } ?? holding.value
            let detail = [[shares, value.map(HomeFormat.whole)].compactMap { $0 }.joined(separator: " · "),
                          quote?.earnings.flatMap { earningsNote($0, now: now) }]
                .compactMap { $0 }.joined(separator: " · ")
            result.append(Row(id: symbol, symbol: symbol, title: HomeFormat.display(symbol), detail: detail,
                              dollars: quote.map { $0.change * holding.quantity }, percent: quote?.changePercent, value: value, urgent: false))
        }
        return result.sorted { a, b in
            if a.urgent != b.urgent { return a.urgent }
            return abs(a.value ?? 0) > abs(b.value ?? 0)
        }
    }

    private var rows: [Row] {
        _ = portfolio.snapshot.updated
        return Self.rows(positions: HomeSymbols.positions, quotes: board.quotes, options: optionQuotes, now: .now)
    }

    private static func earningsNote(_ date: Date, now: Date) -> String? {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 99
        guard (0...7).contains(days) else { return nil }
        return days == 0 ? "Earnings today" : days == 1 ? "Earnings tomorrow" : "Earnings \(date.formatted(.dateTime.weekday(.abbreviated)))"
    }

    var body: some View {
        let rows = rows
        if rows.isEmpty {
            Button(action: openPortfolio) {
                Text("Link a brokerage to see your positions here.").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain)
        } else {
            let total = rows.compactMap(\.dollars).reduce(0, +)
            let shown = Array(rows.prefix(3))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { row in
                    line(row)
                    if row.id != shown.last?.id { Divider() }
                }
                Button(action: openPortfolio) {
                    HStack(spacing: 4) {
                        if rows.contains(where: { $0.dollars != nil }) {
                            // Positions without a move today are left out of the total, so say so instead of implying all of them.
                            Text("\(HomeFormat.dollars(total)) today\(rows.contains { $0.dollars == nil } ? " · partial" : "")")
                                .fontWeight(.semibold).foregroundStyle(HomeFormat.tint(total))
                            Text("·")
                        }
                        Text(rows.count > shown.count ? "All \(rows.count) positions" : "Portfolio")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .padding(.top, 6).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .task(id: "\(HomeSymbols.positions.filter { $0.option != nil }.map(\.id))-\(scenePhase == .active)") { await refreshOptions() }
        }
    }

    private func refreshOptions() async {
        guard scenePhase == .active, !FinancialFreshnessPreview.active else { return }
        while !Task.isCancelled {
            let held = HomeSymbols.positions.filter { ($0.option?.daysLeft ?? -1) >= 0 }
            guard !held.isEmpty else { optionQuotes = [:]; return }
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
            do { try await Task.sleep(for: .seconds(found.values.contains(where: \.liveMarket) ? 30 : 120)) } catch { return }
        }
    }

    private func line(_ row: Row) -> some View {
        Menu {
            Section(row.detail) {
                Button("Open \(HomeFormat.display(row.symbol))", systemImage: "chart.xyaxis.line") { onQuote(row.symbol) }
                Button("Set Price Alert…", systemImage: "bell.badge") { onAlert(row.symbol) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title).font(.subheadline.weight(.semibold)).layoutPriority(2)
                if row.urgent { Image(systemName: "hourglass").font(.caption2).foregroundStyle(.orange) }
                Text(row.detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let dollars = row.dollars {
                    Text(HomeFormat.dollars(dollars)).font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HomeFormat.tint(dollars)).layoutPriority(2)
                    if let percent = row.percent {
                        Text(HomeFormat.percent(percent)).font(.caption2).foregroundStyle(.secondary).layoutPriority(1)
                    }
                } else if let fallback = row.fallback {
                    Text(fallback.text).font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HomeFormat.tint(fallback.tint)).layoutPriority(2)
                    Text(fallback.caption).font(.caption2).foregroundStyle(.tertiary).layoutPriority(1)
                } else {
                    Text("—").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1).monospacedDigit()
            .frame(height: 32)
            .contentShape(.rect)
        } primaryAction: { onQuote(row.symbol) }
        .buttonStyle(.plain)
    }
}

/// One watchlist symbol on a single line for the home card.
struct WatchlistLine: View {
    let symbol: String
    @State private var board = MarketBoard.shared

    var body: some View {
        let quote = board.quotes[symbol]
        let notice = board.freshness(of: symbol, now: .now)?.notice
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(OptionSymbol.display(symbol)).font(.subheadline.weight(.semibold)).layoutPriority(2)
            Text(quote?.name ?? "").font(.caption).foregroundStyle(.secondary)
            if let notice { Image(systemName: notice.symbol).font(.caption2).foregroundStyle(notice.tint).accessibilityLabel(notice.text) }
            Spacer(minLength: 6)
            Text(quote.map { QuoteFormat.price($0.price) } ?? "—").font(.subheadline.weight(.semibold)).layoutPriority(2)
            Text(quote.map { QuoteFormat.percent($0.changePercent) } ?? " ").font(.caption.weight(.semibold))
                .foregroundStyle(QuoteFormat.color(quote?.changePercent ?? 0)).layoutPriority(2)
        }
        .lineLimit(1).monospacedDigit()
        .frame(height: 32)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Coming up

struct TodayEventsCard: View {
    let now: Date
    var limit = 2
    var onQuote: (String) -> Void
    @State private var board = MarketBoard.shared
    @State private var pulse = PulseStore.shared
    @State private var watchlist = Watchlist.shared

    struct Event: Identifiable {
        let id: String
        let at: Date
        let title: String
        /// A number worth a second line: a consensus forecast or EPS estimate.
        var detail: String? = nil
        /// A few words at the end of the line, such as "Held".
        var note: String? = nil
        var symbols: [String] = []
        /// "Before open" or "After close" when the source only knows which side of the session the event falls on.
        var session: String? = nil
        var clockTime = true
    }

    struct Earnings {
        let symbol: String
        let at: Date
        let timing: String?
        let estimated: Bool
        let held: Bool
    }

    static func events(upcoming: [MarketPulse.Upcoming], earnings: [Earnings], now: Date, calendar: Calendar = .current) -> [Event] {
        var result: [Event] = []
        for item in upcoming where item.at > now.addingTimeInterval(-3 * 3600) && item.at < now.addingTimeInterval(36 * 3600) {
            result.append(Event(id: item.id, at: item.at, title: item.title, detail: fact(item.detail), session: session(item.timing),
                                clockTime: item.timing == nil && !item.title.hasSuffix(" earnings")))
        }
        // Yahoo stamps reports with placeholder clock times, so reports on the same day and side of the session are one event.
        let start = calendar.startOfDay(for: now)
        var keys: [String] = []
        var groups: [String: [Earnings]] = [:]
        for report in earnings where report.at >= start && report.at < now.addingTimeInterval(4 * 86400) {
            let key = "\(calendar.startOfDay(for: report.at).timeIntervalSince1970)|\(session(report.timing) ?? "")|\(report.estimated)"
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(report)
        }
        for key in keys {
            let group = groups[key]!
            let symbols = group.map(\.symbol)
            let names = symbols.prefix(3).map(HomeFormat.display).joined(separator: ", ") + (symbols.count > 3 ? " +\(symbols.count - 3)" : "")
            let held = group.filter(\.held).map { HomeFormat.display($0.symbol) }
            let owner: String? = held.isEmpty ? nil : held.count == symbols.count ? "Held" : "\(held.joined(separator: ", ")) held"
            result.append(Event(id: "earnings-\(key)", at: group.map(\.at).min()!, title: "\(names) earnings",
                                note: [owner, group[0].estimated ? "date est." : nil].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                                symbols: symbols, session: session(group[0].timing), clockTime: false))
        }
        return Array(result.sorted { ($0.at, $0.title) < ($1.at, $1.title) }.prefix(5))
    }

    static func session(_ timing: String?) -> String? {
        guard let timing = timing?.lowercased() else { return nil }
        if timing.hasPrefix("before") { return "Before open" }
        if timing.hasPrefix("after") { return "After close" }
        return nil
    }

    /// Pulse details end with how much the event can move the index next to the other drivers; only the leading fact stands alone.
    static func fact(_ detail: String) -> String? {
        let sentences = detail.components(separatedBy: ". ")
        guard sentences.count > 1 else { return nil }
        // "CPI m/m forecast 0.6%" repeats the event's own title; the number is what the line is for.
        if let range = sentences[0].range(of: " forecast ") { return "Forecast \(sentences[0][range.upperBound...])" }
        return sentences[0]
    }

    static func time(_ event: Event, now: Date, calendar: Calendar = .current) -> String {
        let midnight = calendar.component(.hour, from: event.at) == 0 && calendar.component(.minute, from: event.at) == 0
        let clock = event.session ?? (event.clockTime && !midnight ? event.at.formatted(.dateTime.hour().minute()) : nil)
        let day: String? = calendar.isDate(event.at, inSameDayAs: now) ? nil
            : calendar.isDate(event.at, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now)!) ? "Tmrw"
            : event.at.formatted(.dateTime.weekday(.abbreviated))
        guard let day else { return clock ?? "Today" }
        guard let clock else { return day == "Tmrw" ? "Tomorrow" : day }
        return "\(day) \(event.session == nil ? clock : clock.lowercased())"
    }

    private var upcoming: [MarketPulse.Upcoming] {
        #if DEBUG
        if let demo = HomeBriefingDemo.upcoming { return demo }
        #endif
        return pulse.current?.comingUp ?? []
    }

    private var earnings: [Earnings] {
        #if DEBUG
        if let demo = HomeBriefingDemo.earnings { return demo }
        #endif
        _ = watchlist.symbols
        let held = Set(HomeSymbols.held)
        return HomeSymbols.tracked.compactMap { symbol in
            guard let quote = board.quotes[symbol], let date = quote.earnings else { return nil }
            return Earnings(symbol: symbol, at: date, timing: quote.earningsTiming, estimated: quote.earningsEstimated, held: held.contains(symbol))
        }
    }

    var body: some View {
        let events = Array(Self.events(upcoming: upcoming, earnings: earnings, now: now).prefix(limit))
        if !events.isEmpty {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: events.count, by: 2)), id: \.self) { index in
                    GridRow {
                        row(events[index])
                        if index + 1 < events.count { row(events[index + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ event: Event) -> some View {
        if event.symbols.count > 1 {
            Menu {
                ForEach(event.symbols, id: \.self) { symbol in
                    Button("Open \(HomeFormat.display(symbol))", systemImage: "chart.xyaxis.line") { onQuote(symbol) }
                }
            } label: { line(event) }
            .buttonStyle(.plain)
        } else if let symbol = event.symbols.first {
            Button { onQuote(symbol) } label: { line(event) }.buttonStyle(.plain)
        } else {
            line(event)
        }
    }

    private func line(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.time(event, now: now)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Text(event.title).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            if let extra = [event.detail, event.note].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                Text(extra).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        .opacity(event.at < now ? 0.45 : 1)
        .contentShape(.rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: Outlook

struct OutlookLine: View {
    var now: Date?
    var embedded = false
    @State private var store = PulseStore.shared
    @State private var macro = MacroStore.shared
    @State private var showing = false
    @State private var hitRate: Double?
    @State private var graded = 0
    @Environment(\.scenePhase) private var phase

    private var record: String {
        guard let hitRate, graded > 0 else { return "Not yet graded" }
        return "\(Int((hitRate * 100).rounded()))% right · \(graded) graded"
    }

    var body: some View {
        let button = Button { showing = true } label: {
            VStack(alignment: .leading, spacing: embedded ? 2 : 6) {
                if !embedded {
                    HomeCardHeader(title: "Outlook · \(PulseStore.names[store.symbol] ?? store.symbol)") {
                        HStack(spacing: 6) {
                            Text(record).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                }
                if let pulse = store.current {
                    TimelineView(.everyMinute) { context in
                        let note = pulse.outlookNote(at: now ?? context.date, refreshFailed: store.failed, fetchedAt: store.fetchedAt(store.symbol))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if embedded { Text(PulseStore.names[store.symbol] ?? store.symbol).foregroundStyle(.secondary) }
                                Text(pulse.call?.headline ?? "Outlook unavailable")
                                    .foregroundStyle(note.standing == .current ? pulse.tint : Color.secondary)
                                if embedded { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
                            }
                            .font(embedded ? .subheadline.weight(.semibold) : .subheadline).lineLimit(1)
                            Text(embedded ? "\(note.text) · \(record)" : note.text).font(.caption2)
                                .foregroundStyle(note.refreshFailed || note.standing == .expired ? Color.orange : Color.secondary)
                                .lineLimit(embedded ? 1 : 2)
                        }
                    }
                } else {
                    Text(store.failed ? "Outlook unavailable" : "Loading outlook…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, embedded ? 0 : 16).padding(.vertical, embedded ? 0 : 12)
            .contentShape(.rect)
        }
        .buttonStyle(PressSpringStyle())
        Group { if embedded { button } else { button.homeCard() } }
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
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.caption).monospacedDigit().lineLimit(1) }
        }
        .foregroundStyle(.secondary)
    }
}

#if DEBUG
enum HomeBriefingDemo {
    static let active = CommandLine.arguments.contains("-briefingDemo")
    nonisolated(unsafe) static var watched: [String]?
    nonisolated(unsafe) static var positions: [Position]?
    nonisolated(unsafe) static var upcoming: [MarketPulse.Upcoming]?
    nonisolated(unsafe) static var earnings: [TodayEventsCard.Earnings]?

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
        let now = Date.now
        upcoming = [
            MarketPulse.Upcoming(title: "Federal Funds Rate, FOMC Statement", at: now.addingTimeInterval(8 * 3600),
                                 detail: "Federal Funds Rate forecast 4.00%. A surprise here can outweigh everything above.", timing: nil),
            MarketPulse.Upcoming(title: "FOMC Press Conference", at: now.addingTimeInterval(8.5 * 3600),
                                 detail: "A surprise here can outweigh everything above.", timing: nil),
        ]
        earnings = ["KEX", "VFC", "GEV"].map { TodayEventsCard.Earnings(symbol: $0, at: now.addingTimeInterval(2.5 * 3600), timing: "Before open", estimated: false, held: false) }
            + [TodayEventsCard.Earnings(symbol: "MSFT", at: now.addingTimeInterval(30 * 3600), timing: "After close", estimated: false, held: true)]
        VisitLedger.shared.override(since: Calendar.current.date(byAdding: .hour, value: -15, to: .now)!, prices: prices)
    }
}
#endif
