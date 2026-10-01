import Foundation
import FoundationModels
import SwiftUI

nonisolated struct TickerStory: Identifiable, Hashable, Sendable {
    let title: String
    let publisher: String
    let url: URL
    let date: Date
    let thumbnail: URL?
    let tagged: Bool

    var id: String { url.absoluteString }
}

nonisolated enum TickerNews {
    private struct Envelope: Decodable {
        struct Item: Decodable {
            struct Thumbnail: Decodable {
                struct Size: Decodable { let url: String; let tag: String? }
                let resolutions: [Size]?
            }
            let title: String
            let publisher: String?
            let link: String
            let providerPublishTime: Double?
            let relatedTickers: [String]?
            let thumbnail: Thumbnail?
        }
        let news: [Item]?
    }

    static func core(_ name: String, symbol: String) -> String {
        let suffixes: Set<String> = ["inc", "corp", "corporation", "co", "company", "ltd", "plc", "holdings", "group", "limited", "sa", "ag", "nv", "usd", "the"]
        let months: Set<String> = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let words = name.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let kept = words.enumerated().prefix { index, word in
            index == 0 || !(suffixes.contains(word.lowercased()) || months.contains(word.lowercased()) || word.allSatisfy(\.isNumber))
        }.map(\.element)
        let joined = kept.joined(separator: " ")
        return joined.count > 1 ? joined : symbol
    }

    static func mentions(_ title: String, symbol: String, core: String) -> Bool {
        let base = symbol.split(separator: "-").first.map(String.init) ?? symbol
        return [core, base].contains { QuoteInline.range(of: $0, in: title) != nil }
    }

    @concurrent static func stories(symbol: String, name: String) async -> [TickerStory] {
        let core = core(name, symbol: symbol)
        async let tagged = yahoo(symbol: symbol, core: core)
        async let searched = google(symbol: symbol, core: core)
        let all = await tagged + searched
        var seen: Set<String> = []
        return all.sorted { $0.date > $1.date }.filter { story in
            let key = story.title.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").prefix(7).joined(separator: " ")
            return seen.insert(key).inserted
        }
        .prefix(14).map { $0 }
    }

    private static func yahoo(symbol: String, core: String) async -> [TickerStory] {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: symbol), URLQueryItem(name: "quotesCount", value: "0"),
            URLQueryItem(name: "newsCount", value: "20"), URLQueryItem(name: "listsCount", value: "0"),
        ]
        guard let url = components.url, let (data, code) = try? await MarketClient.load(url), (200..<300).contains(code),
              let items = try? JSONDecoder().decode(Envelope.self, from: data).news else { return [] }
        return items.compactMap { item in
            let related = item.relatedTickers ?? []
            guard related.contains(symbol), mentions(item.title, symbol: symbol, core: core) || related == [symbol],
                  let link = URL(string: item.link), let time = item.providerPublishTime else { return nil }
            let sizes = item.thumbnail?.resolutions ?? []
            let thumbnail = (sizes.first { $0.tag == "140x140" } ?? sizes.first).flatMap { URL(string: $0.url) }
            return TickerStory(title: item.title, publisher: item.publisher ?? link.host() ?? "", url: link,
                               date: Date(timeIntervalSince1970: time), thumbnail: thumbnail, tagged: true)
        }
    }

    private static func google(symbol: String, core: String) async -> [TickerStory] {
        var components = URLComponents(string: "https://news.google.com/rss/search")!
        let equity = symbol.allSatisfy { $0.isLetter || $0 == "." }
        components.queryItems = [
            URLQueryItem(name: "q", value: "\"\(core)\"\(equity ? " (stock OR shares)" : "") when:2d"), URLQueryItem(name: "hl", value: "en-US"),
            URLQueryItem(name: "gl", value: "US"), URLQueryItem(name: "ceid", value: "US:en"),
        ]
        guard let url = components.url, let (data, code) = try? await MarketClient.load(url), (200..<300).contains(code) else { return [] }
        let parser = RSSItems()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items.prefix(25).compactMap { item in
            var title = item["title"] ?? ""
            let source = item["source"] ?? ""
            if !source.isEmpty, title.hasSuffix(" - \(source)") { title = String(title.dropLast(source.count + 3)) }
            guard mentions(title, symbol: symbol, core: core), let link = item["link"].flatMap(URL.init(string:)),
                  let date = item["pubDate"].flatMap(RSSItems.date) else { return nil }
            return TickerStory(title: title, publisher: source, url: link, date: date, thumbnail: nil, tagged: false)
        }
    }

    @concurrent static func excerpt(_ story: TickerStory, core: String) async -> String? {
        var request = URLRequest(url: story.url, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let html = String(data: data.prefix(1_500_000), encoding: .utf8) else { return nil }
        let result = ArticleExtractor.extract(html: html, baseURL: story.url)
        let text = result.paragraphs.filter { !$0.hasPrefix("•") }.joined(separator: " ")
        guard text.count >= 200 else { return nil }
        return String(text.prefix(900))
    }
}

nonisolated private final class RSSItems: NSObject, XMLParserDelegate {
    var items: [[String: String]] = []
    private var current: [String: String]?
    private var buffer = ""

    static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" { current = [:] }
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item", let current {
            items.append(current)
            self.current = nil
        } else if current != nil, ["title", "link", "pubDate", "source"].contains(name) {
            current?[name] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

@Observable final class QuoteNewsModel {
    enum Phase { case idle, reading, writing, done, failed }

    let symbol: String
    private(set) var stories: [TickerStory]?
    private(set) var brief = ""
    private(set) var phase = Phase.idle
    private var generation: Task<Void, Never>?

    private static var loaded: [String: (at: Date, stories: [TickerStory])] = [:]

    init(symbol: String) {
        self.symbol = symbol
    }

    static var intelligence: Bool { AIRouter.isAvailable(.moveExplanations) }

    static func threshold(instrument: String?) -> Double {
        instrument == nil || instrument == "EQUITY" ? 0.04 : 0.02
    }

    func load(name: String) async {
        if let cached = Self.loaded[symbol + "|" + name], Date.now.timeIntervalSince(cached.at) < 300 { stories = cached.stories; return }
        let found = await TickerNews.stories(symbol: symbol, name: name)
        guard !Task.isCancelled else { return }
        Self.loaded[symbol + "|" + name] = (.now, found)
        stories = found
    }

    private var cacheKey: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.dateComponents([.year, .month, .day], from: .now)
        return "\(symbol)|\(day.year!)-\(day.month!)-\(day.day!)"
    }

    func restore() {
        guard phase == .idle, let saved = (UserDefaults.standard.dictionary(forKey: "moveBriefs") as? [String: String])?[cacheKey] else { return }
        brief = saved
        phase = .done
    }

    func explain(name: String, move: Double, price: String, force: Bool = false) {
        guard Self.intelligence, let stories, !stories.isEmpty else { return }
        guard force || phase == .idle else { return }
        generation?.cancel()
        brief = ""
        phase = .reading
        let symbol = symbol, key = cacheKey
        generation = Task {
            let core = TickerNews.core(name, symbol: symbol)
            let recent = stories.filter { Date.now.timeIntervalSince($0.date) < 60 * 60 * 48 }
            let pool = recent.isEmpty ? Array(stories.prefix(6)) : recent
            let sources = Array(pool.filter(\.tagged).prefix(2))
            var excerpts: [(TickerStory, String)] = []
            await withTaskGroup(of: (TickerStory, String)?.self) { group in
                for story in sources { group.addTask { await TickerNews.excerpt(story, core: core).map { (story, $0) } } }
                for await found in group { if let found { excerpts.append(found) } }
            }
            guard !Task.isCancelled else { return }
            let headlines = pool.prefix(10).map { "- [\($0.date.formatted(.relative(presentation: .named))), \($0.publisher)] \($0.title)" }
            let direction = move >= 0 ? "up" : "down"
            let percent = abs(move).formatted(.percent.precision(.fractionLength(1)))
            let base = "\(name) (\(symbol)) is \(direction) \(percent) today, trading at \(price).\n\nRecent headlines, newest first:\n\(headlines.joined(separator: "\n"))"
            let prompts = excerpts.isEmpty ? [base] : [base + "\n\nArticle excerpts:\n" + excerpts.map { "[\($0.0.publisher)] \($0.0.title)\n\($0.1)" }.joined(separator: "\n\n"), base]
            phase = .writing
            for prompt in prompts {
                let instructions = """
                You explain why a stock or market asset moved today for a news wire, using only the supplied headlines and excerpts. \
                Write two or three short, plain sentences. Lead with the most likely catalyst and name the source when useful. \
                If the material does not clearly explain the move, say no specific catalyst was reported and mention only supported context. \
                Never invent figures, events, or analyst calls. No preamble, markdown, or investment advice.
                """
                do {
                    brief = try await AIRouter.generate(.moveExplanations, instructions: instructions, prompt: prompt, temperature: 0.2, maxTokens: 180) { [weak self] text in
                        if !Task.isCancelled { self?.brief = text }
                    }
                    guard !Task.isCancelled else { return }
                    brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !brief.isEmpty else { continue }
                    phase = .done
                    let today = key.drop { $0 != "|" }
                    var saved = (UserDefaults.standard.dictionary(forKey: "moveBriefs") as? [String: String] ?? [:]).filter { $0.key.hasSuffix(today) }
                    saved[key] = brief
                    UserDefaults.standard.set(saved, forKey: "moveBriefs")
                    return
                } catch is CancellationError {
                    return
                } catch {
                    brief = ""
                }
            }
            phase = .failed
        }
    }
}

struct QuoteNewsSection: View {
    let name: String
    let instrument: String?
    let move: Double?
    let price: String?
    @State private var model: QuoteNewsModel
    @State private var reading: TickerStory?
    @State private var expanded = false

    init(symbol: String, name: String, instrument: String?, move: Double?, price: String?) {
        self.name = name
        self.instrument = instrument
        self.move = move
        self.price = price
        _model = State(initialValue: QuoteNewsModel(symbol: symbol))
    }

    private var big: Bool {
        guard let move else { return false }
        return abs(move) >= QuoteNewsModel.threshold(instrument: instrument)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.stories == nil {
                QuoteSection("News") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(big ? "Finding out why it's moving…" : "Finding stories…").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } else if let stories = model.stories, !stories.isEmpty {
                QuoteSection("News") {
                    if model.phase != .idle { briefCard }
                    else if QuoteNewsModel.intelligence, let move, let price, !big { askButton(move: move, price: price) }
                    VStack(spacing: 0) {
                        ForEach(Array(stories.prefix(expanded ? 14 : 5).enumerated()), id: \.element.id) { index, story in
                            if index > 0 { Divider() }
                            row(story)
                        }
                    }
                    if stories.count > 5 {
                        Button(expanded ? "Show less" : "Show \(stories.count - 5) more") {
                            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .tint(Color.wireAccent)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.stories?.count)
        .animation(.easeOut(duration: 0.2), value: model.phase)
        .task(id: name) {
            model.restore()
            await model.load(name: name)
        }
        .task(id: "\(model.stories?.isEmpty == false)|\(big)") {
            guard big, let move, let price else { return }
            model.explain(name: name, move: move, price: price)
        }
        .fullScreenCover(item: $reading) { SafariView(url: $0.url).ignoresSafeArea() }
    }

    private func askButton(move: Double, price: String) -> some View {
        Button { model.explain(name: name, move: move, price: price) } label: {
            Label("Why is it moving?", systemImage: "apple.intelligence")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .contentShape(.capsule)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(PressSpringStyle())
    }

    private var briefCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "apple.intelligence").symbolEffect(.pulse, isActive: model.phase == .reading || model.phase == .writing)
                Text(model.phase == .reading ? "Reading the news…" : "Why it's moving")
                Spacer(minLength: 0)
                if model.phase == .done || model.phase == .failed, let move, let price {
                    Button { model.explain(name: name, move: move, price: price, force: true) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Regenerate summary")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.wireAccent)
            if model.phase == .failed {
                Text("Apple Intelligence couldn't summarize this move.").font(.subheadline).foregroundStyle(.secondary)
            } else if !model.brief.isEmpty {
                Text(model.brief)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeOut(duration: 0.15), value: model.brief)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([1.0, 0.85, 0.55], id: \.self) { width in
                        Capsule().fill(.secondary.opacity(0.18)).frame(maxWidth: .infinity).frame(height: 10)
                            .scaleEffect(x: width, anchor: .leading)
                    }
                }
                .phaseAnimator([0.5, 1.0]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
            }
            if model.phase == .done {
                Text("Generated on device from recent headlines. May be incomplete.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wireAccent.opacity(0.08), in: .rect(cornerRadius: 16))
    }

    private func row(_ story: TickerStory) -> some View {
        Button { reading = story } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(story.title).font(.subheadline.weight(.semibold)).lineLimit(3).multilineTextAlignment(.leading)
                    Text("\(story.publisher) · \(story.date.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let thumbnail = story.thumbnail {
                    ThumbnailImage(url: thumbnail, size: ThumbnailLoader.small)
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 10))
                }
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
