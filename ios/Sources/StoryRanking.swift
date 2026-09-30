import Foundation

nonisolated enum StoryRanking {
    private static let stopwords: Set<String> = [
        "that", "this", "with", "from", "after", "over", "into", "amid", "about", "their", "they", "will", "would", "could",
        "says", "said", "than", "more", "have", "been", "what", "when", "where", "which", "while", "report", "reports", "news",
    ]

    /// Ranking compares every pair of titles, so the feed calls this variant to keep it off the main thread.
    @concurrent static func ranked(_ stories: [Story], symbols: Set<String>) async -> [Story] {
        rank(stories, seen: [], symbols: symbols)
    }

    static func rank(_ stories: [Story], seen: Set<String>, symbols: Set<String>, now: Date = .now) -> [Story] {
        guard stories.count > 1 else { return stories }
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
        var base: [Double] = stories.map { story in
            let hours = max(now.timeIntervalSince(story.publishedAt), 0) / 3600
            let freshness = pow(0.5, hours / 4)
            let priority = story.priority == "breaking" ? 1.0 : story.priority == "urgent" ? 0.5 : 0
            let personal = story.tickers.contains { symbols.contains($0.uppercased()) } ? 0.3 : 0
            return freshness * (1 + priority + personal)
        }
        for members in groups.values where members.count > 1 {
            let sources = Set(members.map { stories[$0].source.lowercased() }).count
            let boost = 1 + min(Double(sources - 1) * 0.3, 1.2)
            let lead = members.max { base[$0] < base[$1] }!
            for index in members { base[index] *= index == lead ? boost : 0.55 }
        }
        for index in stories.indices where seen.contains(stories[index].id) { base[index] *= 0.3 }
        return stories.indices.sorted { base[$0] != base[$1] ? base[$0] > base[$1] : stories[$0].publishedAt > stories[$1].publishedAt }
            .map { stories[$0] }
    }

    private static func keywords(_ story: Story) -> Set<String> {
        Set(story.title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) })
    }
}
