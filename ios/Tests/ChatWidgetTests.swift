import Foundation
import Testing
@testable import Newswire

@MainActor struct ChatWidgetTests {
    private let long600 = ChatOption(symbol: "QQQ261030C00600000", strike: 600, bid: 5, ask: 5.2, spot: 600)
    private let short610 = ChatOption(symbol: "QQQ261030C00610000", strike: 610, bid: 1.8, ask: 2, spot: 600)
    private let put590 = ChatOption(symbol: "QQQ261030P00590000", strike: 590, bid: 3.4, ask: 3.6, spot: 600)
    private let other = ChatOption(symbol: "QQQ261120C00600000", strike: 600, bid: 7, ask: 7.2, spot: 600)

    private func leg(_ contract: String, _ side: String, qty: Double = 1) -> ChatStrategyLeg { ChatStrategyLeg(contract: contract, shares: nil, side: side, qty: qty) }

    @Test func bullCallSpreadHasBoundedRiskAndReward() throws {
        let spec = ChatStrategySpec(name: "Bull call spread", outlook: "bullish", legs: [leg(long600.symbol, "buy"), leg(short610.symbol, "sell")])
        let analysis = try #require(StrategyAnalysis(spec: spec, options: [long600, short610]))
        #expect(abs(analysis.net - 340) < 1e-9)
        #expect(abs((analysis.maxLoss ?? -1) - 340) < 1e-9)
        #expect(abs((analysis.maxProfit ?? -1) - 660) < 1e-9)
        #expect(analysis.breakevens.count == 1)
        #expect(abs(analysis.breakevens[0] - 603.4) < 1e-9)
        #expect(abs(analysis.pnl(at: 650) - 660) < 1e-9)
        #expect(abs(analysis.pnl(at: 500) + 340) < 1e-9)
    }

    @Test func longCallHasUnlimitedProfit() throws {
        let spec = ChatStrategySpec(name: nil, outlook: nil, legs: [leg(long600.symbol, "buy")])
        let analysis = try #require(StrategyAnalysis(spec: spec, options: [long600]))
        #expect(analysis.maxProfit == nil)
        #expect(abs((analysis.maxLoss ?? -1) - 520) < 1e-9)
        #expect(abs(analysis.breakevens[0] - 605.2) < 1e-9)
    }

    @Test func shortCallHasUnlimitedLoss() throws {
        let spec = ChatStrategySpec(name: nil, outlook: nil, legs: [leg(short610.symbol, "sell")])
        let analysis = try #require(StrategyAnalysis(spec: spec, options: [short610]))
        #expect(analysis.maxLoss == nil)
        #expect(abs((analysis.maxProfit ?? -1) - 180) < 1e-9)
        #expect(analysis.net < 0)
    }

    @Test func coveredCallUsesSpotForTheShares() throws {
        let spec = ChatStrategySpec(name: "Covered call", outlook: nil, legs: [ChatStrategyLeg(contract: nil, shares: 100, side: "buy", qty: nil), leg(short610.symbol, "sell")])
        let analysis = try #require(StrategyAnalysis(spec: spec, options: [short610]))
        #expect(abs(analysis.net - (60_000 - 180)) < 1e-6)
        #expect(abs((analysis.maxProfit ?? -1) - (1_000 + 180)) < 1e-6)
        #expect(abs((analysis.maxLoss ?? -1) - (60_000 - 180)) < 1e-6)
        #expect(abs(analysis.breakevens[0] - 598.2) < 1e-6)
    }

    @Test func longStraddleHasTwoBreakevens() throws {
        let call = long600
        let put = ChatOption(symbol: "QQQ261030P00600000", strike: 600, bid: 5.8, ask: 6, spot: 600)
        let spec = ChatStrategySpec(name: nil, outlook: nil, legs: [leg(call.symbol, "buy"), leg(put.symbol, "buy")])
        let analysis = try #require(StrategyAnalysis(spec: spec, options: [call, put]))
        #expect(analysis.maxProfit == nil)
        #expect(analysis.breakevens.count == 2)
        #expect(abs(analysis.breakevens[0] - 588.8) < 1e-9)
        #expect(abs(analysis.breakevens[1] - 611.2) < 1e-9)
    }

    @Test func refusesLegsThatWereNeverQuoted() {
        let spec = ChatStrategySpec(name: nil, outlook: nil, legs: [leg(long600.symbol, "buy"), leg("QQQ261030C00620000", "sell")])
        #expect(StrategyAnalysis(spec: spec, options: [long600]) == nil)
    }

    @Test func refusesMixedExpiriesAndUnknownSides() {
        let mixed = ChatStrategySpec(name: nil, outlook: nil, legs: [leg(long600.symbol, "buy"), leg(other.symbol, "sell")])
        #expect(StrategyAnalysis(spec: mixed, options: [long600, other]) == nil)
        let odd = ChatStrategySpec(name: nil, outlook: nil, legs: [leg(long600.symbol, "hold")])
        #expect(StrategyAnalysis(spec: odd, options: [long600]) == nil)
    }

    @Test func parsesWidgetBlocksAndIgnoresBrokenJSON() {
        let options = ChatWidget.parse(language: "options", body: #"{"title":"QQQ","contracts":["QQQ261030C00600000"]}"#)
        #expect(options == .options(ChatOptionsSpec(title: "QQQ", contracts: ["QQQ261030C00600000"])))
        #expect(ChatWidget.parse(language: "Newswire-Strategy", body: #"{"legs":[{"contract":"QQQ261030C00600000","side":"buy"}]}"#) != nil)
        #expect(ChatWidget.parse(language: "options", body: "{not json") == nil)
        #expect(ChatWidget.parse(language: "options", body: #"{"contracts":[]}"#) == nil)
        #expect(ChatWidget.parse(language: "swift", body: "{}") == nil)
    }

    @Test func chatsSavedBeforeWidgetsStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","user":false,"text":"Hello","sources":[],"provider":"DeepSeek"}"#
        let message = try JSONDecoder().decode(StockChatMessage.self, from: Data(old.utf8))
        #expect(message.options.isEmpty)
        let round = try JSONDecoder().decode(StockChatMessage.self, from: JSONEncoder().encode(StockChatMessage(user: false, text: "x", options: [long600])))
        #expect(round.options == [long600])
    }

    @Test func tickerNormalizesOptionSymbolsAndRejectsJunk() {
        #expect(StockResearchTools.ticker(" qqq ") == "QQQ")
        #expect(StockResearchTools.ticker("QQQ261030C00600000") == "QQQ")
        #expect(StockResearchTools.ticker("^GSPC") == "^GSPC")
        #expect(StockResearchTools.ticker("drop table") == nil)
    }
}
