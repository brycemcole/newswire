#if DEBUG
import SwiftUI

struct ArticleReaderPreview: View {
    let url: URL

    var body: some View {
        NavigationStack {
            StoryDetail(story: Story(id: url.absoluteString, externalId: "article-preview", title: "Article recovery test", summary: "", body: "", source: "Reader QA", url: url, publishedAt: .now, receivedAt: .now, category: "economy", priority: "normal", tickers: [], tags: ["headlines"], agent: "preview", imageUrl: nil))
        }
    }
}

struct StoryDesignPreview: View {
    @State private var store = FeedStore()
    private static func story(_ id: String, _ title: String, source: String, minutes: Double, category: String = "economy", tickers: [String] = [], body: String = "") -> Story {
        let url = URL(string: "https://example.com/\(id)")!
        return Story(id: id, externalId: id, title: title, summary: "", body: body, source: source, url: url, publishedAt: .now.addingTimeInterval(-minutes * 60), receivedAt: .now, category: category, priority: "normal", tickers: tickers, tags: ["headlines"], agent: "preview", imageUrl: nil)
    }
    private let main = story("main", "[TEST] Fed holds rates steady, signals two cuts before year end", source: "Reuters", minutes: 42, body: "Matched watchlist: Fed, Inflation. Headline and link as published by Reuters.")

    var body: some View {
        NavigationStack {
            StoryDetail(story: main)
                .navigationDestination(for: Story.self) { StoryDetail(story: $0) }
        }
        .environment(\.feedStore, store)
        .task {
            let paragraphs = Array(repeating: "Federal Reserve officials left the benchmark rate unchanged on Wednesday, pointing to cooling inflation and a steady labor market while keeping the door open to easing later this year.", count: 6)
            Summarizer.shared.seedPreview(key: main.url.absoluteString, text: paragraphs.joined(separator: "\n"), glance: [
                "The Fed kept its benchmark rate at 4.25% to 4.5% for a fifth straight meeting.",
                "Officials now project two quarter-point cuts by December, up from one in June.",
                "Core inflation slowed to 2.6% in August, the lowest reading since 2021.",
            ], brief: CommandLine.arguments.contains("-storyDesignMore") ? "Policymakers voted 11 to 1 to hold rates. Chair Powell said the committee wants more evidence that inflation is settling before it moves.\n\nMarkets had priced in a September cut, so Treasury yields rose after the decision." : nil)
            try? await Task.sleep(for: .milliseconds(600))
            store.stories = [main,
                Self.story("a", "[TEST] Treasury yields climb as traders pare back rate-cut bets", source: "Bloomberg", minutes: 25, body: "Matched watchlist: Fed. x."),
                Self.story("b", "[TEST] Core PCE inflation cools for a third month", source: "WSJ", minutes: 180, body: "Matched watchlist: Inflation. x."),
                Self.story("c", "[TEST] Mortgage rates dip to lowest level since spring", source: "CNBC", minutes: 300),
            ]
        }
    }
}
#endif
