import Foundation
import Testing
@testable import Newswire

struct ContractTests {
    @Test(arguments: ["2026-09-06T14:30:00Z", "2026-09-06T14:30:00.123Z", "2026-09-06T10:30:00-04:00"])
    func decodesContract(timestamp: String) throws {
        let json = """
        {"stories":[{"id":"test-id","external_id":"test:1","title":"Contract fixture","summary":"","body":"","source":"Test","url":"https://example.com/story","published_at":"\(timestamp)","received_at":"2026-09-06T14:30:01.000Z","category":"technology","priority":"breaking","tickers":[],"tags":["test"],"agent":"test"}],"next_cursor":"opaque+/=cursor"}
        """
        let page = try NewswireAPI.decoder().decode(StoryPage.self, from: Data(json.utf8))
        #expect(page.nextCursor == "opaque+/=cursor")
        let story = try #require(page.stories.first)
        #expect(story.externalId == "test:1")
        #expect(story.priority == "breaking")
        #expect(story.tags == ["test"])
    }

    @Test func emptyPageAndServerError() throws {
        let page = try NewswireAPI.decoder().decode(StoryPage.self, from: Data(#"{"stories":[],"next_cursor":null}"#.utf8))
        #expect(page.stories.isEmpty && page.nextCursor == nil)
        let error = try NewswireAPI.decoder().decode(APIError.self, from: Data(#"{"error":{"code":"unauthorized","message":"Invalid token"}}"#.utf8))
        #expect(error.errorDescription == "Invalid token")
    }

    @Test(arguments: ["http://example.com", "https://user:secret@example.com", "https://example.com?token=x", "https://example.com#fragment", ""])
    func rejectsUnsafeServerURL(value: String) {
        #expect(NewswireAPI.validatedURL(value) == nil)
    }

    @Test func detectsHTMLBodies() {
        #expect(StoryHTML.isHTML("<p>First paragraph.</p><p>Second.</p>"))
        #expect(StoryHTML.isHTML("Lead in<br>then a break"))
        #expect(StoryHTML.isHTML("<STRONG>shouting</STRONG>"))
        #expect(!StoryHTML.isHTML("Rates rose to 5 < 6 percent today"))
        #expect(!StoryHTML.isHTML("Use Array<String> in Swift"))
        #expect(!StoryHTML.isHTML("Plain text report with no markup."))
    }

    @Test func splitsParagraphsAndDecodesEntities() {
        let blocks = StoryHTML.parse("<p>Fed &amp; ECB meet &lt;today&gt;&#8230;</p><p>  Second \n  paragraph </p>")
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0.kind == .paragraph })
        #expect(String(blocks[0].content.characters) == "Fed & ECB meet <today>…")
        #expect(String(blocks[1].content.characters) == "Second paragraph")
    }

    @Test func rendersInlineStylesAndLinks() throws {
        let blocks = StoryHTML.parse(#"<p><strong>Bold</strong> and <em>italic</em>, see <a href="https://example.com/a?x=1&amp;y=2">notes</a>.</p>"#)
        let content = try #require(blocks.first).content
        var sawBold = false
        var sawItalic = false
        var link: URL?
        for run in content.runs {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { sawBold = true }
                if intent.contains(.emphasized) { sawItalic = true }
            }
            if let runLink = run.link { link = runLink }
        }
        #expect(sawBold && sawItalic)
        #expect(link?.absoluteString == "https://example.com/a?x=1&y=2")
    }

    @Test func rendersListsHeadingsQuotesAndRules() {
        let blocks = StoryHTML.parse("<h2>Header</h2><ul><li>alpha</li><li>beta</li></ul><ol><li>one</li></ol><blockquote>quoted text</blockquote><hr>")
        #expect(blocks.map(\.kind) == [.heading(2), .listItem(marker: "•"), .listItem(marker: "•"), .listItem(marker: "1."), .quote, .rule])
    }

    @Test func rendersEncodedLinksAndSummaryMarkup() throws {
        let encoded = "&lt;p&gt;Read &lt;a href=&quot;https://example.com/report&quot;&gt;the report&lt;/a&gt;.&lt;/p&gt;"
        let blocks = StoryHTML.parse(encoded)
        let content = try #require(blocks.first).content
        #expect(String(content.characters) == "Read the report.")
        #expect(content.runs.contains { $0.link == URL(string: "https://example.com/report") })
        #expect(StoryHTML.plainText("<a href='https://example.com'>Source</a>") == "Source")
        #expect(StoryHTML.plainText("&amp;lt;p&amp;gt;Report&amp;lt;/p&amp;gt;") == "Report")
        #expect(StoryHTML.plainText("Rates < 6 &amp; rising") == "Rates < 6 & rising")
    }

    @Test func dropsScriptAndStyleContent() {
        let blocks = StoryHTML.parse(#"<p>Hello</p><script type="text/javascript">var x = 1;</script><style>.a { color: red; }</style><p>World</p>"#)
        #expect(blocks.map { String($0.content.characters) }.joined() == "HelloWorld")
    }

    @Test func preservesPreformattedAndLineBreaks() {
        let blocks = StoryHTML.parse("<p>line one<br>line two</p><pre>  keep  spacing\nnew line</pre>")
        #expect(blocks[0].kind == .paragraph)
        #expect(String(blocks[0].content.characters) == "line one\nline two")
        #expect(blocks[1].kind == .pre)
        #expect(String(blocks[1].content.characters) == "  keep  spacing\nnew line")
    }

    @Test func flushesUnclosedFinalBlock() {
        let blocks = StoryHTML.parse("<p>First</p><p>Second")
        #expect(blocks.count == 2)
        #expect(String(blocks[1].content.characters) == "Second")
        let plain = StoryHTML.parse("no markup at all")
        #expect(plain.count == 1 && String(plain[0].content.characters) == "no markup at all")
    }

    @Test func articleExtractionSkipsScriptsSvgAndCards() {
        let html = """
        <html><head><script>var x = "<p>fake</p>";</script></head><body>
        <svg><path d="M0 0"></path></svg><picture><img src="a.jpg"></picture>
        <button>Close dialogue</button>
        <p>The real opening paragraph of the article explains what happened today in detail.</p>
        <script>document.addEventListener('DOMContentLoaded', function () { const a = 1; });</p></script>
        <p>34||h1?t[1]=i:t.push(i)}else t[0]&&t[0].headers&&e(t[0].headers,o)&&(this.dt=o)})</p>
        <ul><li><div><a href="/other">Related story headline that should not appear</a></div></li></ul>
        </body></html>
        """
        let result = ArticleExtractor.extract(html: html, baseURL: URL(string: "https://example.com")!)
        #expect(result.paragraphs == ["The real opening paragraph of the article explains what happened today in detail."])
    }

    @Test func articleExtractionPrefersEmbeddedArticleHTML() {
        let html = #"""
        <p>If you type a company or ETF ticker symbol in capital letters we will automatically link to the symbol page.</p>
        <script>{"title":"Earnings","content":"\u003Cp\u003EMajor earnings expected before the bell on Monday include:\u003C\u002Fp\u003E\u003Cul\u003E\u003Cli\u003EKandi Technologies Group (\u003Ca href=\"\u002Fsymbol\u002FKNDI\"\u003EKNDI\u003C\u002Fa\u003E)\u003C\u002Fli\u003E\u003C\u002Ful\u003E"}</script>
        """#
        let result = ArticleExtractor.extract(html: html, baseURL: URL(string: "https://example.com")!)
        #expect(result.paragraphs == ["Major earnings expected before the bell on Monday include:", "• Kandi Technologies Group (KNDI)"])
        #expect(result.complete)
    }
}
