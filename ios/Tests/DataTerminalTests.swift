import Foundation
import Testing
@testable import Newswire

struct DataTerminalTests {
    @Test func functionCodesOpenDataRoutes() {
        #expect(TerminalCommand.parse("eco")?.token == "data:calendar")
        #expect(TerminalCommand.parse("WIRP")?.token == "data:fed/odds")
        #expect(TerminalCommand.parse("wei")?.token == "data:board/world")
        #expect(TerminalCommand.parse("UNRATE")?.token == "data:series/UNRATE")
        #expect(TerminalCommand.parse("FRED japan cpi")?.token == "data:series/search?q=japan%20cpi")
        #expect(TerminalCommand.parse("AAPL HDS")?.token == "data:sec/holders?symbol=AAPL")
        #expect(TerminalCommand.parse("EQS jp")?.token == "data:screener?region=jp")
        #expect(TerminalCommand.parse("AAPL") == nil)
        #expect(TerminalCommand.parse("toyota") == nil)
    }

    @Test func bloombergListingsMapToYahooSymbols() {
        #expect(TerminalCommand.parse("7203 JP")?.token == "7203.T")
        #expect(TerminalCommand.parse("700 HK")?.token == "0700.HK")
        #expect(TerminalCommand.parse("SHEL LN")?.token == "SHEL.L")
        #expect(TerminalCommand.parse("BRK.B US")?.token == "BRK-B")
        #expect(TerminalCommand.parse("SAP GY")?.token == "SAP.DE")
    }

    @Test func routeTokensRoundTrip() throws {
        let route = DataRoute("contracts", ["company": "Lockheed Martin & Co"])
        let decoded = try #require(DataRoute(token: route.token))
        #expect(decoded == route)
        #expect(DataRoute(token: "AAPL") == nil)
    }

    @Test func searchGroupsListingsByCompany() throws {
        let data = Data("""
        [{"symbol":"TM","longname":"Toyota Motor Corporation","quoteType":"EQUITY","exchDisp":"NYSE"},
         {"symbol":"7203.T","longname":"Toyota Motor Corporation","quoteType":"EQUITY","exchDisp":"Tokyo"},
         {"symbol":"8015.T","longname":"Toyota Tsusho Corporation","quoteType":"EQUITY","exchDisp":"Tokyo"}]
        """.utf8)
        let groups = TickerMatch.grouped(try JSONDecoder().decode([TickerMatch].self, from: data))
        #expect(groups.map(\.first.symbol) == ["TM", "8015.T"])
        #expect(groups[0].others.map(\.symbol) == ["7203.T"])
    }

    @Test func penceQuotesShowInPounds() throws {
        let data = Data(#"{"symbol":"SHEL.L","currency":"GBp","regularMarketPrice":2450,"regularMarketChange":-25,"regularMarketChangePercent":-1.01,"marketState":"REGULAR"}"#.utf8)
        let quote = try #require(MarketQuote(JSONDecoder().decode(YValue.self, from: data)))
        #expect(quote.price == 24.5 && quote.change == -0.25 && quote.currency == "GBP" && quote.changePercent == -1.01)
        #expect(MinorCurrency.major("USD").divisor == 1)
        #expect(StockResearchTools.pairs("region=jp; max_pe=15").count == 2)
    }

    @Test func payloadDecodes() throws {
        let data = Data(#"{"title":"T","source":"S","url":"https://x","as_of":"2026-10-06T00:00:00.000Z","sections":[{"title":"A","rows":[{"label":"L","value":"1","change_label":"+1"}]}],"chart":{"label":"c","points":[{"x":"2026-01-01","value":1}]},"text":"t"}"#.utf8)
        let payload = try NewswireAPI.decoder().decode(DataPayload.self, from: data)
        #expect(payload.sections[0].rows[0].changeLabel == "+1" && payload.asOf.hasPrefix("2026"))
    }
}
