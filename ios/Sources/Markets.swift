import Charts
import SwiftUI

nonisolated enum ChartRange: String, CaseIterable, Identifiable, Sendable {
    case day = "1D", week = "5D", month = "1M", threeMonths = "3M", sixMonths = "6M", ytd = "YTD", year = "1Y", fiveYears = "5Y", max = "MAX"

    var id: String { rawValue }

    var query: (range: String, interval: String, prePost: Bool) {
        switch self {
        case .day: ("1d", "2m", true)
        case .week: ("5d", "15m", true)
        case .month: ("1mo", "60m", false)
        case .threeMonths: ("3mo", "1d", false)
        case .sixMonths: ("6mo", "1d", false)
        case .ytd: ("ytd", "1d", false)
        case .year: ("1y", "1d", false)
        case .fiveYears: ("5y", "1wk", false)
        case .max: ("max", "1mo", false)
        }
    }

    var intraday: Bool { self == .day || self == .week || self == .month }

    var caption: String {
        switch self {
        case .day: "Today"
        case .week: "Past week"
        case .month: "Past month"
        case .threeMonths: "Past 3 months"
        case .sixMonths: "Past 6 months"
        case .ytd: "Year to date"
        case .year: "Past year"
        case .fiveYears: "Past 5 years"
        case .max: "All time"
        }
    }
}

nonisolated struct PricePoint: Identifiable, Hashable, Sendable {
    let id: Int
    let date: Date
    let open: Double?
    let close: Double
    let extended: Bool
    let run: Int
}

nonisolated struct MarketSession: Sendable {
    let start: Date
    let end: Date
    func contains(_ date: Date) -> Bool { start <= date && date < end }
}

nonisolated struct MarketChart: Sendable {
    let symbol: String
    let name: String
    let exchange: String
    let currency: String
    let instrument: String
    var price: Double
    let previousClose: Double?
    var dayHigh: Double?
    var dayLow: Double?
    let volume: Double?
    let yearHigh: Double?
    let yearLow: Double?
    let decimals: Int
    let timeZone: TimeZone
    var points: [PricePoint]
    var slots: Int
    let pre: MarketSession?
    let regular: MarketSession?
    let post: MarketSession?

    var high: Double? { points.map(\.close).max() }
    var low: Double? { points.map(\.close).min() }
    var open: Double? { points.first { !$0.extended }?.open ?? points.first?.open }

    var extendedQuote: (label: String, price: Double)? {
        guard let last = points.last, last.extended else { return nil }
        if let post, last.date >= post.start { return ("After hours", last.close) }
        if let pre, pre.contains(last.date) { return ("Pre-market", last.close) }
        return nil
    }

    var awaitingOpen: Bool {
        guard let pre, let last = points.last, last.extended, pre.contains(last.date) else { return false }
        return !points.contains { !$0.extended && $0.date >= pre.start }
    }

    func applying(_ tick: MarketTick, interval: TimeInterval = 120) -> MarketChart? {
        guard tick.price > 0, let last = points.last, tick.date >= last.date, tick.date.timeIntervalSince(last.date) < 1800 else { return nil }
        let extended = pre?.contains(tick.date) == true || post?.contains(tick.date) == true
        var next = self
        if !extended {
            next.price = tick.price
            next.dayHigh = max(dayHigh ?? tick.price, tick.price)
            next.dayLow = min(dayLow ?? tick.price, tick.price)
        }
        let bucket = (tick.date.timeIntervalSince1970 / interval).rounded(.down)
        if (last.date.timeIntervalSince1970 / interval).rounded(.down) == bucket {
            next.points[points.count - 1] = PricePoint(id: last.id, date: last.date, open: last.open, close: tick.price, extended: last.extended, run: last.run)
        } else {
            next.points.append(PricePoint(id: points.count, date: Date(timeIntervalSince1970: bucket * interval), open: tick.price, close: tick.price,
                                          extended: extended, run: last.run + (last.extended == extended ? 0 : 1)))
            next.slots = max(slots, next.points.count)
        }
        return next
    }

    var status: String {
        let now = Date()
        if let regular, regular.contains(now) { return "Market open" }
        if let pre, pre.contains(now) { return "Pre-market" }
        if let post, post.contains(now) { return "After hours" }
        return "Market closed"
    }
}

nonisolated struct MarketTick: Sendable {
    let symbol: String
    let price: Double
    let date: Date

    init?(_ data: Data) {
        var symbol: String?, price: Double?, millis: Int64?
        let bytes = [UInt8](data)
        var index = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint() else { return nil }
            switch (key >> 3, key & 7) {
            case (_, 0):
                guard let value = varint() else { return nil }
                if key >> 3 == 3 { millis = Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1) }
            case (_, 1):
                index += 8
            case (let field, 2):
                guard let length = varint().map(Int.init), index + length <= bytes.count else { return nil }
                if field == 1 { symbol = String(decoding: bytes[index..<index + length], as: UTF8.self) }
                index += length
            case (let field, 5):
                guard index + 4 <= bytes.count else { return nil }
                let bits = bytes[index..<index + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                if field == 2 { price = Double(Float(bitPattern: bits)) }
                index += 4
            default:
                return nil
            }
        }
        guard let symbol, let price, let millis else { return nil }
        self.symbol = symbol
        self.price = price
        date = Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}

nonisolated enum MarketStream {
    private struct Envelope: Decodable { let message: String }

    static func ticks(_ symbol: String) -> AsyncThrowingStream<MarketTick, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let socket = URLSession.shared.webSocketTask(with: URL(string: "wss://streamer.finance.yahoo.com/?version=2")!)
            let reader = Task {
                do {
                    socket.resume()
                    let subscribe = try JSONEncoder().encode(["subscribe": [symbol]])
                    try await socket.send(.string(String(decoding: subscribe, as: UTF8.self)))
                    while true {
                        guard case .string(let text) = try await socket.receive(),
                              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)),
                              let data = Data(base64Encoded: envelope.message),
                              let tick = MarketTick(data), tick.symbol == symbol else { continue }
                        continuation.yield(tick)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}

nonisolated struct TickerMatch: Identifiable, Hashable, Sendable, Decodable {
    let symbol: String
    let shortname: String?
    let longname: String?
    let quoteType: String?
    let exchDisp: String?

    var id: String { symbol }
    var title: String { longname ?? shortname ?? symbol }
    var kind: String {
        switch quoteType {
        case "FUTURE": "Future"
        case "ETF": "ETF"
        case "CRYPTOCURRENCY": "Crypto"
        case "INDEX": "Index"
        case "CURRENCY": "Currency"
        case "MUTUALFUND": "Fund"
        default: "Stock"
        }
    }
}

nonisolated enum MarketError: LocalizedError {
    case notFound(String), status(Int)

    var errorDescription: String? {
        switch self {
        case .notFound(let symbol): "No market data for \(symbol)."
        case .status(let code): "Market data unavailable (\(code))."
        }
    }
}

nonisolated enum YValue: Decodable, Sendable {
    case number(Double), string(String), bool(Bool), object([String: YValue]), array([YValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([YValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: YValue].self)) }
    }

    subscript(key: String) -> YValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var array: [YValue] {
        if case .array(let array) = self { array } else { [] }
    }

    var raw: Double? {
        switch self {
        case .number(let value): value
        case .object(let object): object["raw"]?.raw
        default: nil
        }
    }

    var text: String? {
        switch self {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let value): value.formatted()
        case .object(let object): object["fmt"]?.text
        default: nil
        }
    }

    var date: Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }
}

nonisolated struct QuoteSummary: Sendable {
    let root: YValue

    func value(_ module: String, _ key: String) -> YValue? { root[module]?[key] }
    func text(_ module: String, _ key: String) -> String? { value(module, key)?.text }
    func raw(_ module: String, _ key: String) -> Double? { value(module, key)?.raw }
    func day(_ module: String, _ key: String) -> String? {
        value(module, key)?.date?.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!))
    }
}

actor YahooAuth {
    static let shared = YahooAuth()
    private var crumb: String?

    func crumb(refresh: Bool) async throws -> String {
        if let crumb, !refresh { return crumb }
        _ = try? await MarketClient.load(URL(string: "https://fc.yahoo.com")!)
        let (data, code) = try await MarketClient.load(URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb")!)
        guard (200..<300).contains(code), let text = String(data: data, encoding: .utf8), !text.isEmpty, !text.contains("<") else {
            throw MarketError.status(code)
        }
        crumb = text
        return text
    }
}

nonisolated enum MarketClient {
    private struct ChartEnvelope: Decodable {
        struct Chart: Decodable { let result: [Result]? }
        struct Result: Decodable { let meta: Meta; let timestamp: [Double]?; let indicators: Indicators }
        struct Indicators: Decodable { let quote: [Bars] }
        struct Bars: Decodable { let open: [Double?]?; let close: [Double?]? }
        struct Period: Decodable { let start: Double; let end: Double }
        struct Current: Decodable { let pre: Period?; let regular: Period?; let post: Period? }
        struct Periods: Decodable {
            var pre: [Period] = [], regular: [Period] = [], post: [Period] = []
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let split = try? container.decode([String: [[Period]]].self) {
                    pre = split["pre"]?.flatMap { $0 } ?? []
                    regular = split["regular"]?.flatMap { $0 } ?? []
                    post = split["post"]?.flatMap { $0 } ?? []
                } else if let list = try? container.decode([[Period]].self) {
                    regular = list.flatMap { $0 }
                }
            }
        }
        struct Meta: Decodable {
            let symbol: String
            let currency: String?
            let fullExchangeName: String?
            let instrumentType: String?
            let longName: String?
            let shortName: String?
            let regularMarketPrice: Double?
            let chartPreviousClose: Double?
            let previousClose: Double?
            let regularMarketDayHigh: Double?
            let regularMarketDayLow: Double?
            let regularMarketVolume: Double?
            let fiftyTwoWeekHigh: Double?
            let fiftyTwoWeekLow: Double?
            let exchangeTimezoneName: String?
            let priceHint: Int?
            let currentTradingPeriod: Current?
            let tradingPeriods: Periods?
        }
        let chart: Chart
    }

    private struct SearchEnvelope: Decodable { let quotes: [TickerMatch] }

    static func load(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func url(_ host: String, _ path: String, _ items: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = items
        guard let url = components.url else { throw MarketError.status(0) }
        return url
    }

    private static func get(_ path: String, _ items: [URLQueryItem]) async throws -> Data {
        let (data, code) = try await load(url("query1.finance.yahoo.com", path, items))
        guard (200..<300).contains(code) else { throw code == 404 ? MarketError.notFound(items.first?.value ?? "") : MarketError.status(code) }
        return data
    }

    private static func authed(_ path: String, _ items: [URLQueryItem]) async throws -> YValue {
        for attempt in 0..<2 {
            let crumb = try await YahooAuth.shared.crumb(refresh: attempt > 0)
            let (data, code) = try await load(url("query2.finance.yahoo.com", path, items + [URLQueryItem(name: "crumb", value: crumb)]))
            if code == 401 || code == 403 { continue }
            guard (200..<300).contains(code) else { throw code == 404 ? MarketError.notFound(path) : MarketError.status(code) }
            return try JSONDecoder().decode(YValue.self, from: data)
        }
        throw MarketError.status(401)
    }

    @concurrent static func summary(_ symbol: String) async throws -> QuoteSummary {
        let modules = "price,summaryDetail,defaultKeyStatistics,financialData,assetProfile,calendarEvents,recommendationTrend,earnings,fundProfile,topHoldings"
        let root: YValue
        do {
            root = try await authed("/v10/finance/quoteSummary/\(symbol)", [URLQueryItem(name: "modules", value: modules)])
        } catch MarketError.notFound { throw MarketError.notFound(symbol) }
        guard let result = root["quoteSummary"]?["result"]?.array.first else { throw MarketError.notFound(symbol) }
        return QuoteSummary(root: result)
    }

    @concurrent static func quotes(_ symbols: [String]) async throws -> [MarketQuote] {
        guard !symbols.isEmpty else { return [] }
        let root = try await authed("/v7/finance/quote", [URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))])
        return (root["quoteResponse"]?["result"]?.array ?? []).compactMap(MarketQuote.init)
    }

    @concurrent static func movers(_ list: MoverList) async throws -> [MarketQuote] {
        let root = try await authed("/v1/finance/screener/predefined/saved", [
            URLQueryItem(name: "scrIds", value: list.rawValue), URLQueryItem(name: "count", value: "8"),
        ])
        return (root["finance"]?["result"]?.array.first?["quotes"]?.array ?? []).compactMap(MarketQuote.init)
    }

    @concurrent static func sparks(_ symbols: [String]) async throws -> [String: Spark] {
        guard !symbols.isEmpty else { return [:] }
        let data = try await get("/v7/finance/spark", [
            URLQueryItem(name: "symbols", value: symbols.prefix(20).joined(separator: ",")),
            URLQueryItem(name: "range", value: "1d"), URLQueryItem(name: "interval", value: "5m"),
        ])
        var result: [String: Spark] = [:]
        for item in try JSONDecoder().decode(YValue.self, from: data)["spark"]?["result"]?.array ?? [] {
            guard case .string(let symbol)? = item["symbol"], let response = item["response"]?.array.first else { continue }
            let closes = (response["indicators"]?["quote"]?.array.first?["close"]?.array ?? []).compactMap(\.raw)
            guard closes.count > 1 else { continue }
            let meta = response["meta"]
            result[symbol] = Spark(points: closes, baseline: meta?["chartPreviousClose"]?.raw ?? meta?["previousClose"]?.raw)
        }
        return result
    }

    @concurrent static func search(_ query: String) async throws -> [TickerMatch] {
        let data = try await get("/v1/finance/search", [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "quotesCount", value: "8"),
            URLQueryItem(name: "newsCount", value: "0"), URLQueryItem(name: "listsCount", value: "0"),
        ])
        return try JSONDecoder().decode(SearchEnvelope.self, from: data).quotes
    }

    @concurrent static func chart(_ symbol: String, range: ChartRange) async throws -> MarketChart {
        let query = range.query
        let data: Data
        do {
            data = try await get("/v8/finance/chart/\(symbol)", [
                URLQueryItem(name: "range", value: query.range), URLQueryItem(name: "interval", value: query.interval),
                URLQueryItem(name: "includePrePost", value: query.prePost ? "true" : "false"),
            ])
        } catch MarketError.notFound { throw MarketError.notFound(symbol) }
        guard let result = try JSONDecoder().decode(ChartEnvelope.self, from: data).chart.result?.first,
              let price = result.meta.regularMarketPrice else { throw MarketError.notFound(symbol) }
        let meta = result.meta
        let session = { (period: ChartEnvelope.Period?) in
            period.map { MarketSession(start: Date(timeIntervalSince1970: $0.start), end: Date(timeIntervalSince1970: $0.end)) }
        }
        let regularHours = (meta.tradingPeriods?.regular ?? []).compactMap(session)
        let bars = result.indicators.quote.first
        let closes = bars?.close ?? []
        let opens = bars?.open ?? []
        var points: [PricePoint] = []
        var run = 0
        for (index, stamp) in (result.timestamp ?? []).enumerated() {
            guard index < closes.count, let close = closes[index] else { continue }
            if range.intraday, index > 0, index + 1 < closes.count, let before = closes[index - 1], let after = closes[index + 1],
               abs(close - before) / before > 0.02, abs(close - after) / after > 0.02, abs(after - before) / before < 0.01 { continue }
            let date = Date(timeIntervalSince1970: stamp)
            let extended = query.prePost && !regularHours.isEmpty && !regularHours.contains { $0.start <= date && date <= $0.end }
            if let last = points.last, last.extended != extended { run += 1 }
            points.append(PricePoint(id: points.count, date: date, open: index < opens.count ? opens[index] : nil, close: close, extended: extended, run: run))
        }
        let current = meta.currentTradingPeriod
        var slots = points.count
        if range == .day, let last = points.last {
            let close = (meta.tradingPeriods?.post.last ?? meta.tradingPeriods?.regular.last).map { Date(timeIntervalSince1970: $0.end) }
            if let close, close > last.date { slots += Int(close.timeIntervalSince(last.date) / 120) }
        }
        return MarketChart(
            symbol: meta.symbol,
            name: meta.longName ?? meta.shortName ?? meta.symbol,
            exchange: meta.fullExchangeName ?? "",
            currency: meta.currency ?? "USD",
            instrument: meta.instrumentType ?? "",
            price: price,
            previousClose: range == .day ? (meta.chartPreviousClose ?? meta.previousClose) : meta.previousClose,
            dayHigh: meta.regularMarketDayHigh,
            dayLow: meta.regularMarketDayLow,
            volume: meta.regularMarketVolume,
            yearHigh: meta.fiftyTwoWeekHigh,
            yearLow: meta.fiftyTwoWeekLow,
            decimals: min(max(meta.priceHint ?? 2, 2), 6),
            timeZone: meta.exchangeTimezoneName.flatMap(TimeZone.init(identifier:)) ?? .current,
            points: points,
            slots: max(slots, 2),
            pre: session(current?.pre),
            regular: session(current?.regular),
            post: session(current?.post)
        )
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var items: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !items.isEmpty && x + size.width > width {
                rows.append((items, y, x - spacing, height))
                y += height + spacing
                items = []; x = 0; height = 0
            }
            items.append(index)
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !items.isEmpty { rows.append((items, y, x - spacing, height)) }
        return rows
    }
}
