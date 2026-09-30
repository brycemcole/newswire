import Charts
import SwiftUI

struct Quote: Codable, Hashable, Identifiable {
    struct Extended: Codable, Hashable {
        let session: String
        let price: Double
        let change: Double
        let changePercent: Double
        let time: Date
    }

    let symbol: String
    let name: String
    let match: String?
    let currency: String
    let exchange: String
    let state: String
    let price: Double
    let change: Double
    let changePercent: Double
    let previousClose: Double
    let time: Date
    let extended: Extended?
    let points: [Double]
    let extendedPoints: [Double]
    let url: URL

    var id: String { symbol }
    var isLive: Bool { state != "closed" }

    var needles: [String] {
        let suffixes: Set<String> = ["inc", "inc.", "corp", "corp.", "corporation", "co", "co.", "company", "ltd", "ltd.", "plc", "holdings", "group", "limited", "sa", "ag", "nv"]
        let words = name.split(separator: " ").map(String.init)
        let core = words.prefix { !suffixes.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) || $0 == words.first }
        return [match, core.joined(separator: " "), symbol].compactMap { $0 }.filter { $0.count > 1 }
    }
}

extension NewswireAPI {
    struct QuoteEnvelope: Decodable { let quotes: [Quote] }

    func quotes(symbols: [String] = [], text: String? = nil) async throws -> [Quote] {
        var components = URLComponents(url: baseURL.appending(path: "v1/quotes"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if !symbols.isEmpty { items.append(URLQueryItem(name: "symbols", value: symbols.prefix(12).joined(separator: ","))) }
        if let text { items.append(URLQueryItem(name: "text", value: String(text.prefix(1500)))) }
        components?.queryItems = items
        guard let url = components?.url else { throw WireError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw WireError.status(response.statusCode) }
        return try Self.decoder().decode(QuoteEnvelope.self, from: data).quotes
    }
}

@Observable final class QuoteStore {
    static let shared = QuoteStore()

    private(set) var quotes: [String: Quote] = [:]
    private(set) var resolved: [String: [String]] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var queued: Set<String> = []
    private var flushing: Task<Void, Never>?
    private var resolving: Set<String> = []

    private var api: NewswireAPI? {
        let store = FeedStore.shared
        guard let url = NewswireAPI.validatedURL(store.serverURL) else { return nil }
        return NewswireAPI(baseURL: url)
    }

    @ObservationIgnored private var scanned: [String: Int] = [:]
    @ObservationIgnored private var headlineSymbols: [String: [String]] = [:]

    /// The feed's own tickers, then symbols found in the story's text. Headline symbols appear only once Yahoo has
    /// confirmed them with a quote, so a stray capitalized word in parentheses never shows as a pill.
    func symbols(for story: Story) -> [String] {
        var seen = Set<String>()
        let confirmed = headline(story).filter { quotes[$0] != nil }
        return (story.tickers + (resolved[story.id] ?? []) + confirmed).filter { seen.insert($0).inserted }.prefix(6).map { $0 }
    }

    /// Everything worth asking Yahoo about for a feed row: its tickers plus any symbol its headline or summary spells out.
    func candidates(for story: Story) -> [String] {
        var seen = Set<String>()
        return (story.tickers + (resolved[story.id] ?? []) + headline(story)).filter { seen.insert($0).inserted }
    }

    private func headline(_ story: Story) -> [String] {
        if let known = headlineSymbols[story.id] { return known }
        let found = TickerScanner.symbols(in: "\(story.title)\n\(StoryHTML.plainText(story.summary))")
        headlineSymbols[story.id] = found
        return found
    }

    /// Runs when the article text arrives: explicit symbols in the text are kept only if they return a real quote, and
    /// stories the feed left untagged also get the server's company-name matching over the article's opening.
    func scan(_ story: Story, article: String) async {
        guard let api, !article.isEmpty, scanned[story.id] != article.count else { return }
        scanned[story.id] = article.count
        let text = "\(story.title)\n\(StoryHTML.plainText(story.summary))\n\(article)"
        let known = Set(symbols(for: story))
        let explicit = TickerScanner.symbols(in: text).filter { !known.contains($0) }
        var found: [String] = []
        if !explicit.isEmpty, let quotes = try? await api.quotes(symbols: Array(explicit.prefix(12))) {
            store(quotes)
            found += explicit.filter { symbol in quotes.contains { $0.symbol == symbol } }
        }
        if story.tickers.isEmpty, let named = try? await api.quotes(text: String(text.prefix(1500))) {
            store(named)
            found += named.map(\.symbol)
        }
        guard !found.isEmpty else { return }
        var seen = Set<String>()
        resolved[story.id] = ((resolved[story.id] ?? []) + found).filter { seen.insert($0).inserted }
    }

    func quotes(for story: Story) -> [Quote] {
        symbols(for: story).compactMap { quotes[$0] }
    }

    private func stale(_ symbol: String) -> Bool {
        guard let at = fetchedAt[symbol] else { return true }
        let limit: TimeInterval = quotes[symbol]?.isLive == false ? 600 : 30
        return Date.now.timeIntervalSince(at) > limit
    }

    func want(_ symbols: [String]) {
        let needed = symbols.filter { stale($0) }
        guard !needed.isEmpty else { return }
        queued.formUnion(needed)
        guard flushing == nil else { return }
        flushing = Task {
            try? await Task.sleep(for: .milliseconds(200))
            let batch = Array(queued.prefix(12))
            queued.subtract(batch)
            flushing = nil
            await fetch(batch)
            if !queued.isEmpty { want(Array(queued)) }
        }
    }

    func load(_ story: Story) async {
        if !story.tickers.isEmpty || resolved[story.id] != nil {
            await fetch(candidates(for: story).filter { stale($0) })
            return
        }
        guard let api, !resolving.contains(story.id) else { return }
        resolving.insert(story.id)
        defer { resolving.remove(story.id) }
        let text = "\(story.title)\n\(StoryHTML.plainText(story.summary))"
        await fetch(headline(story).filter { stale($0) })
        guard let found = try? await api.quotes(text: text) else { return }
        store(found)
        resolved[story.id] = found.map(\.symbol)
    }

    func refresh(_ story: Story) async {
        let symbols = symbols(for: story)
        guard symbols.contains(where: { quotes[$0]?.isLive ?? true }) else { return }
        await fetch(symbols.filter { stale($0) })
    }

    private func fetch(_ symbols: [String]) async {
        guard !symbols.isEmpty, let api, let found = try? await api.quotes(symbols: symbols) else { return }
        store(found)
        for symbol in symbols where fetchedAt[symbol] == nil { fetchedAt[symbol] = .now }
    }

    private func store(_ found: [Quote]) {
        for quote in found {
            let previous = quotes[quote.symbol]
            quotes[quote.symbol] = previous?.match != nil && quote.match == nil ? quote.keeping(match: previous?.match) : quote
            fetchedAt[quote.symbol] = .now
        }
    }
}

private extension Quote {
    func keeping(match: String?) -> Quote {
        Quote(symbol: symbol, name: name, match: match, currency: currency, exchange: exchange, state: state, price: price, change: change, changePercent: changePercent, previousClose: previousClose, time: time, extended: extended, points: points, extendedPoints: extendedPoints, url: url)
    }
}

/// Finds tickers that stories spell out in the standard formats: exchange-prefixed ("NASDAQ: MU", "NYSE:NU"),
/// cashtags ("$TSLA"), Reuters codes ("(MU.O)") and a parenthesized symbol after a company name ("Nu Holdings (NU)").
nonisolated enum TickerScanner {
    private static let ignored: Set<String> = ["CEO", "CFO", "COO", "CTO", "IPO", "GDP", "CPI", "PPI", "PCE", "ETF", "SEC", "FDA", "FTC", "DOJ", "FCC", "EPA", "IRS", "FED", "ECB", "BOJ", "IMF", "OPEC", "AI", "EU", "UK", "US", "USA", "UN", "EV", "EVS", "LLC", "LP", "PLC", "NYSE", "EPS", "YOY", "QOQ", "ESG", "API", "M&A", "TV", "PC", "OK", "AM", "PM", "ET", "PT", "EST", "EDT", "Q1", "Q2", "Q3", "Q4", "FY", "USD", "EUR", "GBP", "JPY", "CNY", "NATO", "WHO", "NFL", "NBA", "CNBC", "CNN", "BBC", "WSJ", "FT", "AP", "AFP", "EBITDA", "ARR", "IT", "HR", "R&D", "GPU", "CPU", "LNG", "OTC"]
    nonisolated(unsafe) private static let exchange = /\b(?:NYSE(?:\s?American|\s?Arca)?|NASDAQ|Nasdaq|AMEX|NYSEAMERICAN|NYSEARCA|OTCQX|OTCQB|OTC|TSX|TSXV|CBOE|BATS)\s*:\s*([A-Z]{1,5}(?:\.[A-Z])?)\b/
    nonisolated(unsafe) private static let cashtag = /(?:^|[\s(])\$([A-Z]{1,5})\b/
    nonisolated(unsafe) private static let reuters = /\(([A-Z]{1,5})\.(?:O|N|OQ|K|A|P)\)/
    nonisolated(unsafe) private static let parenthesized = /(?:[A-Z][\w.&'’-]*|Inc\.?|Corp\.?|Co\.?|Ltd\.?|plc)\s+\(\s*([A-Z]{2,5})\s*\)/

    static func symbols(in text: String) -> [String] {
        var found: [String] = []
        func add(_ symbol: Substring) {
            let value = String(symbol)
            if !ignored.contains(value), !found.contains(value) { found.append(value) }
        }
        for match in text.matches(of: exchange) { add(match.1) }
        for match in text.matches(of: cashtag) { add(match.1) }
        for match in text.matches(of: reuters) { add(match.1) }
        for match in text.matches(of: parenthesized) { add(match.1) }
        return Array(found.prefix(8))
    }
}

enum QuoteFormat {
    static func color(_ change: Double) -> Color { change > 0 ? .green : change < 0 ? .red : .secondary }
    static func arrow(_ change: Double) -> String { change > 0 ? "▲" : change < 0 ? "▼" : "" }
    static func percent(_ value: Double) -> String { String(format: "%@%.2f%%", value > 0 ? "+" : value < 0 ? "−" : "", abs(value)) }
    static func signed(_ value: Double) -> String { (value > 0 ? "+" : value < 0 ? "−" : "") + price(abs(value)) }
    static func price(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value >= 1000 ? 0...2 : value < 1 ? 2...4 : 2...2)))
    }
    static func session(_ extended: Quote.Extended) -> String { extended.session == "pre" ? "Pre-market" : "After hours" }
    static func sessionSymbol(_ extended: Quote.Extended) -> String { extended.session == "pre" ? "sun.horizon.fill" : "moon.fill" }
}

struct QuotePill: View {
    let quote: Quote
    var showsPrice = true

    var body: some View {
        HStack(spacing: 5) {
            Text(quote.symbol).fontWeight(.bold).foregroundStyle(.primary)
            if showsPrice { Text(QuoteFormat.price(quote.price)).foregroundStyle(.secondary) }
            Text("\(QuoteFormat.arrow(quote.changePercent))\(QuoteFormat.percent(quote.changePercent).trimmingCharacters(in: CharacterSet(charactersIn: "+−")))")
                .foregroundStyle(QuoteFormat.color(quote.changePercent))
            if let extended = quote.extended {
                Image(systemName: QuoteFormat.sessionSymbol(extended)).font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(QuoteFormat.percent(extended.changePercent)).foregroundStyle(QuoteFormat.color(extended.changePercent))
            }
        }
        .font(.system(.footnote, design: .monospaced).weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(QuoteFormat.color(quote.changePercent).opacity(0.12), in: .capsule)
        .contentTransition(.numericText())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        var label = "\(quote.name), \(QuoteFormat.price(quote.price)), \(QuoteFormat.percent(quote.changePercent))"
        if let extended = quote.extended { label += ", \(QuoteFormat.session(extended)) \(QuoteFormat.percent(extended.changePercent))" }
        return label
    }
}

struct QuoteStrip: View {
    let quotes: [Quote]
    @Binding var selected: Quote?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(quotes) { quote in
                    Button { selected = quote } label: { QuotePill(quote: quote) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows quote details")
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .animation(.easeOut(duration: 0.2), value: quotes)
    }
}

enum QuoteInline {
    static func plan(_ paragraphs: [String], quotes: [Quote]) -> [Int: [Quote]] {
        var result: [Int: [Quote]] = [:]
        for quote in quotes {
            if let index = paragraphs.firstIndex(where: { paragraph in quote.needles.contains { range(of: $0, in: paragraph) != nil } }) {
                result[index, default: []].append(quote)
            }
        }
        return result
    }

    nonisolated static func range(of needle: String, in text: String) -> Range<String.Index>? {
        var start = text.startIndex
        while let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            if !(before?.isLetter ?? false), !(after?.isLetter ?? false) { return found }
            start = found.upperBound
        }
        return nil
    }

    static func annotate(_ base: AttributedString, quotes: [Quote]) -> AttributedString {
        var text = base
        for quote in quotes {
            let plain = String(text.characters)
            guard let found = quote.needles.lazy.compactMap({ range(of: $0, in: plain) }).first else { continue }
            var end = found.upperBound
            let rest = plain[end...]
            if let suffix = rest.firstMatch(of: /^,?\s(?:Inc|Corp|Co|Ltd|Plc|Corporation|Holdings)\.?/) { end = suffix.range.upperBound }
            let offset = plain.distance(from: plain.startIndex, to: end)
            let index = text.characters.index(text.startIndex, offsetBy: offset)
            var tag = AttributedString("\u{00A0}\(quote.symbol)\u{00A0}\(QuoteFormat.arrow(quote.changePercent))\(QuoteFormat.percent(abs(quote.changePercent)).trimmingCharacters(in: CharacterSet(charactersIn: "+")))")
            tag.font = .system(.subheadline, design: .monospaced).weight(.semibold)
            tag.foregroundColor = QuoteFormat.color(quote.changePercent)
            text.insert(AttributedString(" "), at: index)
            text.insert(tag, at: text.characters.index(after: index))
        }
        return text
    }

    static func annotate(_ string: String, quotes: [Quote]) -> AttributedString {
        annotate(AttributedString(string), quotes: quotes)
    }
}
