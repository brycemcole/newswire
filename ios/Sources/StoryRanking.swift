import Foundation

nonisolated enum StoryRanking {
    private static let stopwords: Set<String> = [
        "that", "this", "with", "from", "after", "over", "into", "amid", "about", "their", "they", "will", "would", "could",
        "says", "said", "than", "more", "have", "been", "what", "when", "where", "which", "while", "report", "reports", "news",
    ]

    /// Ranking compares every pair of titles, so the feed calls this variant to keep it off the main thread.
    @concurrent static func ranked(_ stories: [Story], symbols: Set<String>, holdings: Set<String> = [], companyNames: [String: String] = [:]) async -> [Story] {
        rank(stories, seen: [], symbols: symbols, holdings: holdings, companyNames: companyNames, dropsFiller: true)
    }

    static func rank(_ stories: [Story], seen: Set<String>, symbols: Set<String>, holdings: Set<String> = [], companyNames: [String: String] = [:], dropsFiller: Bool = false, now: Date = .now) -> [Story] {
        guard stories.count > 1 else { return stories }
        let holdings = Set(holdings.map { $0.uppercased() })
        let interests = Set(symbols.map { $0.uppercased() }).union(holdings)
        let names = companyNames.compactMap { symbol, name -> (String, String)? in
            guard interests.contains(symbol.uppercased()) else { return nil }
            let name = normalized(TickerNews.core(name, symbol: symbol))
            return name.count >= 4 ? (symbol.uppercased(), " \(name) ") : nil
        }
        let stories = dropsFiller ? stories.filter { story in
            guard isRoutine(story) else { return true }
            let text = "\(story.title)\n\(story.summary)"
            let searchable = " \(normalized(text)) "
            let tickers = Set((story.tickers + TickerScanner.symbols(in: text)).map { $0.uppercased() })
            return !tickers.isDisjoint(with: interests) || names.contains { searchable.contains($0.1) }
        } : stories
        let words = stories.map(keywords)
        var cluster = Array(stories.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while cluster[index] != index { index = cluster[index] }
            return index
        }
        for a in stories.indices where words[a].count >= 3 {
            for b in stories.indices where b > a && words[b].count >= 3 {
                let shared = words[a].intersection(words[b]).count
                let union = words[a].union(words[b]).count
                if shared >= 3 && Double(shared) / Double(union) >= 0.3 { cluster[root(b)] = root(a) }
            }
        }
        let groups = Dictionary(grouping: stories.indices, by: root)
        var shielded = [Bool](repeating: false, count: stories.count)
        var base: [Double] = stories.indices.map { index in
            let story = stories[index]
            let hours = max(now.timeIntervalSince(story.publishedAt), 0) / 3600
            let freshness = pow(0.5, hours / 8)
            let text = "\(story.title)\n\(story.summary)"
            var tickers = Set((story.tickers + TickerScanner.symbols(in: text)).map { $0.uppercased() })
            let searchable = " \(normalized(text)) "
            for (symbol, name) in names where searchable.contains(name) { tickers.insert(symbol) }
            let held = !tickers.isDisjoint(with: holdings)
            let watched = !tickers.isDisjoint(with: interests)
            let routine = isRoutine(story)
            let priority = routine ? 0.0 : story.priority == "breaking" ? 7.0 : story.priority == "urgent" ? 3.0 : 0
            let systemic = story.tags.contains("systemic-event") ? 3.0 : 0
            shielded[index] = watched || priority > 0 || systemic > 0
            let personal = held ? 2.5 : watched ? 1.5 : 0
            let relevance = routine ? (held ? 0.8 : watched ? 0.5 : 0.15) : 1.0
            return freshness * (1 + max(priority, systemic) + personal) * relevance
        }
        for members in groups.values where members.count > 1 {
            let sources = Set(members.map { normalized(stories[$0].source) }.filter { !$0.isEmpty }).count
            let boost = 1 + min(Double(max(0, sources - 1)) * 0.3, 0.9)
            let lead = members.max { base[$0] < base[$1] }!
            for index in members { base[index] *= index == lead ? boost : 0.55 }
        }
        // One publisher's burst (Seeking Alpha posts dozens of guidance items an hour in earnings season) must not fill the feed.
        // Each further story from a source counts less unless it concerns a holding or watched symbol or is breaking or systemic.
        var perSource: [String: Int] = [:]
        for index in stories.indices.sorted(by: { base[$0] > base[$1] }) where !shielded[index] {
            let source = normalized(stories[index].source)
            guard !source.isEmpty else { continue }
            let rank = perSource[source, default: 0]
            perSource[source] = rank + 1
            base[index] /= 1 + 0.35 * Double(rank)
        }
        for index in stories.indices where seen.contains(stories[index].id) { base[index] *= 0.3 }
        return stories.indices.sorted {
            if base[$0] != base[$1] { return base[$0] > base[$1] }
            if stories[$0].publishedAt != stories[$1].publishedAt { return stories[$0].publishedAt > stories[$1].publishedAt }
            return stories[$0].id < stories[$1].id
        }
            .map { stories[$0] }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    private static func isRoutine(_ story: Story) -> Bool {
        if story.tags.contains("systemic-event") || story.tags.contains("material-company-event") { return false }
        if story.tags.contains("routine-company-update") || story.tags.contains("feature") { return true }
        let title = story.title.lowercased()
        // Older headlines predate significance tags. A payout change must not be treated as a routine declaration.
        if title.range(of: #"\b(cuts?|cutting|suspend\w*|slash\w*|halt\w*|scrap\w*|eliminat\w*|rais\w*|hik\w*|increas\w*|reduc\w*|special)\b"#, options: .regularExpression) != nil { return false }
        return title.range(of: #"\b(declares? .{0,60}dividend|ex.dividend|dividend reminder|dividend picks|dividend stocks|what(?:'s| is) next for .{0,50}stock|stocks? to buy|should you buy)\b"#, options: .regularExpression) != nil
    }

    private static func keywords(_ story: Story) -> Set<String> {
        Set(story.title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) })
    }
}
