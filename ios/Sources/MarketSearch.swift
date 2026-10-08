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

nonisolated enum MoverList: String, CaseIterable, Identifiable, Sendable {
    case gainers = "day_gainers", losers = "day_losers", active = "most_actives"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .gainers: "Gainers"
        case .losers: "Losers"
        case .active: "Active"
        }
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

nonisolated struct MarketQuote: Sendable, Hashable, Identifiable {
    let symbol: String
    let name: String
    let type: String?
    let exchange: String?
    let currency: String
    let price: Double
    let change: Double
    let changePercent: Double
    let marketCap: Double?
    let extendedLabel: String?
    let extendedPercent: Double?
    let earnings: Date?
    let earningsEstimated: Bool

    var id: String { symbol }

    init?(_ value: YValue) {
        guard case .string(let symbol)? = value["symbol"], let rawPrice = value["regularMarketPrice"]?.raw else { return nil }
        let (currency, divisor) = MinorCurrency.major(value["currency"]?.text)
        let minor = { (key: String) in value[key]?.raw.map { $0 / divisor } }
        let price = rawPrice / divisor
        self.symbol = symbol
        self.currency = currency
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
        } else if state.hasPrefix("POST") || state == "CLOSED", let post, post > 0,
                  (value["postMarketTime"]?.raw ?? 0) >= regularTime {
            self.price = post
            change = minor("postMarketChange") ?? post - price
            changePercent = value["postMarketChangePercent"]?.raw ?? (post - price) / price * 100
            extendedLabel = "After"
            extendedPercent = changePercent
        } else {
            self.price = price
            change = minor("regularMarketChange") ?? 0
            changePercent = value["regularMarketChangePercent"]?.raw ?? 0
            extendedLabel = nil
            extendedPercent = nil
        }
        earnings = value["earningsTimestampStart"]?.date ?? value["earningsTimestamp"]?.date
        if case .bool(true)? = value["isEarningsDateEstimate"] { earningsEstimated = true } else { earningsEstimated = false }
    }

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
    private(set) var movers: [MoverList: [MarketQuote]] = [:]
    private(set) var moversState = Dictionary(uniqueKeysWithValues: MoverList.allCases.map { ($0, MarketLoadState.loading) })
    private var quotedAt: [String: Date] = [:]
    private var sparkedAt: [String: Date] = [:]
    private var moversAt: [MoverList: Date] = [:]

    private func stale(_ stamp: Date?, _ limit: TimeInterval) -> Bool {
        stamp.map { Date.now.timeIntervalSince($0) > limit } ?? true
    }

    func refresh(quotes wanted: [String], sparks sparkWanted: [String]) async {
        let needQuotes = Array(Set(wanted.filter { stale(quotedAt[$0], 25) }))
        let needSparks = Array(Set(sparkWanted.filter { stale(sparkedAt[$0], 90) }).prefix(20))
        async let foundQuotes = try? MarketClient.quotes(needQuotes)
        async let foundSparks = try? MarketClient.sparks(needSparks)
        let (q, s) = await (foundQuotes, foundSparks)
        guard !Task.isCancelled else { return }
        for quote in q ?? [] { quotes[quote.symbol] = quote; quotedAt[quote.symbol] = .now }
        for (symbol, spark) in s ?? [:] { sparks[symbol] = spark; sparkedAt[symbol] = .now }
    }

    func refresh(movers list: MoverList, force: Bool = false) async {
        guard force || stale(moversAt[list], 60) else { return }
        moversState[list] = .loading
        let found: [MarketQuote]
        do {
            found = try await MarketClient.movers(list)
            guard !Task.isCancelled else { return }
            movers[list] = found
            moversAt[list] = .now
            moversState[list] = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            moversState[list] = .unavailable
            return
        }
        for quote in found { quotes[quote.symbol] = quote; quotedAt[quote.symbol] = .now }
        let symbols = found.prefix(6).map(\.symbol).filter { stale(sparkedAt[$0], 90) }
        guard !symbols.isEmpty, let lines = try? await MarketClient.sparks(symbols) else { return }
        for (symbol, spark) in lines { sparks[symbol] = spark; sparkedAt[symbol] = .now }
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

struct MarketSearchSheet: View {
    @Binding var detent: DockDetent
    let onSelect: (String) -> Void
    @State private var query = ""
    @State private var matches: [TickerMatch] = []
    @State private var matchesQuery = ""
    @State private var loading = false
    @State private var searchFailed = false
    @State private var searchRetry = 0
    @State private var recents = MarketRecents.all
    @State private var moverList = MoverList(rawValue: UserDefaults.standard.string(forKey: "marketMovers") ?? "") ?? .gainers
    @State private var board = MarketBoard.shared
    @FocusState private var searching: Bool
    @Environment(\.scenePhase) private var phase

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

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
            if focused { detent = .large }
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
        .task(id: phase == .active) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                if trimmed.isEmpty {
                    let pinned = MarketRecents.popular + recents
                    async let quotes: Void = board.refresh(quotes: pinned + MarketBoard.earningsWatch, sparks: pinned)
                    async let movers: Void = board.refresh(movers: moverList)
                    _ = await (quotes, movers)
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .task(id: moverList) {
            UserDefaults.standard.set(moverList.rawValue, forKey: "marketMovers")
            await board.refresh(movers: moverList)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search markets", text: $query)
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
        .glassEffect(.regular.interactive(), in: .capsule)
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
                                  tag: [group.first.kind, group.first.exchDisp].compactMap { $0 }.joined(separator: " · "),
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
                                            if let exchange = listing.exchDisp { Text(exchange).font(.caption2).foregroundStyle(.secondary) }
                                            if let quote = board.quotes[listing.symbol] {
                                                Text(QuoteFormat.percent(quote.changePercent)).font(.caption2.weight(.semibold)).foregroundStyle(QuoteFormat.color(quote.changePercent))
                                            }
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(.fill.tertiary, in: .capsule)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(listing.symbol), \(listing.exchDisp ?? "")")
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
                section("Stocks") {
                    indices
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
                if !recents.isEmpty {
                    section("Recent") {
                        ForEach(recents, id: \.self) { symbol in
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
                movers
                earnings
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDisabled(detent == .peek)
        .scrollDismissesKeyboard(.interactively)
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

    private var movers: some View {
        let list = board.movers[moverList] ?? []
        return section("Movers", accessory: {
            Picker("Movers", selection: $moverList) {
                ForEach(MoverList.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
        }) {
            if list.isEmpty && board.moversState[moverList] == .loading {
                ForEach(0..<4, id: \.self) { _ in
                    MarketRow(symbol: "XXXX", title: "Loading market movers", tag: nil, quote: nil, spark: nil).redacted(reason: .placeholder)
                }
            } else if list.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(board.moversState[moverList] == .loaded ? "No market movers available" : "Market movers unavailable")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await board.refresh(movers: moverList, force: true) }
                    }
                    .buttonStyle(.bordered).tint(Color.wireAccent)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                if board.moversState[moverList] == .loading || board.moversState[moverList] == .unavailable {
                    HStack(spacing: 6) {
                        Text(board.moversState[moverList] == .loading ? "Refreshing cached movers" : "Showing cached movers")
                        if board.moversState[moverList] == .unavailable {
                            Button("Retry") { Task { await board.refresh(movers: moverList, force: true) } }
                                .foregroundStyle(Color.wireAccent)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                }
                ForEach(list.prefix(6)) { quote in row(quote.symbol, quote: quote) }
            }
        }
        .animation(.easeOut(duration: 0.2), value: list)
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
                    if let label = quote?.extendedLabel {
                        Image(systemName: label == "Pre" ? "sunrise" : "moon")
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel(label == "Pre" ? "Premarket" : "After hours")
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
                ChangeBadge(percent: quote?.changePercent)
            }
            .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.horizontal, inset)
        .frame(minHeight: 60)
        .contentShape(.rect)
        .contentTransition(.numericText())
        .animation(.easeOut(duration: 0.2), value: quote)
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
                    if let label = quote?.extendedLabel {
                        Image(systemName: label == "Pre" ? "sunrise" : "moon")
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel(label == "Pre" ? "Premarket" : "After hours")
                    }
                }
                Text(quote?.name ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            SparkLine(spark: spark, fallbackUp: (quote?.changePercent ?? 0) >= 0).frame(height: 24)
            HStack(alignment: .firstTextBaseline) {
                Text(quote.map { QuoteFormat.price($0.price) } ?? "—").font(.subheadline.weight(.semibold))
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Text(quote.map { QuoteFormat.percent($0.changePercent) } ?? "")
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
        .contentTransition(.numericText())
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
