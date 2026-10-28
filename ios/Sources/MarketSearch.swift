import SwiftUI

enum MarketSearchSelection {
    static func symbol(query: String, matchesQuery: String, firstMatch: String?) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return matchesQuery == trimmed ? firstMatch ?? trimmed : trimmed
    }
}

nonisolated struct Spark: Sendable, Hashable {
    let points: [Double]
    let baseline: Double?
}

enum FinancialFreshnessPreview {
    static var active: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-financialFreshnessPreview")
        #else
        false
        #endif
    }

    /// Fixed clock for the DEBUG preview: Monday 2026-10-19 15:00 UTC, inside the regular session.
    static let now = ISO8601DateFormatter().date(from: "2026-10-19T15:00:00Z")!

    static var expired: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-financialFreshnessExpired")
        #else
        false
        #endif
    }
}

enum MarketLoadState: Equatable {
    case loading
    case loaded
    case unavailable
}

#if DEBUG
enum MarketSearchFixture: String {
    case loading, empty, failure, cached, retry

    static var launch: MarketSearchFixture? {
        guard let index = CommandLine.arguments.firstIndex(of: "-marketSearchFixture"),
              let value = CommandLine.arguments.dropFirst(index + 1).first else { return nil }
        return MarketSearchFixture(rawValue: value)
    }

    var delay: Duration { self == .loading ? .seconds(60) : .milliseconds(80) }

    func matches(attempt: Int) throws -> [TickerMatch] {
        switch self {
        case .loading: return []
        case .empty: return []
        case .failure, .cached: throw MarketError.status(503)
        case .retry:
            if attempt == 0 { throw MarketError.status(503) }
            return Self.sampleMatches
        }
    }

    static let sampleMatches = [
        TickerMatch(symbol: "AAPL", shortname: "Apple Inc.", longname: "Apple Inc.", quoteType: "EQUITY", exchDisp: "NASDAQ"),
        TickerMatch(symbol: "MSFT", shortname: "Microsoft", longname: "Microsoft Corporation", quoteType: "EQUITY", exchDisp: "NASDAQ"),
    ]
}
#endif

enum MarketSearchRecovery {
    static func shouldKeepCachedResults(matchesQuery: String, query: String) -> Bool {
        matchesQuery == query
    }
}

nonisolated enum QuoteFreshness: Equatable, Sendable {
    /// App policy: a source timestamp this old during an expected-live window counts as delayed.
    static let liveWindow: TimeInterval = 20 * 60

    case live
    case closed
    case delayed(minutes: Int)
    case unavailable
    case unknown

    struct Notice: Equatable {
        let symbol: String
        let text: String
        let tint: Color
    }

    var notice: Notice? {
        switch self {
        case .delayed(let minutes): Notice(symbol: "clock.badge.exclamationmark", text: "Delayed \(minutes)m", tint: .orange)
        case .unavailable: Notice(symbol: "exclamationmark.triangle.fill", text: "Update failed", tint: .orange)
        case .unknown: Notice(symbol: "clock.badge.questionmark", text: "Source time unknown", tint: .secondary)
        case .live, .closed: nil
        }
    }
}

nonisolated enum QuoteFetchStatus: Equatable, Sendable {
    case ok
    case missing
    case failed
}

nonisolated struct MarketQuote: Sendable, Hashable, Identifiable {
    let symbol: String
    let name: String
    let type: String?
    let exchange: String?
    let currency: String
    private(set) var price: Double
    private(set) var change: Double
    private(set) var changePercent: Double
    let marketCap: Double?
    private(set) var extendedLabel: String?
    private(set) var extendedPercent: Double?
    let earnings: Date?
    let earningsEstimated: Bool
    /// Source timestamp of the selected price (pre, post, overnight or regular session), not a fetch time.
    private(set) var observedAt: Date?
    let regularPrice: Double

    var id: String { symbol }

    init?(_ value: YValue) {
        guard case .string(let symbol)? = value["symbol"], let rawPrice = value["regularMarketPrice"]?.raw else { return nil }
        let (currency, divisor) = MinorCurrency.major(value["currency"]?.text)
        let minor = { (key: String) in value[key]?.raw.map { $0 / divisor } }
        let price = rawPrice / divisor
        self.symbol = symbol
        self.currency = currency
        regularPrice = price
        name = value["longName"]?.text ?? value["shortName"]?.text ?? value["displayName"]?.text ?? symbol
        type = value["quoteType"]?.text
        exchange = value["fullExchangeName"]?.text
        marketCap = value["marketCap"]?.raw
        let state = value["marketState"]?.text ?? ""
        let regularTime = value["regularMarketTime"]?.raw ?? 0
        let pre = minor("preMarketPrice")
        let post = minor("postMarketPrice")
        if state.hasPrefix("PRE"), let pre, pre > 0,
           (value["preMarketTime"]?.raw ?? 0) >= regularTime {
            self.price = pre
            change = minor("preMarketChange") ?? pre - price
            changePercent = value["preMarketChangePercent"]?.raw ?? (pre - price) / price * 100
            extendedLabel = "Pre"
            extendedPercent = changePercent
            observedAt = value["preMarketTime"]?.date
        } else if state.hasPrefix("POST") || state == "CLOSED", let post, post > 0,
                  (value["postMarketTime"]?.raw ?? 0) >= regularTime {
            self.price = post
            change = minor("postMarketChange") ?? post - price
            changePercent = value["postMarketChangePercent"]?.raw ?? (post - price) / price * 100
            extendedLabel = "After"
            extendedPercent = changePercent
            observedAt = value["postMarketTime"]?.date
        } else {
            self.price = price
            change = minor("regularMarketChange") ?? 0
            changePercent = value["regularMarketChangePercent"]?.raw ?? 0
            extendedLabel = nil
            extendedPercent = nil
            observedAt = value["regularMarketTime"]?.date
        }
        earnings = value["earningsTimestampStart"]?.date ?? value["earningsTimestamp"]?.date
        if case .bool(true)? = value["isEarningsDateEstimate"] { earningsEstimated = true } else { earningsEstimated = false }
    }

    func applyingOvernight(_ trade: MarketTick?, now: Date = .now) -> MarketQuote {
        guard let trade, trade.symbol == symbol, currency == "USD", regularPrice > 0, trade.date > observedAt ?? .distantPast,
              now.timeIntervalSince(trade.date) < 8 * 3600 else { return self }
        var next = self
        next.price = trade.price
        next.change = trade.price - regularPrice
        next.changePercent = next.change / regularPrice * 100
        next.extendedLabel = "Overnight"
        next.extendedPercent = next.changePercent
        next.observedAt = trade.date
        return next
    }

    var extendedIcon: String { extendedLabel == "Pre" ? "sunrise" : extendedLabel == "Overnight" ? "moon.stars" : "moon" }
    var extendedDescription: String { extendedLabel == "Pre" ? "Premarket" : extendedLabel == "Overnight" ? "Overnight" : "After hours" }

    var kind: String {
        switch type {
        case "FUTURE": "Future"
        case "ETF": "ETF"
        case "CRYPTOCURRENCY": "Crypto"
        case "INDEX": "Index"
        case "CURRENCY": "FX"
        case "MUTUALFUND": "Fund"
        default: "Stock"
        }
    }

    var earningsTiming: String? {
        guard let earnings, !earningsEstimated else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let hour = calendar.component(.hour, from: earnings)
        return hour > 0 && hour < 10 ? "Before open" : hour >= 16 ? "After close" : nil
    }

    func freshness(at now: Date) -> QuoteFreshness {
        guard let observedAt else { return .unknown }
        guard expectsLiveTrading(at: now) else { return .closed }
        let age = now.timeIntervalSince(observedAt)
        if age < -60 { return .unknown }
        if age <= QuoteFreshness.liveWindow { return .live }
        return .delayed(minutes: Int(age / 60))
    }

    private func expectsLiveTrading(at now: Date) -> Bool {
        switch type {
        case "CRYPTOCURRENCY": return true
        case "FUTURE", "CURRENCY": return MarketClock.futuresScheduled(now)
        case "INDEX": return MarketClock.session(on: now)?.contains(now) ?? false
        case "MUTUALFUND": return false
        default:
            guard MarketClock.session(on: now) != nil else { return false }
            return (4..<20).contains(MarketClock.calendar.component(.hour, from: now))
        }
    }
}

@Observable final class MarketBoard {
    static let shared = MarketBoard()
    static let earningsWatch = [
        "AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "TSLA", "AVGO", "BRK-B", "LLY", "JPM", "V", "MA", "WMT", "XOM", "UNH", "ORCL",
        "COST", "HD", "PG", "JNJ", "NFLX", "ABBV", "BAC", "CRM", "AMD", "KO", "CVX", "MRK", "PEP", "TMO", "ADBE", "CSCO", "LIN", "ACN",
        "MCD", "WFC", "C", "ABT", "DIS", "INTU", "QCOM", "IBM", "GE", "CAT", "TXN", "AMGN", "VZ", "PM", "NOW", "ISRG", "GS", "MS", "AMAT",
        "MU", "LRCX", "KLAC", "INTC", "ADI", "PANW", "CRWD", "SNOW", "PLTR", "UBER", "SHOP", "ABNB", "COIN", "HOOD", "SBUX", "NKE", "BA",
        "LMT", "T", "PFE", "ARM", "SMCI", "DELL", "ANET", "MRVL", "TSM", "ASML", "FDX",
    ]

    private(set) var quotes: [String: MarketQuote] = [:]
    private(set) var sparks: [String: Spark] = [:]
    private(set) var quoteStatus: [String: QuoteFetchStatus] = [:]
    private var quotedAt: [String: Date] = [:]
    private var sparkedAt: [String: Date] = [:]
    @ObservationIgnored private let fetchQuotes: ([String]) async throws -> [MarketQuote]
    @ObservationIgnored private let fetchSparks: ([String]) async throws -> [String: Spark]
    @ObservationIgnored private let clock: () -> Date

    init(
        fetchQuotes: @escaping ([String]) async throws -> [MarketQuote] = { try await MarketClient.quotes($0) },
        fetchSparks: @escaping ([String]) async throws -> [String: Spark] = { try await MarketClient.sparks($0) },
        clock: @escaping () -> Date = { .now }
    ) {
        self.fetchQuotes = fetchQuotes
        self.fetchSparks = fetchSparks
        self.clock = clock
    }

    private func stale(_ stamp: Date?, _ limit: TimeInterval) -> Bool {
        stamp.map { clock().timeIntervalSince($0) > limit } ?? true
    }

    #if DEBUG
    func seedFreshnessPreview(now: Date) {
        func quote(_ symbol: String, _ name: String, price: Double, minutesAgo: Double?) -> MarketQuote? {
            let stamp = minutesAgo.map { ",\"regularMarketTime\":\(Int(now.addingTimeInterval(-$0 * 60).timeIntervalSince1970))" } ?? ""
            let json = #"{"symbol":"\#(symbol)","longName":"\#(name)","quoteType":"ETF","regularMarketPrice":\#(price)\#(stamp),"regularMarketChange":1.2,"regularMarketChangePercent":0.45,"marketState":"REGULAR"}"#
            return (try? JSONDecoder().decode(YValue.self, from: Data(json.utf8))).flatMap(MarketQuote.init)
        }
        let fresh: [(String, String, Double, Double?)] = [
            ("SPY", "SPDR S&P 500", 681.2, 45), ("^VIX", "CBOE Volatility Index", 15.2, 2), ("NVDA", "NVIDIA", 182.4, nil),
        ]
        for (symbol, name, price, minutes) in fresh {
            if let item = quote(symbol, name, price: price, minutesAgo: minutes) { quotes[symbol] = item; quoteStatus[symbol] = .ok }
        }
        if let qqq = quote("QQQ", "Invesco QQQ Trust", price: 612.4, minutesAgo: 10) {
            quotes[qqq.symbol] = qqq
            quoteStatus["QQQ"] = .failed
        }
        quoteStatus["IWM"] = .failed
    }
    #endif

    /// Freshness of the cached quote for a symbol, or nil when the board has never been asked for it.
    func freshness(of symbol: String, now: Date = .now) -> QuoteFreshness? {
        switch quoteStatus[symbol] {
        case .failed?, .missing?: return .unavailable
        case .ok?, nil: return quotes[symbol]?.freshness(at: now)
        }
    }

    func refresh(quotes wanted: [String], sparks sparkWanted: [String]) async {
        let needQuotes = Array(Set(wanted.filter { stale(quotedAt[$0], 25) }))
        let needSparks = Array(Set(sparkWanted.filter { stale(sparkedAt[$0], 90) }).prefix(20))
        let quoteResult: Result<[MarketQuote], Error>
        if needQuotes.isEmpty {
            quoteResult = .success([])
        } else {
            do { quoteResult = .success(try await fetchQuotes(needQuotes)) } catch { quoteResult = .failure(error) }
        }
        var s: [String: Spark]?
        if !needSparks.isEmpty { s = try? await fetchSparks(needSparks) }
        guard !Task.isCancelled else { return }
        switch quoteResult {
        case .success(let found):
            let returned = Set(found.map(\.symbol))
            let stamp = clock()
            for quote in found { quotes[quote.symbol] = quote; quotedAt[quote.symbol] = stamp; quoteStatus[quote.symbol] = .ok }
            for symbol in needQuotes where !returned.contains(symbol) { quoteStatus[symbol] = .missing }
        case .failure:
            for symbol in needQuotes { quoteStatus[symbol] = .failed }
        }
        for (symbol, spark) in s ?? [:] { sparks[symbol] = spark; sparkedAt[symbol] = clock() }
    }

    var upcomingEarnings: [MarketQuote] {
        let start = Calendar.current.startOfDay(for: .now)
        let end = start.addingTimeInterval(45 * 86_400)
        return quotes.values.filter { quote in
            guard let date = quote.earnings else { return false }
            return date >= start && date < end
        }
        .sorted { ($0.earnings ?? .distantFuture, $0.symbol) < ($1.earnings ?? .distantFuture, $1.symbol) }
    }
}

struct MarketSearchSheet: View, Equatable {
    private static let watchlistPreviewCount = 3
    private static let financeSymbols: [(String, String)] = [("^KS11", "KOSPI"), ("^N225", "NIKKEI"), ("^HSI", "HANG SENG"), ("^GDAXI", "DAX"), ("^FTSE", "FTSE"),
                                                              ("^TNX", "US 10Y"), ("DX-Y.NYB", "DOLLAR"), ("JPY=X", "USD/JPY"), ("CL=F", "WTI"), ("GC=F", "GOLD")]
    @Binding var detent: DockDetent
    let onSelect: (String) -> Void
    var onAsk: (String) -> Void = { _ in }
    @State private var query = ""
    @State private var matches: [TickerMatch] = []
    @State private var matchesQuery = ""
    @State private var loading = false
    @State private var searchFailed = false
    @State private var searchRetry = 0
    @State private var recents = MarketRecents.all
    @State private var showAllRecents = false
    @State private var showAllWatchlist = false
    @State private var board = MarketBoard.shared
    @State private var screeners = ScreenerStore.shared
    @State private var screenerPreset: ScreenerPreset?
    @State private var watchlist = Watchlist.shared
    @State private var selection: TextSelection?
    @FocusState private var searching: Bool
    @Environment(\.scenePhase) private var phase

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The dock re-renders on every frame of a drag; its closures never compare equal, so without this the whole overview rebuilt each frame.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.detent == rhs.detent }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, MarketDock.barInset)
                .padding(.bottom, MarketDock.barInset)
            if trimmed.isEmpty {
                overview
            } else {
                suggestions
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: trimmed.isEmpty)
        #if DEBUG
        .onAppear {
            if let index = CommandLine.arguments.firstIndex(of: "-searchQuery"), let text = CommandLine.arguments.dropFirst(index + 1).first {
                query = text
                if MarketSearchFixture.launch == .cached {
                    matches = MarketSearchFixture.sampleMatches
                    matchesQuery = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        #endif
        // The keyboard covers most of the dock, so search at full height, and drop focus when it is pulled back down.
        .onChange(of: searching) { _, focused in
            if focused {
                detent = .large
                selectQuery()
            }
        }
        .onChange(of: detent) { _, value in
            if value != .large { searching = false }
        }
        .task(id: "\(trimmed):\(searchRetry)") {
            let text = trimmed
            if !MarketSearchRecovery.shouldKeepCachedResults(matchesQuery: matchesQuery, query: text) {
                matches = []
                matchesQuery = ""
            }
            searchFailed = false
            loading = !text.isEmpty
            guard !text.isEmpty else { return }
#if DEBUG
            let fixture = MarketSearchFixture.launch
#endif
            defer { if !Task.isCancelled { loading = false } }
#if DEBUG
            do { try await Task.sleep(for: fixture?.delay ?? .milliseconds(250)) } catch { return }
#else
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
#endif
            guard !Task.isCancelled else { return }
            do {
                let found: [TickerMatch]
#if DEBUG
                if let fixture { found = try fixture.matches(attempt: searchRetry) }
                else { found = try await MarketClient.search(text) }
#else
                found = try await MarketClient.search(text)
#endif
                guard !Task.isCancelled else { return }
                matches = found
                matchesQuery = text
                let symbols = found.map(\.symbol)
                await board.refresh(quotes: symbols, sparks: symbols)
            } catch {
                guard !Task.isCancelled else { return }
                searchFailed = true
            }
        }
        .sheet(item: $screenerPreset) { preset in
            ScreenerSheet(preset: preset, store: screeners) { choose($0) }
        }
        .task(id: phase == .active) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                if trimmed.isEmpty {
                    let pinned = MarketRecents.popular + recents + Self.financeSymbols.map(\.0) + watchlist.symbols
                    async let quotes: Void = board.refresh(quotes: pinned + MarketBoard.earningsWatch, sparks: pinned)
                    async let screeners: Void = refreshScreeners()
                    _ = await (quotes, screeners)
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private var searchBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                searchField
                askButton
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search markets", text: $query, selection: $selection)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searching)
                .onSubmit {
                    if let command = TerminalCommand.parse(query) { choose(command.token) }
                    else { choose(MarketSearchSelection.symbol(query: query, matchesQuery: matchesQuery, firstMatch: matches.first?.symbol)) }
                }
            if loading {
                ProgressView().controlSize(.small)
            }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .contentShape(.capsule)
        .onTapGesture { searching = true }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// Focusing a field that already holds a query selects it, so typing replaces it. Deferred a tick so the tap's own caret placement doesn't override it.
    private func selectQuery() {
        guard !query.isEmpty else { return }
        Task { @MainActor in
            await Task.yield()
            guard searching, !query.isEmpty else { return }
            selection = TextSelection(range: query.startIndex..<query.endIndex)
        }
    }

    /// Opens the Ask sheet. Anything typed in the field is sent as the first question.
    private var askButton: some View {
        Button {
            let prompt = trimmed
            query = ""
            searching = false
            detent = .peek
            onAsk(prompt)
        } label: {
            Image(systemName: "message")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.wireAccent)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(trimmed.isEmpty ? "Ask the markets" : "Ask the markets about \(trimmed)")
    }

    private var suggestions: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let command = TerminalCommand.parse(trimmed) {
                    Button { choose(command.token) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "terminal").foregroundStyle(Color.wireAccent)
                            Text(command.title).font(.body.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Image(systemName: "return").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 20)
                        .frame(minHeight: 52)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 20)
                }
                ForEach(TickerMatch.grouped(matches), id: \.first.id) { group in
                    Button { choose(group.first.symbol) } label: {
                        MarketRow(symbol: group.first.symbol, title: group.first.title,
                                  tag: [group.first.kind, group.first.marketLabel].filter { !$0.isEmpty }.joined(separator: " · "),
                                  quote: board.quotes[group.first.symbol], spark: board.sparks[group.first.symbol])
                    }
                    .buttonStyle(.plain)
                    if !group.others.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(group.others) { listing in
                                    Button { choose(listing.symbol) } label: {
                                        HStack(spacing: 4) {
                                            Text(listing.symbol).font(.caption.weight(.semibold).monospaced())
                                            if !listing.marketLabel.isEmpty { Text(listing.marketLabel).font(.caption2).foregroundStyle(.secondary) }
                                            if let quote = board.quotes[listing.symbol] {
                                                Text(QuoteFormat.percent(quote.changePercent)).font(.caption2.weight(.semibold)).foregroundStyle(QuoteFormat.color(quote.changePercent))
                                            }
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(.fill.tertiary, in: .capsule)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(listing.symbol), \(listing.marketLabel)")
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .scrollIndicators(.hidden)
                        .padding(.bottom, 10)
                    }
                    Divider().padding(.leading, 20)
                }
                if searchFailed && !matches.isEmpty {
                    HStack(spacing: 8) {
                        Text("Showing cached matches")
                        Button("Retry") { searchRetry += 1 }.foregroundStyle(Color.wireAccent)
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
                }
                if matches.isEmpty && !loading && TerminalCommand.parse(trimmed) == nil {
                    VStack(spacing: 10) {
                        if searchFailed {
                            Label("Search unavailable", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                            Button("Try again") { searchRetry += 1 }
                                .buttonStyle(.bordered).tint(Color.wireAccent)
                        } else if matchesQuery == trimmed {
                            Text("No matches found")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("Press Search to open \(trimmed.uppercased())")
                                .font(.subheadline).foregroundStyle(.tertiary)
                        } else {
                            Text("Press Search to open \(trimmed.uppercased())")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 32)
                }
            }
            .animation(.easeOut(duration: 0.18), value: matches)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !recents.isEmpty && searching { recentSection }
                section("Stocks") {
                    indices
                }
                movers
                watchlistSection
                section("Global & macro") {
                    financeCards
                }
                section("Data") {
                    TerminalFunctionsRow(onSelect: choose, excluding: ["INST", "FLOW", "PTR"])
                }
                section("Institutions") {
                    TerminalFunctionsRow(onSelect: choose, codes: ["INST", "FLOW", "PTR"])
                }
                section("Discover") {
                    Button { onSelect(TerminalExploreView.token) } label: {
                        HStack(spacing: 12) {
                            ToolIcon(symbol: "square.grid.2x2.fill", tint: Color.wireAccent, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("All data tools").font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text("Search \(TerminalFunction.all.count) tools and pin favorites")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .contentShape(.rect(cornerRadius: 18))
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                    }
                    .buttonStyle(PressSpringStyle())
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("explore-data-tools")
                }
                if !recents.isEmpty && !searching { recentSection }
                earnings
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDisabled(detent == .peek)
        .scrollDismissesKeyboard(.interactively)
    }

    private var recentSection: some View {
        let shown = showAllRecents ? recents : Array(recents.prefix(3))
        return section("Recent", accessory: {
            if recents.count > 3 {
                Button(showAllRecents ? "Show less" : "Show more") {
                    withAnimation(.easeOut(duration: 0.2)) { showAllRecents.toggle() }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Color.wireAccent)
            }
        }) {
            ForEach(shown, id: \.self) { symbol in
                row(symbol)
                    .contextMenu {
                        Button("Remove from Recent", systemImage: "minus.circle", role: .destructive) {
                            MarketRecents.remove(symbol)
                            withAnimation(.easeOut(duration: 0.2)) { recents = MarketRecents.all }
                        }
                    }
            }
        }
    }

    private var indices: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(MarketRecents.popular, id: \.self) { symbol in
                        Button { choose(symbol) } label: {
                            IndexCard(symbol: symbol, quote: board.quotes[symbol], spark: board.sparks[symbol])
                        }
                        .buttonStyle(PressSpringStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var financeCards: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(Self.financeSymbols, id: \.0) { symbol, label in
                        Button { choose(symbol) } label: {
                            IndexCard(symbol: symbol, quote: board.quotes[symbol], spark: board.sparks[symbol], label: label)
                        }
                        .buttonStyle(PressSpringStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private var watchlistSection: some View {
        section("Watchlist", accessory: {
            if watchlist.symbols.count > Self.watchlistPreviewCount {
                Button(showAllWatchlist ? "Show less" : "Show more") {
                    withAnimation(.easeOut(duration: 0.2)) { showAllWatchlist.toggle() }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Color.wireAccent)
            }
        }) {
            watchlistRows
        }
    }

    private var watchlistRows: some View {
        let order = Dictionary(watchlist.symbols.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let symbols = watchlist.symbols.sorted { a, b in
            switch (board.quotes[a]?.changePercent, board.quotes[b]?.changePercent) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: order[a, default: 0] < order[b, default: 0]
            }
        }
        return Group {
            if symbols.isEmpty {
                Text("Star a quote to add it here.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                ForEach(showAllWatchlist ? symbols : Array(symbols.prefix(Self.watchlistPreviewCount)), id: \.self) { symbol in
                    row(symbol)
                }
            }
        }
    }

    private func refreshScreeners() async {
        for preset in screeners.pinnedPresets { Task { await screeners.refresh(preset) } }
    }

    private var movers: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(screeners.pinnedPresets) { preset in
                let rows = screeners.rows(preset)
                let state = screeners.state(preset)
                section(preset.title, accessory: {
                    Button("See all") { screenerPreset = preset }
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.wireAccent)
                }) {
                    if !rows.isEmpty {
                        MoverPillRows(pills: rows.prefix(10).map { MoverPill($0, metric: preset.metric) }, onSelect: choose)
                        if state == .unavailable {
                            HStack(spacing: 6) {
                                Text("Showing cached results")
                                Button("Retry") { Task { await screeners.refresh(preset, force: true) } }.foregroundStyle(Color.wireAccent)
                            }
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                        } else if screeners.usesEstimatedVolatility(preset) {
                            Text("Some IV estimated from last trades while options are closed")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                        } else if preset.isImpliedVolatility, let progress = screeners.volatilityProgress {
                            Text("Checking options \(progress.done) of \(progress.total)")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                        }
                    } else if state == .loading || (preset.isImpliedVolatility && screeners.volatilityProgress != nil) {
                        MoverPillRows(pills: (0..<8).map { MoverPill(symbol: "XXX\($0)", changePercent: 0.0) }, onSelect: { _ in })
                            .redacted(reason: .placeholder).allowsHitTesting(false)
                    } else {
                        HStack(spacing: 8) {
                            Text(state == .loaded ? "Nothing to show" : "\(preset.title) unavailable").font(.subheadline).foregroundStyle(.secondary)
                            Button("Try again") { Task { await screeners.refresh(preset, force: true) } }
                                .font(.subheadline).foregroundStyle(Color.wireAccent)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                    }
                }
            }
            Button { screenerPreset = ScreenerPreset.all[0] } label: {
                Label("All screeners", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).frame(height: 40).contentShape(.capsule)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(PressSpringStyle())
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var earnings: some View {
        let upcoming = board.upcomingEarnings.filter { Set(recents + MarketBoard.earningsWatch).contains($0.symbol) }.prefix(8)
        if !upcoming.isEmpty {
            section("Upcoming earnings") {
                ForEach(Array(upcoming)) { quote in
                    Button { choose(quote.symbol) } label: { EarningsRow(quote: quote) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ symbol: String, quote: MarketQuote? = nil) -> some View {
        let quote = quote ?? board.quotes[symbol]
        return Button { choose(symbol) } label: {
            MarketRow(symbol: symbol, title: quote?.name ?? " ", tag: nil, quote: quote, spark: board.sparks[symbol])
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, accessory: { EmptyView() }, content: content)
    }

    private func section<Accessory: View, Content: View>(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 2)
            content()
        }
    }

    private func choose(_ symbol: String) {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = trimmed.hasPrefix("data:") ? trimmed : trimmed.uppercased()
        guard !symbol.isEmpty else { return }
        if DataRoute(token: symbol) == nil {
            MarketRecents.add(symbol)
            recents = MarketRecents.all
        }
        searching = false
        onSelect(symbol)
    }
}

struct MarketRow: View {
    let symbol: String
    let title: String
    let tag: String?
    let quote: MarketQuote?
    let spark: Spark?
    var inset: CGFloat = 20

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.trimmingCharacters(in: .whitespaces).isEmpty ? symbol : title)
                    .font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(symbol).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let quote, quote.extendedLabel != nil {
                        Image(systemName: quote.extendedIcon)
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel(quote.extendedDescription)
                    }
                    if let tag, !tag.isEmpty {
                        Text(tag).font(.caption2.weight(.medium)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SparkLine(spark: spark, fallbackUp: (quote?.changePercent ?? 0) >= 0)
                .frame(width: 54, height: 26)
            VStack(alignment: .trailing, spacing: 3) {
                Text(quote.map { QuoteFormat.price($0.price) } ?? "—")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .numericTextTransition(value: quote?.price)
                ChangeBadge(percent: quote?.changePercent)
            }
            .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.horizontal, inset)
        .frame(minHeight: 60)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        guard let quote else { return "\(symbol), \(title)" }
        return "\(symbol), \(title), \(quote.extendedLabel ?? "Regular"), \(QuoteFormat.price(quote.price)), \(QuoteFormat.percent(quote.changePercent))"
    }
}

struct ChangeBadge: View {
    let percent: Double?

    var body: some View {
        Text(percent.map(QuoteFormat.percent) ?? "—")
            .numericTextTransition(value: percent)
            .font(.caption.weight(.bold)).monospacedDigit()
            .foregroundStyle(percent == nil ? Color.secondary : .white)
            .padding(.horizontal, 7)
            .frame(minWidth: 64, minHeight: 20, alignment: .trailing)
            .background((percent.map(QuoteFormat.color) ?? .secondary).opacity(percent == nil || percent == 0 ? 0.18 : 0.9), in: .rect(cornerRadius: 6))
    }
}

struct SparkLine: View {
    let spark: Spark?
    var fallbackUp = true

    var body: some View {
        Canvas { context, size in
            guard let spark, let last = spark.points.last else { return }
            let values = spark.points + (spark.baseline.map { [$0] } ?? [])
            guard let low = values.min(), let high = values.max() else { return }
            let span = max(high - low, abs(high) * 0.0005, .ulpOfOne)
            let y = { (value: Double) in size.height - 1 - CGFloat((value - low) / span) * (size.height - 2) }
            let step = size.width / CGFloat(max(spark.points.count - 1, 1))
            if let baseline = spark.baseline {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(baseline)))
                line.addLine(to: CGPoint(x: size.width, y: y(baseline)))
                context.stroke(line, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
            }
            var path = Path()
            for (index, value) in spark.points.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: y(value))
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            let up = spark.baseline.map { last >= $0 } ?? fallbackUp
            context.stroke(path, with: .color(up ? .green : .red), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct IndexCard: View {
    let symbol: String
    let quote: MarketQuote?
    let spark: Spark?
    var label: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(label ?? symbol).font(.footnote.weight(.bold).monospaced()).lineLimit(1)
                    if let quote, quote.extendedLabel != nil {
                        Image(systemName: quote.extendedIcon)
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel(quote.extendedDescription)
                    }
                }
                Text(quote?.name ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            SparkLine(spark: spark, fallbackUp: (quote?.changePercent ?? 0) >= 0).frame(height: 24)
            HStack(alignment: .firstTextBaseline) {
                Text(quote.map { QuoteFormat.price($0.price) } ?? "—").font(.subheadline.weight(.semibold))
                    .numericTextTransition(value: quote?.price)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Text(quote.map { QuoteFormat.percent($0.changePercent) } ?? "")
                    .numericTextTransition(value: quote?.changePercent)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(QuoteFormat.color(quote?.changePercent ?? 0))
                    .fixedSize()
            }
            .monospacedDigit()
            .lineLimit(1)
        }
        .padding(12)
        .frame(width: 142, alignment: .leading)
        .contentShape(.rect(cornerRadius: 18))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quote.map { "\(symbol), \($0.name), \(QuoteFormat.price($0.price)), \(QuoteFormat.percent($0.changePercent))" } ?? symbol)
    }
}

private struct EarningsRow: View {
    let quote: MarketQuote

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(quote.earnings?.formatted(.dateTime.month(.abbreviated)).uppercased() ?? "")
                    .font(.caption2.weight(.bold)).foregroundStyle(.red)
                Text(quote.earnings?.formatted(.dateTime.day()) ?? "")
                    .font(.title3.weight(.semibold)).monospacedDigit()
            }
            .frame(width: 40, height: 42)
            .background(.fill.tertiary, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.symbol).font(.body.weight(.semibold).monospaced())
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(QuoteFormat.price(quote.price)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .numericTextTransition(value: quote.price)
                ChangeBadge(percent: quote.changePercent)
            }
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 60)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(quote.name) reports \(detail)")
    }

    private var detail: String {
        guard let date = quote.earnings else { return quote.name }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: date)).day ?? 0
        let when = days == 0 ? "Today" : days == 1 ? "Tomorrow" : "In \(days) days"
        return [when, quote.earningsTiming ?? (quote.earningsEstimated ? "Estimated" : nil)].compactMap { $0 }.joined(separator: " · ")
    }
}
