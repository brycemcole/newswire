import Foundation
import Testing
@testable import Newswire

@MainActor struct StoryLensTests {
    private var context: StoryChatContext { StoryChatContext(story: StoryLensFixture.story, article: StoryLensFixture.article) }

    private func raw(stocks: [[String: String]], questions: [String] = StoryLensReport.fallbackQuestions) throws -> String {
        let value: [String: Any] = ["market": "Higher AI investment could help some index constituents; the story alone does not establish an index move.",
            "uncertainty": "No new revenue guidance was given.", "stocks": stocks, "watch": ["Whether orders turn into delivered processors."], "questions": questions]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    @Test func inventedEvidenceAndInvalidTickersNeverBecomeStockSuggestions() throws {
        let valid = ["symbol": "NVDA", "company": "Nvidia", "reason": "The company discusses processor demand.", "evidence": "Nvidia said demand for its data-center processors continued to grow"]
        let invented = ["symbol": "AAPL", "company": "Apple", "reason": "An invented order.", "evidence": "Apple committed to buying ten million processors."]
        var malformed = valid; malformed["symbol"] = "NOT A TICKER"
        let report = try StoryLensReport.decode(raw(stocks: [valid, invented, malformed, valid]), context: context)
        #expect(report.stocks.map(\.symbol) == ["NVDA"])
    }

    @Test func aRealTickerMustMatchTheSuggestedCompany() {
        let stock = StoryLensReport.Stock(symbol: "NVDA", company: "Nvidia", reason: "Demand", evidence: "Nvidia said demand")
        let quote = Quote(symbol: "NVDA", name: "NVIDIA Corporation", match: nil, currency: "USD", exchange: "NASDAQ", state: "closed",
            price: 1, change: 0, changePercent: 0, previousClose: 1, time: .now, extended: nil, points: [], extendedPoints: [], url: context.url)
        #expect(StoryLensReport.matches(stock, quote: quote))
        #expect(!StoryLensReport.matches(.init(symbol: "NVDA", company: "Apple", reason: "Wrong company", evidence: "Nvidia said demand"), quote: quote))
    }

    @Test func indirectExposureIsNeverPresentedAsAMentionedCompany() {
        let direct = StoryLensReport.Stock(symbol: "NVDA", company: "Nvidia", reason: "Demand", evidence: "Nvidia said demand")
        let indirect = StoryLensReport.Stock(symbol: "MSFT", company: "Microsoft", reason: "Could be exposed to AI demand.", evidence: "customers expanded their AI infrastructure")
        #expect(StoryLensReport.mentioned(direct, in: context))
        #expect(!StoryLensReport.mentioned(indirect, in: context))
    }

    @Test func contentChangesInvalidateTheCacheAndMissingArticlesStayExplicit() {
        let partial = StoryChatContext(story: Story(id: "partial", externalId: "partial", title: "A headline", summary: "A short summary", body: "", source: "Test",
            url: context.url, publishedAt: .now, receivedAt: .now, category: "markets", priority: "normal", tickers: [], tags: [], agent: "test", imageUrl: nil), article: "")
        #expect(!partial.hasArticle)
        #expect(partial.prompt.contains("full article has not been read"))
        #expect(context.hasArticle)
        #expect(context.cacheKey != StoryChatContext(story: StoryLensFixture.story, article: StoryLensFixture.article + " A correction was added.").cacheKey)
        #expect(context.chatInstructions.contains(context.title))
        #expect(context.chatInstructions.contains(context.url.absoluteString))
    }

    @Test func duplicateOrMalformedGeneratedQuestionsKeepUsefulFallbacks() throws {
        let report = try StoryLensReport.decode(raw(stocks: [], questions: ["Same?", "same?", ""]), context: context)
        #expect(report.questions == StoryLensReport.fallbackQuestions)
    }

    @Test func concurrentAndRepeatedReadsReuseThePersistedAnalysis() async throws {
        actor Counter { var value = 0; func increment() { value += 1 } }
        let file = URL.temporaryDirectory.appending(path: "story-lens-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = StoryLensCache(file: file)
        let count = Counter()
        let report = try StoryLensReport.decode(raw(stocks: []), context: context)
        let generate: @Sendable () async throws -> StoryLensReport = {
            await count.increment()
            try await Task.sleep(for: .milliseconds(20))
            return report
        }
        async let first = cache.report(key: "same-article", generate: generate)
        async let second = cache.report(key: "same-article", generate: generate)
        let results = try await (first, second)
        #expect(results.0.market == results.1.market)
        #expect(await count.value == 1)
        _ = try await StoryLensCache(file: file).report(key: "same-article", generate: generate)
        #expect(await count.value == 1)
        _ = try await cache.report(key: "corrected-article", generate: generate)
        #expect(await count.value == 2)
    }

    @Test func savedChatsKeepTheArticleAndLegacyChatsStillDecode() throws {
        let thread = ChatThread(name: "Story", story: context)
        let restored = try JSONDecoder().decode(ChatThread.self, from: JSONEncoder().encode(thread))
        #expect(restored.story?.text == context.text)
        #expect(restored.story?.url == context.url)
        let old = "{\"id\":\"\(UUID())\",\"symbol\":\"\",\"name\":\"Markets\",\"updated\":0,\"messages\":[]}"
        #expect(try JSONDecoder().decode(ChatThread.self, from: Data(old.utf8)).story == nil)
    }

    @Test func storyAnswersIncludeTheOriginalSourceWithoutDuplicates() async {
        let research = StockResearchTools(symbol: "", name: "Markets") { _ in }
        await research.includeStory(context)
        await research.includeStory(context)
        #expect(await research.sources.count == 1)
        #expect(await research.sources.first?.url == context.url)
    }

    @Test func aTemporaryFailureOrMalformedAnswerRecoversWithoutTappingRetry() async throws {
        actor Attempts {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let answer = try raw(stocks: [])
        let network = Attempts()
        let recovered = try await StoryLensReport.generate(context: context, retryDelay: .zero) { _ in
            if await network.next() == 1 { throw WireError.status(503) }
            return answer
        }
        #expect(recovered.stocks.isEmpty)
        #expect(await network.count == 2)
        let malformed = Attempts()
        _ = try await StoryLensReport.generate(context: context, retryDelay: .zero) { _ in
            await malformed.next() == 1 ? "{\"market\":" : answer
        }
        #expect(await malformed.count == 2)
    }

    @Test func retriesAreBoundedAndConfigurationFailuresNeverRetry() async throws {
        actor Attempts {
            var count = 0
            func increment() { count += 1 }
        }
        let attempts = Attempts()
        await #expect(throws: WireError.self) {
            try await StoryLensReport.generate(context: context, retryDelay: .zero) { _ in
                await attempts.increment()
                throw WireError.status(502)
            }
        }
        #expect(await attempts.count == 2)
        #expect(!StoryLensFailure.canRetry(WireError.configuration))
        #expect(!StoryLensFailure.canRetry(StockAIError.missingKey))
        #expect(!StoryLensFailure.canRetry(CancellationError()))
        #expect(!StoryLensFailure.canRetry(URLError(.notConnectedToInternet)))
        #expect(StoryLensFailure.message(URLError(.notConnectedToInternet)).contains("internet"))
        #expect(StoryLensFailure.message(StockAIError.missingKey).contains("API key"))
    }

    @Test func failedLensesCanRecoverOnAnExplicitReload() async throws {
        actor Attempts {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let file = URL.temporaryDirectory.appending(path: "lens-retry-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let attempts = Attempts()
        let answer = try raw(stocks: [])
        let lenses = StoryLenses(cache: StoryLensCache(file: file)) { _ in
            if await attempts.next() == 1 { throw WireError.configuration }
            return answer
        }
        await lenses.load(context)
        #expect(lenses.error != nil)
        #expect(!lenses.loading)
        await lenses.load(context, retry: true)
        #expect(lenses.error == nil)
        #expect(lenses.report != nil)
        #expect(await attempts.count == 2)
    }
}
