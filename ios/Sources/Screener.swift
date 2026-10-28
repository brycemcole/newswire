import SwiftUI

nonisolated enum ScreenerFilter: Hashable, Sendable {
    case usListed
    case minPrice(Double)
    case minAverageVolume(Double)
    case marketCap(min: Double?, max: Double?)
    case minDividendYield(Double)

    var operand: [String: Any] {
        switch self {
        case .usListed: ["operator": "eq", "operands": ["region", "us"]]
        case .minPrice(let value): ["operator": "gt", "operands": ["intradayprice", value]]
        case .minAverageVolume(let value): ["operator": "gt", "operands": ["avgdailyvol3m", value]]
        case .minDividendYield(let value): ["operator": "gt", "operands": ["forward_dividend_yield", value]]
        case .marketCap(let low, let high):
            switch (low, high) {
            case let (low?, high?): ["operator": "btwn", "operands": ["intradaymarketcap", low, high]]
            case let (low?, nil): ["operator": "gt", "operands": ["intradaymarketcap", low]]
            case let (nil, high?): ["operator": "lt", "operands": ["intradaymarketcap", high]]
            case (nil, nil): ["operator": "gt", "operands": ["intradaymarketcap", 0]]
            }
        }
    }

    var label: String {
        switch self {
        case .usListed: "US listed"
        case .minPrice(let value): "Price > $\(value.formatted())"
        case .minAverageVolume(let value): "Avg volume > \(DataText.compact(value))"
        case .minDividendYield(let value): "Yield > \(value.formatted())%"
        case .marketCap(let low, let high):
            switch (low, high) {
            case let (low?, high?): "Cap $\(DataText.compact(low))–$\(DataText.compact(high))"
            case let (low?, nil): "Cap > $\(DataText.compact(low))"
            case let (nil, high?): "Cap < $\(DataText.compact(high))"
            case (nil, nil): "Any cap"
            }
        }
    }
}

nonisolated enum ScreenerMetric: Sendable {
    case change, volume, relativeVolume, marketCap, impliedVolatility, yearChange, dividendYield

    var header: String {
        switch self {
        case .change: "Change"
        case .volume: "Volume"
        case .relativeVolume: "Rel. volume"
        case .marketCap: "Market cap"
        case .impliedVolatility: "IV"
        case .yearChange: "1Y"
        case .dividendYield: "Yield"
        }
    }
}

nonisolated struct ScreenerPreset: Identifiable, Hashable, Sendable {
    enum Ranking: Hashable, Sendable {
        case fetched
        case relativeVolume(minimum: Double)
        case change(descending: Bool)
        case impliedVolatility(universe: Int)
    }

    enum Source: Hashable, Sendable {
        case screener
        case crypto
        case symbols([String])
    }

    let id: String
    let title: String
    let symbol: String
    let blurb: String
    let filters: [ScreenerFilter]
    let sortField: String
    let descending: Bool
    let ranking: Ranking
    let metric: ScreenerMetric
    var size = 50
    var source = Source.screener

    var criteria: String {
        switch source {
        case .screener: filters.map(\.label).joined(separator: " · ")
        case .crypto: "US-listed crypto pairs"
        case .symbols(let symbols): symbols.map { $0.replacingOccurrences(of: "=F", with: "") }.joined(separator: " · ")
        }
    }
    var isImpliedVolatility: Bool { if case .impliedVolatility = ranking { true } else { false } }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func requestBody() -> [String: Any] {
        [
            "size": isImpliedVolatility ? 60 : size, "offset": 0,
            "sortField": sortField, "sortType": descending ? "DESC" : "ASC",
            "quoteType": "EQUITY", "userId": "", "userIdType": "guid",
            "query": ["operator": "AND", "operands": filters.map(\.operand)],
        ]
    }

    private static let liquid: [ScreenerFilter] = [.usListed, .minPrice(5), .minAverageVolume(500_000)]

    private static let stocks: [ScreenerPreset] = [
        ScreenerPreset(id: "iv", title: "Highest implied volatility", symbol: "waveform.path.ecg",
                       blurb: "At-the-money IV, about a month out, across the most actively traded optionable US stocks.",
                       filters: [.usListed, .minPrice(3), .minAverageVolume(1_000_000)], sortField: "dayvolume", descending: true,
                       ranking: .impliedVolatility(universe: 40), metric: .impliedVolatility),
        ScreenerPreset(id: "gainers", title: "Top gainers", symbol: "arrow.up.right",
                       blurb: "Biggest percentage gains today.", filters: liquid, sortField: "percentchange", descending: true,
                       ranking: .fetched, metric: .change),
        ScreenerPreset(id: "losers", title: "Top losers", symbol: "arrow.down.right",
                       blurb: "Biggest percentage declines today.", filters: liquid, sortField: "percentchange", descending: false,
                       ranking: .fetched, metric: .change),
        ScreenerPreset(id: "active", title: "Most active", symbol: "chart.bar.fill",
                       blurb: "Highest share volume today.", filters: [.usListed, .minPrice(1)], sortField: "dayvolume", descending: true,
                       ranking: .fetched, metric: .volume),
        ScreenerPreset(id: "unusual", title: "Unusual volume", symbol: "bolt.fill",
                       blurb: "Trading at least 1.5× its three-month average volume.",
                       filters: [.usListed, .minPrice(2), .minAverageVolume(500_000)], sortField: "dayvolume", descending: true,
                       ranking: .relativeVolume(minimum: 1.5), metric: .relativeVolume, size: 100),
        ScreenerPreset(id: "yearly", title: "52-week climbers", symbol: "chart.line.uptrend.xyaxis",
                       blurb: "Largest one-year gains among companies over $2B.",
                       filters: [.usListed, .minPrice(5), .marketCap(min: 2e9, max: nil)], sortField: "fiftytwowkpercentchange", descending: true,
                       ranking: .fetched, metric: .yearChange),
        ScreenerPreset(id: "smallcap", title: "Small-cap gainers", symbol: "sparkle",
                       blurb: "Today's top gainers between $300M and $2B.",
                       filters: [.usListed, .minPrice(2), .minAverageVolume(300_000), .marketCap(min: 3e8, max: 2e9)],
                       sortField: "percentchange", descending: true, ranking: .fetched, metric: .change),
        ScreenerPreset(id: "megacap", title: "Mega-cap movers", symbol: "building.columns",
                       blurb: "Biggest gainers among companies over $200B.",
                       filters: [.usListed, .marketCap(min: 2e11, max: nil)], sortField: "percentchange", descending: true,
                       ranking: .fetched, metric: .change),
        ScreenerPreset(id: "decliners", title: "52-week decliners", symbol: "chart.line.downtrend.xyaxis",
                       blurb: "Largest one-year declines among companies over $2B.",
                       filters: [.usListed, .minPrice(5), .marketCap(min: 2e9, max: nil)], sortField: "fiftytwowkpercentchange", descending: false,
                       ranking: .fetched, metric: .yearChange),
        ScreenerPreset(id: "dividend", title: "High dividend yield", symbol: "dollarsign.arrow.circlepath",
                       blurb: "Highest forward dividend yields among companies over $2B.",
                       filters: [.usListed, .minPrice(5), .marketCap(min: 2e9, max: nil), .minDividendYield(3)], sortField: "forward_dividend_yield", descending: true,
                       ranking: .fetched, metric: .dividendYield),
    ]

    static let futuresSymbols = ["ES=F", "NQ=F", "YM=F", "RTY=F", "CL=F", "GC=F", "SI=F", "NG=F", "HG=F", "ZN=F"]

    static let all: [ScreenerPreset] = stocks + [
        ScreenerPreset(id: "cryptoGainers", title: "Crypto gainers", symbol: "bitcoinsign.circle", blurb: "Biggest 24-hour gains among major crypto.",
                       filters: [], sortField: "", descending: true, ranking: .change(descending: true), metric: .change, source: .crypto),
        ScreenerPreset(id: "cryptoLosers", title: "Crypto losers", symbol: "bitcoinsign.circle", blurb: "Biggest 24-hour declines among major crypto.",
                       filters: [], sortField: "", descending: false, ranking: .change(descending: false), metric: .change, source: .crypto),
        ScreenerPreset(id: "futures", title: "Futures markets", symbol: "calendar.badge.clock", blurb: "Index, energy, metals and rate futures.",
                       filters: [], sortField: "", descending: true, ranking: .fetched, metric: .change, source: .symbols(futuresSymbols)),
    ]

    static let defaultPinned = ["iv", "cryptoGainers", "futures", "gainers", "losers", "active"]
    static func preset(_ id: String) -> ScreenerPreset? { all.first { $0.id == id } }
}

nonisolated struct ScreenerRow: Identifiable, Hashable, Sendable {
    let symbol: String
    let name: String
    let price: Double
    let changePercent: Double
    let volume: Double?
    let averageVolume: Double?
    let marketCap: Double?
    let yearChange: Double?
    let dividendYield: Double?
    var impliedVolatility: Double?

    var label: String {
        symbol.replacingOccurrences(of: "-USD", with: "").replacingOccurrences(of: "=F", with: "")
            .replacing(/\d{4,}$/, with: "")
    }

    var id: String { symbol }

    var relativeVolume: Double? {
        guard let volume, let averageVolume, averageVolume > 0 else { return nil }
        return volume / averageVolume
    }

    init?(_ value: YValue) {
        guard let quote = MarketQuote(value) else { return nil }
        symbol = quote.symbol
        name = quote.name
        // Screens rank on the regular session, so show that session's move rather than a pre/post-market one.
        price = value["regularMarketPrice"]?.raw ?? quote.price
        changePercent = value["regularMarketChangePercent"]?.raw ?? quote.changePercent
        volume = value["regularMarketVolume"]?.raw
        averageVolume = value["averageDailyVolume3Month"]?.raw
        marketCap = value["marketCap"]?.raw
        yearChange = value["fiftyTwoWeekChangePercent"]?.raw
        dividendYield = value["dividendYield"]?.raw
    }

    init(_ quote: MarketQuote) {
        symbol = quote.symbol
        name = quote.name
        price = quote.price
        changePercent = quote.changePercent
        volume = nil
        averageVolume = nil
        marketCap = quote.marketCap
        yearChange = nil
        dividendYield = nil
    }

    func metric(_ metric: ScreenerMetric) -> String? {
        switch metric {
        case .change: nil
        case .volume: volume.map(DataText.compact)
        case .relativeVolume: relativeVolume.map { String(format: "%.1f×", $0) }
        case .marketCap: marketCap.map { "$" + DataText.compact($0) }
        case .impliedVolatility: impliedVolatility.map { $0.formatted(.percent.precision(.fractionLength(0))) }
        case .yearChange: yearChange.map { String(format: "%+.0f%%", $0) }
        case .dividendYield: dividendYield.map { String(format: "%.2f%%", $0) }
        }
    }

    func rankValue(_ metric: ScreenerMetric) -> Double? {
        switch metric {
        case .change: changePercent
        case .volume: volume
        case .relativeVolume: relativeVolume
        case .marketCap: marketCap
        case .impliedVolatility: impliedVolatility
        case .yearChange: yearChange
        case .dividendYield: dividendYield
        }
    }
}

nonisolated enum ScreenerRanking {
    static func apply(_ preset: ScreenerPreset, to rows: [ScreenerRow]) -> [ScreenerRow] {
        switch preset.ranking {
        case .fetched:
            return Array(rows.prefix(preset.size))
        case .change(let descending):
            return rows.sorted { descending ? $0.changePercent > $1.changePercent : $0.changePercent < $1.changePercent }
                .prefix(preset.size).map { $0 }
        case .relativeVolume(let minimum):
            return rows.filter { ($0.relativeVolume ?? 0) >= minimum }
                .sorted { ($0.relativeVolume ?? 0) > ($1.relativeVolume ?? 0) }
                .prefix(preset.size).map { $0 }
        case .impliedVolatility(let universe):
            return rows.prefix(universe).filter { $0.impliedVolatility != nil }
                .sorted { ($0.impliedVolatility ?? 0) > ($1.impliedVolatility ?? 0) }
                .prefix(25).map { $0 }
        }
    }
}

extension MarketClient {
    @concurrent static func screen(_ preset: ScreenerPreset) async throws -> [ScreenerRow] {
        switch preset.source {
        case .symbols(let symbols):
            return try await quotes(symbols).map(ScreenerRow.init)
                .sorted { (symbols.firstIndex(of: $0.symbol) ?? 0) < (symbols.firstIndex(of: $1.symbol) ?? 0) }
        case .crypto:
            let root = try await authed("/v1/finance/screener/predefined/saved", [
                URLQueryItem(name: "scrIds", value: "all_cryptocurrencies_us"), URLQueryItem(name: "count", value: "100"),
            ])
            return (root["finance"]?["result"]?.array.first?["quotes"]?.array ?? []).compactMap(ScreenerRow.init).filter { ($0.marketCap ?? 0) >= 1e8 }
        case .screener: break
        }
        let body = try JSONSerialization.data(withJSONObject: preset.requestBody())
        for attempt in 0..<2 {
            let crumb = try await YahooAuth.shared.crumb(refresh: attempt > 0)
            var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/screener")!
            components.queryItems = [URLQueryItem(name: "crumb", value: crumb), URLQueryItem(name: "lang", value: "en-US"), URLQueryItem(name: "region", value: "US")]
            var request = URLRequest(url: components.url!, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { continue }
            guard (200..<300).contains(code) else { throw MarketError.status(code) }
            let root = try JSONDecoder().decode(YValue.self, from: data)
            return (root["finance"]?["result"]?.array.first?["quotes"]?.array ?? []).compactMap(ScreenerRow.init)
        }
        throw MarketError.status(401)
    }
}

@Observable final class ScreenerStore {
    static let shared = ScreenerStore()
    private static let pinnedKey = "pinnedScreeners"

    private(set) var fetched: [String: [ScreenerRow]] = [:]
    private(set) var states: [String: MarketLoadState] = [:]
    private(set) var updatedAt: [String: Date] = [:]
    private(set) var impliedVolatilities: [String: ImpliedVolatility] = [:]
    private(set) var volatilityProgress: (done: Int, total: Int)?
    private(set) var pinned: [String]
    private var inFlight: Set<String> = []

    @ObservationIgnored private let fetch: (ScreenerPreset) async throws -> [ScreenerRow]
    @ObservationIgnored private let fetchVolatility: @Sendable (String) async -> ImpliedVolatility?
    @ObservationIgnored private let clock: () -> Date

    init(
        fetch: @escaping (ScreenerPreset) async throws -> [ScreenerRow] = { try await MarketClient.screen($0) },
        fetchVolatility: @escaping @Sendable (String) async -> ImpliedVolatility? = { try? await MarketClient.impliedVolatility($0) },
        clock: @escaping () -> Date = { .now }
    ) {
        self.fetch = fetch
        self.fetchVolatility = fetchVolatility
        self.clock = clock
        let saved = UserDefaults.standard.stringArray(forKey: Self.pinnedKey)
        pinned = (saved ?? ScreenerPreset.defaultPinned).filter { ScreenerPreset.preset($0) != nil }
    }

    var pinnedPresets: [ScreenerPreset] { pinned.compactMap(ScreenerPreset.preset) }

    func isPinned(_ preset: ScreenerPreset) -> Bool { pinned.contains(preset.id) }

    func togglePin(_ preset: ScreenerPreset) {
        if let index = pinned.firstIndex(of: preset.id) { pinned.remove(at: index) } else { pinned.append(preset.id) }
        UserDefaults.standard.set(pinned, forKey: Self.pinnedKey)
    }

    func state(_ preset: ScreenerPreset) -> MarketLoadState { states[preset.id] ?? .loading }

    func rows(_ preset: ScreenerPreset) -> [ScreenerRow] {
        var rows = fetched[preset.id] ?? []
        if preset.isImpliedVolatility {
            for index in rows.indices { rows[index].impliedVolatility = impliedVolatilities[rows[index].symbol]?.value }
        }
        return ScreenerRanking.apply(preset, to: rows)
    }

    func usesEstimatedVolatility(_ preset: ScreenerPreset) -> Bool {
        preset.isImpliedVolatility && rows(preset).contains { impliedVolatilities[$0.symbol]?.estimated == true }
    }

    private func stale(_ preset: ScreenerPreset) -> Bool {
        updatedAt[preset.id].map { clock().timeIntervalSince($0) > 60 } ?? true
    }

    func refresh(_ preset: ScreenerPreset, force: Bool = false) async {
        guard force || stale(preset), inFlight.insert(preset.id).inserted else { return }
        defer { inFlight.remove(preset.id) }
        if fetched[preset.id] == nil { states[preset.id] = .loading }
        do {
            let found = try await fetch(preset)
            guard !Task.isCancelled else { return }
            fetched[preset.id] = found
            updatedAt[preset.id] = clock()
            states[preset.id] = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            states[preset.id] = .unavailable
            return
        }
        if case .impliedVolatility(let universe) = preset.ranking {
            await refreshVolatility(Array((fetched[preset.id] ?? []).prefix(universe).map(\.symbol)))
        }
    }

    private func refreshVolatility(_ symbols: [String]) async {
        let need = symbols.filter { symbol in impliedVolatilities[symbol].map { clock().timeIntervalSince($0.fetchedAt) > 600 } ?? true }
        guard !need.isEmpty else { return }
        volatilityProgress = (0, need.count)
        defer { volatilityProgress = nil }
        let fetch = fetchVolatility
        await withTaskGroup(of: (String, ImpliedVolatility?).self) { group in
            var pending = need.makeIterator()
            for _ in 0..<6 { if let symbol = pending.next() { group.addTask { (symbol, await fetch(symbol)) } } }
            var done = 0
            for await (symbol, value) in group {
                done += 1
                if let value { impliedVolatilities[symbol] = value }
                volatilityProgress = (done, need.count)
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let next = pending.next() { group.addTask { (next, await fetch(next)) } }
            }
        }
    }
}
