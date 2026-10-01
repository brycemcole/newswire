import Foundation

nonisolated enum ArticleQuality {
    enum Assessment { case invalid, suspicious, usable }

    static func assess(_ text: String) -> Assessment {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .invalid }
        let paragraphs = text.split(whereSeparator: \.isNewline).map(String.init)
        if paragraphs.contains(where: ArticleExtractor.looksLikeCode) { return .invalid }
        if text.contains(/^(?i)(access denied|access to this page has been denied|just a moment|verify you are human|enable javascript|please enable javascript|are you a robot|checking your browser)/) { return .invalid }
        if paragraphs.allSatisfy(ArticleExtractor.isBoilerplate) { return .invalid }
        if text.contains(/(?i)(subscribe to continue|subscribe to read|to continue reading|unlock this article|sign in to continue|remaining content is available)/) { return .suspicious }
        let words = text.split(whereSeparator: \.isWhitespace).count
        if text.count < 700 || words < 100 || paragraphs.count < 2 { return .suspicious }
        if text.hasSuffix("…") || text.hasSuffix("...") { return .suspicious }
        return .usable
    }
}

nonisolated enum ArticleLoader {
    static func load(
        render: Bool,
        rendersFirst: Bool,
        fetch: @Sendable (Bool) async -> ArticleExtractor.Result?,
        rendered: @Sendable () async -> ArticlePage?
    ) async -> ArticlePage? {
        var best: ArticlePage?
        func consider(_ candidate: ArticlePage?) {
            guard var candidate else { return }
            let image = candidate.image ?? best?.image
            let video = candidate.video ?? best?.video
            if ArticleQuality.assess(candidate.text) == .invalid { candidate.text = "" }
            if candidate.text.count > (best?.text.count ?? 0) || best == nil {
                candidate.image = image
                candidate.video = video
                best = candidate
            } else {
                if var previous = best {
                    previous.image = previous.image ?? image
                    previous.video = previous.video ?? video
                    best = previous
                }
            }
        }
        let initial = await fetch(false)
        guard !Task.isCancelled else { return nil }
        if let initial, !rendersFirst || initial.targeted { consider(ArticlePage(initial)) }
        if let initial, initial.complete, (!rendersFirst || initial.targeted),
           ArticleQuality.assess(initial.text) == .usable {
            best?.validated = true
            return best
        }
        guard render else { return best }
        let browserPage = await rendered()
        if let browserPage, ArticleQuality.assess(browserPage.text) != .invalid,
           initial?.complete != true, initial?.targeted != true {
            best?.text = ""
        }
        consider(browserPage)
        guard !Task.isCancelled else { return nil }
        if ArticleQuality.assess(best?.text ?? "") != .usable {
            let retry = await fetch(true)
            guard !Task.isCancelled else { return nil }
            if let retry, !rendersFirst || retry.targeted,
               ArticleQuality.assess(browserPage?.text ?? "") == .invalid || retry.complete || retry.targeted {
                consider(ArticlePage(retry))
            }
        }
        // Short news briefs remain readable after the bounded recovery attempts.
        if !(best?.text.isEmpty ?? true) { best?.validated = true }
        return best
    }
}
