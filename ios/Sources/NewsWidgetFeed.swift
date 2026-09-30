import WidgetKit

enum NewsWidgetFeed {
    private static var signature = ""
    private static var publishedAt = Date.distantPast

    /// Mirrors the top of the unfiltered feed, plus any recent urgent stories further down, into the app group.
    static func publish(_ stories: [Story]) {
        let now = Date.now
        let urgent = stories.filter { ($0.priority == "breaking" || $0.priority == "urgent") && now.timeIntervalSince($0.publishedAt) < 86_400 }
        var seen = Set<String>()
        let picked = (Array(stories.prefix(24)) + urgent.prefix(10)).filter { seen.insert($0.id).inserted }
        let key = picked.map(\.id).joined(separator: ",")
        guard !picked.isEmpty, key != signature || now.timeIntervalSince(publishedAt) > 600 else { return }
        if signature.isEmpty { WidgetNews.removeLegacyImages() }
        signature = key
        publishedAt = now
        let items = picked.map { story in
            NewsItem(id: story.id, title: story.title, summary: "", source: story.source, published: story.publishedAt,
                     priority: story.priority, category: story.category, tickers: story.tickers, url: story.url)
        }
        WidgetNews(stories: items, updated: now).save()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetNews.kind)
    }
}
