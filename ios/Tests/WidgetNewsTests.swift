import Foundation
import Testing
@testable import Newswire

struct WidgetNewsTests {
    private func item(_ id: String, _ priority: String, minutesAgo: Double, now: Date) -> NewsItem {
        NewsItem(id: id, title: id, summary: "", source: "Wire", published: now.addingTimeInterval(-minutesAgo * 60),
                 priority: priority, category: "markets", tickers: [], url: URL(string: "https://example.com/\(id)")!)
    }

    @Test func rotationPrefersRecentUrgentStoriesNewestFirst() {
        let now = Date.now
        let news = WidgetNews(stories: [
            item("calm", "normal", minutesAgo: 1, now: now),
            item("old", "breaking", minutesAgo: 13 * 60, now: now),
            item("a", "urgent", minutesAgo: 30, now: now),
            item("b", "breaking", minutesAgo: 5, now: now),
            item("c", "urgent", minutesAgo: 90, now: now),
        ], updated: now)
        #expect(news.rotation(at: now).map(\.id) == ["b", "a", "c"])
        #expect(news.lead(at: now, step: 4)?.id == "a")
        #expect(news.urgentCount(at: now) == 4)
    }

    @Test func rotationFillsWithLatestWhenFewUrgent() {
        let now = Date.now
        let news = WidgetNews(stories: [
            item("one", "normal", minutesAgo: 2, now: now),
            item("hot", "urgent", minutesAgo: 10, now: now),
            item("two", "normal", minutesAgo: 20, now: now),
        ], updated: now)
        #expect(news.rotation(at: now).map(\.id) == ["hot", "one", "two"])
    }
}
