import Testing
@testable import Newswire

struct MarketSearchSelectionTests {
    @Test func newerQuerySubmitsTypedTextInsteadOfPreviousSuggestions() {
        #expect(MarketSearchSelection.symbol(query: "MSFT", matchesQuery: "AAPL", firstMatch: "AAPL") == "MSFT")
    }

    @Test func currentCompanySearchCanSubmitItsTickerMatch() {
        #expect(MarketSearchSelection.symbol(query: "Apple", matchesQuery: "Apple", firstMatch: "AAPL") == "AAPL")
    }

    @Test func clearedQueryCannotSubmitOldSuggestion() {
        #expect(MarketSearchSelection.symbol(query: "  ", matchesQuery: "AAPL", firstMatch: "AAPL") == "")
    }

    @Test func searchRecoveryDistinguishesEmptyFromUnavailableAndRetries() throws {
        #expect(try MarketSearchFixture.empty.matches(attempt: 0).isEmpty)
        #expect(throws: MarketError.self) { try MarketSearchFixture.failure.matches(attempt: 0) }
        #expect(throws: MarketError.self) { try MarketSearchFixture.retry.matches(attempt: 0) }
        #expect(try MarketSearchFixture.retry.matches(attempt: 1).map(\.symbol) == ["AAPL", "MSFT"])
    }

    @Test func cachedSearchResultsSurviveSameQueryRetryButClearForNewQuery() {
        #expect(MarketSearchRecovery.shouldKeepCachedResults(matchesQuery: "Apple", query: "Apple"))
        #expect(!MarketSearchRecovery.shouldKeepCachedResults(matchesQuery: "Apple", query: "Microsoft"))
        #expect(!MarketSearchRecovery.shouldKeepCachedResults(matchesQuery: "Apple", query: ""))
    }
}
