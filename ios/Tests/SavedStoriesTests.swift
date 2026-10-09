import Foundation
import Testing
@testable import Newswire

struct SavedStoriesTests {
    @Test func snapshotsPersistAndFilteredRemovalTargetsStableStoryIdentity() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = story(id: "wire:one", title: "Rates hold", tickers: ["SPY"])
        let second = story(id: "wire:two", title: "Earnings", tickers: ["AAPL"])
        let store = SavedStories(defaults: defaults)
        store.toggle(first, articleText: "Offline body for rates")
        store.toggle(second, articleText: nil)

        let relaunched = SavedStories(defaults: defaults)
        #expect(relaunched.items.map(\.id) == [second.id, first.id])
        #expect(relaunched.items.first(where: { $0.id == first.id })?.articleText == "Offline body for rates")
        #expect(relaunched.search("offline body").map(\.id) == [first.id])
        #expect(relaunched.search("aapl").map(\.id) == [second.id])

        relaunched.remove(first)
        #expect(SavedStories(defaults: defaults).items.map(\.id) == [second.id])
    }

    @Test func snapshotsBoundFieldsAndKeepMostRecentHundredStories() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedStories(defaults: defaults)
        let oldest = story(id: "wire:0", title: "Oldest")
        for index in 0...100 {
            let item = story(id: "wire:\(index)", title: index == 100 ? String(repeating: "T", count: 700) : "Story \(index)",
                             summary: String(repeating: "S", count: 12_000), body: String(repeating: "B", count: 22_000))
            store.toggle(item, articleText: String(repeating: "A", count: 45_000))
        }

        #expect(store.items.count == 100)
        #expect(!store.contains(oldest))
        let newest = try #require(store.items.first)
        #expect(newest.id == "wire:100")
        #expect(newest.story.title.count == 500)
        #expect(newest.story.summary.count == 10_000)
        #expect(newest.story.body.count == 20_000)
        #expect(newest.articleText?.count == 40_000)
        #expect(SavedStories(defaults: defaults).items.count == 100)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "SavedStoriesTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func story(id: String, title: String, summary: String = "Summary", body: String = "Body", tickers: [String] = []) -> Story {
        Story(id: id, externalId: id, title: title, summary: summary, body: body, source: "Test Source",
              url: URL(string: "https://example.com/\(id.replacingOccurrences(of: ":", with: "-"))")!,
              publishedAt: Date(timeIntervalSince1970: 1_700_000_000), receivedAt: Date(timeIntervalSince1970: 1_700_000_001),
              category: "markets", priority: "normal", tickers: tickers, tags: ["test"], agent: "wire", imageUrl: nil)
    }
}
