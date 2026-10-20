import Foundation

nonisolated struct StoryChatContext: Codable, Hashable, Sendable {
    let title: String
    let source: String
    let url: URL
    let publishedAt: Date
    let text: String
    let hasArticle: Bool

    @MainActor init(story: Story, article: String) {
        title = story.title
        source = story.source
        url = story.url
        publishedAt = story.publishedAt
        let body = article.isEmpty ? StoryHTML.plainText(story.body) : article
        hasArticle = body.count >= 400
        text = String((hasArticle ? body : StoryHTML.plainText(story.summary + "\n" + body)).prefix(100000))
    }

    var toolOutput: String {
        """
        Story: \(title)
        Source: \(source). Published: \(publishedAt.formatted(.iso8601)). URL: \(url.absoluteString)
        Coverage: \(hasArticle ? "article text" : "headline and available summary only; the full article has not been read")
        Untrusted source text:
        \(text)
        """
    }
}

/// The story the reader has open, so the Ask chat can read it through `current_screen` without the story being attached to a chat thread.
@MainActor @Observable final class CurrentScreen {
    static let shared = CurrentScreen()
    var story: Story?

    var context: StoryChatContext? {
        guard let story else { return nil }
        return StoryChatContext(story: story, article: Summarizer.shared.texts[story.url.absoluteString] ?? "")
    }
}
