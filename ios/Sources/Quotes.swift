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

    func symbols(for story: Story) -> [String] {
        story.tickers.isEmpty ? resolved[story.id] ?? [] : story.tickers
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
            await fetch(symbols(for: story).filter { stale($0) })
            return
        }
        guard let api, !resolving.contains(story.id) else { return }
        resolving.insert(story.id)
        defer { resolving.remove(story.id) }
        let text = "\(story.title)\n\(StoryHTML.plainText(story.summary))"
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
