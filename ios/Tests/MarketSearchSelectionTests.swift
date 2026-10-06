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
}
