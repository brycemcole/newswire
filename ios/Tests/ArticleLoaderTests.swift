import Foundation
import Testing
@testable import Newswire

struct ArticleLoaderTests {
    private let opening = "Officials announced a change to energy policy today, explaining the expected effects on fuel prices, supply and trade. The plan remains under review while advisers gather information from producers and consumers. "
    private var full: String { (1...8).map { "Paragraph \($0): " + opening.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") }
    private func result(_ text: String, complete: Bool = true) -> ArticleExtractor.Result {
        .init(paragraphs: text.components(separatedBy: "\n"), image: nil, complete: complete)
    }

    @Test func identifiesEmptyCodeChallengesAndTeasers() {
        #expect(ArticleQuality.assess(" \n") == .invalid)
        #expect(ArticleQuality.assess("const state = {data: [1, 2, 3]}; window.render(state)") == .invalid)
        #expect(ArticleQuality.assess("Verify you are human to continue.") == .invalid)
        #expect(ArticleQuality.assess(opening) == .suspicious)
        #expect(ArticleQuality.assess(full + "Subscribe to continue reading") == .suspicious)
        #expect(ArticleQuality.assess(full) == .usable)
    }

    @Test func shortStaticContentAutomaticallyUsesRenderedFallback() async {
        let short = result(opening)
        let full = full
        let page = await ArticleLoader.load(render: true, rendersFirst: false, fetch: { _ in short }, rendered: {
            ArticlePage(text: full, image: nil, video: nil)
        })
        #expect(page?.text == full)
        #expect(page?.validated == true)
    }

    @Test func blankAndBrokenRenderedContentRetryTheFetch() async {
        let empty = result("")
        let recovered = result(full)
        let page = await ArticleLoader.load(render: true, rendersFirst: false, fetch: { retry in retry ? recovered : empty }, rendered: {
            ArticlePage(text: "function () { window.bad(); }", image: nil, video: nil)
        })
        #expect(page?.text == full)
    }

    @Test func prefetchDoesNotValidateShortContentOrCreateWebViews() async {
        let short = result(opening)
        let page = await ArticleLoader.load(render: false, rendersFirst: false, fetch: { _ in short }, rendered: {
            Issue.record("Prefetch should not render")
            return nil
        })
        #expect(page?.text == opening)
        #expect(page?.validated == false)
    }

    @Test func boundedRecoveryPreservesRealShortBriefsAndLongerCandidates() async {
        let brief = result(opening)
        let page = await ArticleLoader.load(render: true, rendersFirst: false, fetch: { _ in brief }, rendered: { nil })
        #expect(page?.text == opening)
        #expect(page?.validated == true)
        var larger = result(full, complete: false)
        larger.targeted = true
        let trusted = larger
        let full = full
        let longer = await ArticleLoader.load(render: true, rendersFirst: false, fetch: { _ in trusted }, rendered: {
            ArticlePage(text: "Short teaser", image: nil, video: nil)
        })
        #expect(longer?.text == full)
    }

    @Test func readerKeepsMoreThanSixThousandCharacters() {
        let paragraphs = (0..<100).map { "Paragraph \($0): " + opening }
        let html = "<script type=\"application/ld+json\">" + String(data: try! JSONEncoder().encode(["articleBody": paragraphs.joined(separator: "\n")]), encoding: .utf8)! + "</script>"
        let extracted = ArticleExtractor.extract(html: html, baseURL: URL(string: "https://example.com")!)
        #expect(extracted.text.count > 6000)
        #expect(extracted.text.contains("Paragraph 99:"))
    }

    @Test func fullStructuredBodyWinsOverShortContainer() {
        let html = "<div itemprop=\"articleBody\"><p>" + opening + "</p></div><script>" + String(data: try! JSONEncoder().encode(["articleBody": full]), encoding: .utf8)! + "</script>"
        #expect(ArticleExtractor.extract(html: html, baseURL: URL(string: "https://example.com")!).text == full.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    @Test func articleContainerStopsBeforeRelatedStories() {
        let html = "<div itemprop='articleBody'><div><p>" + opening + "</p></div></div><p>" + full + "</p>"
        let extracted = ArticleExtractor.extract(html: html, baseURL: URL(string: "https://example.com")!)
        #expect(extracted.targeted)
        #expect(extracted.paragraphs.count == 1)
        #expect(extracted.text == opening.trimmingCharacters(in: .whitespaces))
    }

    @Test func untrustedPageTextCannotWinOnRenderedPublishers() async {
        let unrelated = result(full)
        let opening = opening
        let page = await ArticleLoader.load(render: true, rendersFirst: true, fetch: { _ in unrelated }, rendered: {
            ArticlePage(text: opening, image: nil, video: nil)
        })
        #expect(page?.text == opening)
    }

    @Test func renderedArticleWinsOverLongerUnscopedPageText() async {
        let unrelated = result(full, complete: false)
        let opening = opening
        let page = await ArticleLoader.load(render: true, rendersFirst: false, fetch: { _ in unrelated }, rendered: {
            ArticlePage(text: opening, image: nil, video: nil)
        })
        #expect(page?.text == opening)
    }

}
