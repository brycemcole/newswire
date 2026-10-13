import Foundation
import Testing
@testable import Newswire

@MainActor
struct RankingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func story(_ id: String, _ title: String, hoursAgo: Double, source: String = "Wire", priority: String = "normal", tickers: [String] = [], tags: [String] = []) -> Story {
        Story(id: id, externalId: id, title: title, summary: "", body: "", source: source, url: URL(string: "https://example.com/\(id)")!,
              publishedAt: now.addingTimeInterval(-hoursAgo * 3600), receivedAt: now, category: "general", priority: priority,
              tickers: tickers, tags: tags, agent: "test", imageUrl: nil)
    }

    @Test func widelyCoveredUnseenStoryLeads() {
        let stories = [
            story("fresh", "Local bakery opens second shop downtown", hoursAgo: 0.2),
            story("a", "Federal Reserve holds interest rates steady amid inflation worries", hoursAgo: 1.5, source: "Reuters"),
            story("b", "Federal Reserve keeps interest rates steady as inflation lingers", hoursAgo: 1.2, source: "Bloomberg"),
            story("c", "Interest rates steady: Federal Reserve cites inflation", hoursAgo: 1.0, source: "CNBC"),
        ]
        let ranked = StoryRanking.rank(stories, seen: [], symbols: [], now: now).map(\.id)
        #expect(["a", "b", "c"].contains(ranked[0]))
        #expect(ranked[1] == "fresh")
    }

    @Test func seenStoriesSinkAndBreakingRises() {
        let stories = [
            story("seen", "Chipmaker unveils new accelerator lineup", hoursAgo: 0.1),
            story("older", "Oil prices climb on supply outage", hoursAgo: 2, priority: "breaking"),
            story("mine", "Analysts weigh quarterly guidance update", hoursAgo: 0.5, tickers: ["NVDA"]),
        ]
        let ranked = StoryRanking.rank(stories, seen: ["seen"], symbols: ["NVDA"], now: now).map(\.id)
        #expect(ranked == ["older", "mine", "seen"])
    }

    @Test func escalationBeatsNewerUnrelatedStockCoverage() {
        let stories = [
            story("dividend", "Acme declares $0.12 quarterly dividend", hoursAgo: 0.1, source: "Seeking Alpha"),
            story("micron", "What is next for Micron stock?", hoursAgo: 0.2),
            story("iran", "Iran increases threat of war as military deployments expand", hoursAgo: 6, priority: "urgent"),
        ]
        #expect(StoryRanking.rank(stories, seen: [], symbols: [], now: now).first?.id == "iran")
    }

    @Test func holdingsMatchExplicitTickersAndCompanyNamesWithoutServerTickers() {
        let stories = [
            story("other", "Unrelated retailer opens downtown outlet", hoursAgo: 0),
            story("held", "Nvidia announces quarterly results", hoursAgo: 1),
            story("watched", "Micron (NASDAQ:MU) raises guidance", hoursAgo: 1),
        ]
        let result = StoryRanking.rank(stories, seen: [], symbols: ["mu"], holdings: ["nvda"], companyNames: ["NVDA": "NVIDIA Corporation"], now: now)
        #expect(result.map(\.id) == ["held", "watched", "other"])
    }

    @Test func routinePayoutsSinkButHeldPayoutsAndDividendCutsRemainRelevant() {
        let stories = [
            story("routine", "Acme declares $0.12 quarterly dividend", hoursAgo: 0, priority: "urgent"),
            story("held", "Microsoft declares $0.90 quarterly dividend", hoursAgo: 1, tickers: ["MSFT"]),
            story("cut", "Retailer suspends dividend as liquidity runs short", hoursAgo: 0.5, priority: "urgent"),
            story("news", "Scientists discover unusual planetary system", hoursAgo: 0),
        ]
        #expect(StoryRanking.rank(stories, seen: [], symbols: [], holdings: ["MSFT"], now: now).map(\.id) == ["cut", "held", "news", "routine"])
    }

    @Test func significanceIsSeparateFromUrgencyAndMaterialTagsOverrideFallback() {
        let stories = [
            story("fresh", "What is next for Micron stock?", hoursAgo: 0),
            story("systemic", "New shipping restrictions take effect", hoursAgo: 4, tags: ["systemic-event"]),
            story("material", "Acme declares dividend following restructuring", hoursAgo: 0, tags: ["material-company-event"]),
        ]
        #expect(StoryRanking.rank(stories, seen: [], symbols: [], now: now).map(\.id) == ["systemic", "material", "fresh"])
    }

    @Test func oldBreakingDoesNotPinTheFeedAndFutureDatesGetNoExtraBoost() {
        let stories = [
            story("old", "Major military escalation reported last week", hoursAgo: 96, priority: "breaking"),
            story("a", "Fresh science discovery", hoursAgo: 0),
            story("b", "Fresh transport report", hoursAgo: -2),
        ]
        #expect(StoryRanking.rank(stories, seen: [], symbols: [], now: now).last?.id == "old")
    }

    @Test func onePublisherCannotManufactureCoverageAndTiesAreStable() {
        let stories = [
            story("a", "Regional factory opens new electric vehicle production line", hoursAgo: 2, source: " Reuters "),
            story("b", "Regional factory opens new electric vehicle production line", hoursAgo: 2, source: "REUTERS"),
            story("fresh", "Astronomers discover distant planetary system", hoursAgo: 0),
        ]
        #expect(StoryRanking.rank(stories, seen: [], symbols: [], now: now).first?.id == "fresh")
        let tied = [story("b", "Different headline entirely", hoursAgo: 0), story("a", "Another unrelated dispatch", hoursAgo: 0)]
        #expect(StoryRanking.rank(tied, seen: [], symbols: [], now: now).map(\.id) == ["a", "b"])
    }

    @Test func freshRoutineArrivalDoesNotDisplaceExistingImportantNews() {
        let existing = story("iran", "Iran announces new military deployments", hoursAgo: 5, priority: "urgent")
        let incoming = story("payout", "Acme declares quarterly dividend", hoursAgo: 0)
        #expect(StoryRanking.rank([incoming, existing], seen: [], symbols: [], now: now).map(\.id) == ["iran", "payout"])
    }
}
