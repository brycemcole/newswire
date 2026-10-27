import Foundation
import Testing
@testable import Newswire

struct QuoteInlineTests {
    private func quote(_ symbol: String, name: String, change: Double) -> Quote {
        Quote(symbol: symbol, name: name, match: nil, currency: "USD", exchange: "NASDAQ", state: "closed",
              price: 100, change: change, changePercent: change, previousClose: 100 - change,
              time: Date(timeIntervalSince1970: 1_790_000_000), extended: nil, points: [], extendedPoints: [],
              url: URL(string: "https://example.com/\(symbol)")!)
    }

    @Test func batchKeepsFirstMentionPlacementAndQuoteFormatting() {
        let quotes = [quote("AAPL", name: "Apple Inc.", change: 1.25), quote("MSFT", name: "Microsoft Corporation", change: -2)]
        let paragraphs = ["Apple and Microsoft moved today.", "Apple Inc. and Microsoft appeared again.", "Pineapple is not a ticker mention."]
        let plan = QuoteInline.plan(paragraphs, quotes: quotes)
        let annotated = QuoteInline.annotate(paragraphs, quotes: quotes)
        for index in paragraphs.indices {
            #expect(annotated[index] == QuoteInline.annotate(paragraphs[index], quotes: plan[index] ?? []))
        }
        #expect(String(annotated[0].characters).contains("AAPL"))
        #expect(String(annotated[0].characters).contains("MSFT"))
        #expect(String(annotated[1].characters) == paragraphs[1])
        #expect(String(annotated[2].characters) == paragraphs[2])
    }

    @Test func emptyAndUnmatchedQuotesPreserveAllText() {
        #expect(QuoteInline.annotate([String](), quotes: []).isEmpty)
        let paragraphs = ["", "Rates were unchanged.", "Another paragraph."]
        for quotes in [[], [quote("AAPL", name: "Apple Inc.", change: 0)]] {
            #expect(QuoteInline.annotate(paragraphs, quotes: quotes).map { String($0.characters) } == paragraphs)
        }
    }

    @Test func longArticleMatchesThePreviousRendering() {
        let quotes = [quote("AAPL", name: "Apple Inc.", change: 0), quote("MSFT", name: "Microsoft Corporation", change: -2)]
        var paragraphs = (0..<200).map { "Paragraph \($0): Officials discussed the outlook for employment, interest rates and consumer demand while investors reviewed the latest reports." }
        paragraphs[198] += " Apple Inc. reported earnings."
        paragraphs[199] += " Microsoft Corporation also reported."
        let start = ContinuousClock.now
        let previous = paragraphs.enumerated().map { index, paragraph in
            QuoteInline.annotate(paragraph, quotes: QuoteInline.plan(paragraphs, quotes: quotes)[index] ?? [])
        }
        let previousDuration = start.duration(to: .now)
        let batchStart = ContinuousClock.now
        let batched = QuoteInline.annotate(paragraphs, quotes: quotes)
        let batchDuration = batchStart.duration(to: .now)
        #expect(batched == previous)
        print("ARTICLE_ANNOTATION previous=\(previousDuration) batched=\(batchDuration) paragraphs=\(paragraphs.count)")
    }
}
