import Foundation

nonisolated enum BlackScholes {
    static let rate = 0.04

    private static func normal(_ x: Double) -> Double { 0.5 * erfc(-x / 2.squareRoot()) }

    static func price(call: Bool, spot: Double, strike: Double, years: Double, volatility: Double, rate: Double = rate) -> Double {
        guard years > 0, volatility > 0, spot > 0, strike > 0 else { return max(0, call ? spot - strike : strike - spot) }
        let root = volatility * years.squareRoot()
        let d1 = (log(spot / strike) + (rate + volatility * volatility / 2) * years) / root
        let d2 = d1 - root
        let discount = strike * exp(-rate * years)
        return call ? spot * normal(d1) - discount * normal(d2) : discount * normal(-d2) - spot * normal(-d1)
    }

    static func impliedVolatility(call: Bool, premium: Double, spot: Double, strike: Double, years: Double) -> Double? {
        guard premium > 0, years > 0 else { return nil }
        var low = 0.005, high = 6.0
        guard premium >= price(call: call, spot: spot, strike: strike, years: years, volatility: low),
              premium <= price(call: call, spot: spot, strike: strike, years: years, volatility: high) else { return nil }
        for _ in 0..<80 {
            let mid = (low + high) / 2
            if price(call: call, spot: spot, strike: strike, years: years, volatility: mid) < premium { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    static func expiry(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 16)) ?? date
    }

    static func years(from start: Date, to end: Date) -> Double {
        max(0, end.timeIntervalSince(start)) / (365 * 86_400)
    }
}

nonisolated struct OptionQuote: Sendable, Equatable {
    let bid: Double
    let ask: Double
    let last: Double
    let lastTrade: Date?
    let yahooVolatility: Double?
    let regular: Double
    let pre: Double?
    let post: Double?
    let marketState: String

    var liveMarket: Bool { bid > 0 && ask > 0 && marketState == "REGULAR" }
    var mark: Double { bid > 0 && ask > 0 ? (bid + ask) / 2 : last }

    var extended: (label: String, price: Double)? {
        switch marketState {
        case "PRE", "PREPRE": pre.map { ("Pre-market", $0) }
        case "POST", "POSTPOST", "CLOSED": post.map { ("After hours", $0) }
        default: nil
        }
    }
}

nonisolated struct OptionEstimate: Sendable {
    let quote: OptionQuote
    let volatility: Double
    let expiry: Date
    let isCall: Bool
    let strike: Double

    init?(quote: OptionQuote, option: OptionDetail) {
        let expiry = BlackScholes.expiry(option.expiration)
        let anchor = quote.liveMarket ? Date.now : (quote.lastTrade ?? .now)
        let years = BlackScholes.years(from: anchor, to: expiry)
        let solved = BlackScholes.impliedVolatility(call: option.isCall, premium: quote.mark, spot: quote.regular, strike: option.strike, years: years)
        guard let volatility = solved ?? quote.yahooVolatility.flatMap({ $0 > 0.02 ? $0 : nil }) else { return nil }
        self.quote = quote
        self.volatility = volatility
        self.expiry = expiry
        self.isCall = option.isCall
        self.strike = option.strike
    }

    func perShare(at spot: Double, on date: Date = .now) -> Double {
        BlackScholes.price(call: isCall, spot: spot, strike: strike, years: BlackScholes.years(from: date, to: expiry), volatility: volatility)
    }
}

nonisolated struct OptionContract: Identifiable, Hashable, Sendable {
    let symbol: String
    let strike: Double
    let bid: Double
    let ask: Double
    let last: Double
    let changePercent: Double
    let volume: Double
    let openInterest: Double
    let volatility: Double?
    let inTheMoney: Bool

    var id: String { symbol }
    var mark: Double { bid > 0 && ask > 0 ? (bid + ask) / 2 : last }

    init?(_ value: YValue) {
        guard case .string(let symbol)? = value["contractSymbol"], let strike = value["strike"]?.raw else { return nil }
        self.symbol = symbol
        self.strike = strike
        bid = value["bid"]?.raw ?? 0
        ask = value["ask"]?.raw ?? 0
        last = value["lastPrice"]?.raw ?? 0
        changePercent = value["percentChange"]?.raw ?? 0
        volume = value["volume"]?.raw ?? 0
        openInterest = value["openInterest"]?.raw ?? 0
        volatility = value["impliedVolatility"]?.raw
        if case .bool(true)? = value["inTheMoney"] { inTheMoney = true } else { inTheMoney = false }
    }
}

nonisolated struct OptionChainPage: Sendable {
    let expirations: [Date]
    let expiration: Date?
    let spot: Double
    let calls: [OptionContract]
    let puts: [OptionContract]

    static func parse(_ data: Data) -> OptionChainPage? {
        guard let result = (try? JSONDecoder().decode(YValue.self, from: data))?["optionChain"]?["result"]?.array.first,
              let spot = result["quote"]?["regularMarketPrice"]?.raw else { return nil }
        let chain = result["options"]?.array.first
        return OptionChainPage(expirations: (result["expirationDates"]?.array ?? []).compactMap(\.date),
                               expiration: chain?["expirationDate"]?.date,
                               spot: spot,
                               calls: (chain?["calls"]?.array ?? []).compactMap(OptionContract.init),
                               puts: (chain?["puts"]?.array ?? []).compactMap(OptionContract.init))
    }
}

/// OCC option symbols such as AAPL260116C00150000.
nonisolated struct OptionSymbol: Hashable, Sendable {
    let underlying: String
    let expiration: Date
    let isCall: Bool
    let strike: Double

    init?(_ symbol: String) {
        guard let match = symbol.wholeMatch(of: /([A-Z0-9.\-^]{1,6})(\d{2})(\d{2})(\d{2})([CP])(\d{8})/),
              let year = Int(match.2), let month = Int(match.3), let day = Int(match.4), let strike = Double(match.6) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: 2000 + year, month: month, day: day)) else { return nil }
        underlying = String(match.1)
        expiration = date
        isCall = match.5 == "C"
        self.strike = strike / 1000
    }

    var title: String {
        let day = expiration.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.defaultDigits).day().year(.twoDigits))
        return "\(underlying) \(strike.formatted(.number.precision(.fractionLength(0...2))))\(isCall ? "C" : "P") \(day)"
    }

    static func display(_ symbol: String) -> String { OptionSymbol(symbol)?.title ?? symbol }
}

nonisolated enum OptionChain {
    @concurrent static func page(symbol: String, expiration: Date?) async throws -> OptionChainPage {
        for attempt in 0..<2 {
            let crumb = try await YahooAuth.shared.crumb(refresh: attempt > 0)
            var components = URLComponents(string: "https://query2.finance.yahoo.com")!
            components.path = "/v7/finance/options/\(symbol)"
            components.queryItems = [URLQueryItem(name: "crumb", value: crumb)]
                + (expiration.map { [URLQueryItem(name: "date", value: String(Int($0.timeIntervalSince1970)))] } ?? [])
            guard let url = components.url else { throw MarketError.status(0) }
            let (data, code) = try await MarketClient.load(url)
            if code == 401 || code == 403 { continue }
            guard (200..<300).contains(code) else { throw code == 404 ? MarketError.notFound(symbol) : MarketError.status(code) }
            guard let page = OptionChainPage.parse(data) else { throw MarketError.notFound(symbol) }
            return page
        }
        throw MarketError.status(401)
    }

    @concurrent static func quote(symbol: String, option: OptionDetail) async throws -> OptionQuote? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Calendar.current.dateComponents([.year, .month, .day], from: option.expiration)
        guard let expiry = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
        for attempt in 0..<2 {
            let crumb = try await YahooAuth.shared.crumb(refresh: attempt > 0)
            var components = URLComponents(string: "https://query2.finance.yahoo.com")!
            components.path = "/v7/finance/options/\(symbol)"
            components.queryItems = [URLQueryItem(name: "date", value: String(Int(expiry.timeIntervalSince1970))),
                                     URLQueryItem(name: "crumb", value: crumb)]
            guard let url = components.url else { return nil }
            let (data, code) = try await MarketClient.load(url)
            if code == 401 || code == 403 { continue }
            guard (200..<300).contains(code) else { throw MarketError.status(code) }
            return parse(data, option: option)
        }
        throw MarketError.status(401)
    }

    static func parse(_ data: Data, option: OptionDetail) -> OptionQuote? {
        guard let result = (try? JSONDecoder().decode(YValue.self, from: data))?["optionChain"]?["result"]?.array.first,
              let quote = result["quote"],
              let regular = quote["regularMarketPrice"]?.raw,
              let chain = result["options"]?.array.first else { return nil }
        let side = chain[option.isCall ? "calls" : "puts"]?.array ?? []
        guard let contract = side.first(where: { abs(($0["strike"]?.raw ?? -1) - option.strike) < 0.001 }) else { return nil }
        return OptionQuote(bid: contract["bid"]?.raw ?? 0,
                           ask: contract["ask"]?.raw ?? 0,
                           last: contract["lastPrice"]?.raw ?? 0,
                           lastTrade: contract["lastTradeDate"]?.raw.map { Date(timeIntervalSince1970: $0) },
                           yahooVolatility: contract["impliedVolatility"]?.raw,
                           regular: regular,
                           pre: quote["preMarketPrice"]?.raw,
                           post: quote["postMarketPrice"]?.raw,
                           marketState: quote["marketState"]?.text ?? "")
    }
}
