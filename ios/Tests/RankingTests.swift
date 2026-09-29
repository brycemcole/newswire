import Foundation
import Testing
@testable import Newswire

@MainActor
struct RankingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func story(_ id: String, _ title: String, hoursAgo: Double, source: String = "Wire", priority: String = "normal", tickers: [String] = []) -> Story {
        Story(id: id, externalId: id, title: title, summary: "", body: "", source: source, url: URL(string: "https://example.com/\(id)")!,
              publishedAt: now.addingTimeInterval(-hoursAgo * 3600), receivedAt: now, category: "general", priority: priority,
              tickers: tickers, tags: [], agent: "test", imageUrl: nil)
    }

    @Test func widelyCoveredUnseenStoryLeads() {
        let stories = [
            story("fresh", "Local bakery opens second shop downtown", hoursAgo: 0.2),
            story("a", "Federal Reserve holds interest rates steady amid inflation worries", hoursAgo: 1.5, source: "Reuters"),
            story("b", "Federal Reserve keeps interest rates steady as inflation lingers", hoursAgo: 1.2, source: "Bloomberg"),
            story("c", "Interest rates steady: Federal Reserve cites inflation", hoursAgo: 1.0, source: "CNBC"),
        ]
        let ranked = StoryRanking.rank(stories, seen: [], symbols: [], now: now).map(\.id)
        #expect(["a", "b", "c"].contains(ranked[0]))
        #expect(ranked[1] == "fresh")
    }

    @Test func seenStoriesSinkAndBreakingRises() {
        let stories = [
            story("seen", "Chipmaker unveils new accelerator lineup", hoursAgo: 0.1),
            story("older", "Oil prices climb on supply outage", hoursAgo: 2, priority: "breaking"),
            story("mine", "Analysts weigh quarterly guidance update", hoursAgo: 0.5, tickers: ["NVDA"]),
        ]
        let ranked = StoryRanking.rank(stories, seen: ["seen"], symbols: ["NVDA"], now: now).map(\.id)
        #expect(ranked == ["older", "mine", "seen"])
    }
}
