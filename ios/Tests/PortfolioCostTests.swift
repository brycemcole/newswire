import Foundation
import Testing
@testable import Newswire

struct PortfolioCostTests {
    @Test(arguments: ["SP.500.INDEX.PL.CL.D", "SP.INTL.INDEX.D", "SP.SMALL.CP.IND.CL.D"])
    func planIdentifierRetainsValueWithoutInventingBasis(symbol: String) throws {
        let position = try parsed(symbol: symbol, basis: "null")
        #expect(position.symbol == symbol)
        #expect(position.value == 1200 && position.price == 120)
        #expect(position.costBasis == nil && position.gain == nil && position.gainPercent == nil)
        #expect(!position.isEstimated)
        let holding = try #require(PortfolioHolding.group([position], search: "", sort: .value).first)
        #expect(holding.value == 1200 && holding.gain == nil && holding.partialGain)
        #expect(HoldingsResponse.estimatedCost(quantity: position.quantity, trades: []) == nil)
    }

    @Test func zeroBasisIsNotUnavailable() throws {
        let position = try parsed(basis: "0")
        #expect(position.costBasis == 0 && position.gain == 1200)
        #expect(position.gainPercent == nil)
        let holding = try #require(PortfolioHolding.group([position], search: "", sort: .value).first)
        #expect(holding.gain == 1200 && !holding.partialGain)
    }

    @MainActor @Test func manualOverridePersistsAndCanBeRemoved() throws {
        let suite = "PortfolioCostTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        let cache = directory.appending(path: "synthetic.json")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let position = try parsed()
        let store = PortfolioStore(defaults: defaults, cacheURL: cache)
        store.snapshot = PortfolioSnapshot(positions: [position], updated: Date(timeIntervalSince1970: 1_800_000_000), costMethodVersion: 2)
        store.setCost(position, total: position.totalCost(averageCost: "100"))
        let restored = PortfolioStore(defaults: defaults, cacheURL: cache)
        let saved = try #require(restored.snapshot.positions.first)
        #expect(saved.manualCost == 1000 && saved.reportedCost == nil)
        #expect(saved.gain == 200 && saved.isEstimated == false)
        #expect(restored.snapshot.updated == store.snapshot.updated)
        restored.setCost(saved, total: 0)
        let zero = PortfolioStore(defaults: defaults, cacheURL: cache)
        #expect(zero.snapshot.positions.first?.costBasis == 0)
        #expect(zero.snapshot.positions.first?.gain == 1200)
        zero.setCost(saved, total: nil)
        let removed = PortfolioStore(defaults: defaults, cacheURL: cache)
        #expect(removed.snapshot.positions.first?.manualCost == nil)
        #expect(removed.snapshot.positions.first?.gain == nil)
    }

    @Test func averageCostRejectsInvalidInputsAndPreservesZero() throws {
        let position = try parsed()
        #expect(position.totalCost(averageCost: "0") == 0)
        #expect(position.totalCost(averageCost: "$1,234.50") == 12_345)
        for input in ["", "-1", "nan", "inf", "1e309", "not a cost"] {
            #expect(position.totalCost(averageCost: input) == nil)
        }
    }

    @Test func partialHistoryRemainsUnavailable() {
        let trade = PlaidClient.Transactions.Transaction(accountId: "plan", securityId: "fund", type: "buy", quantity: 2, amount: 200, date: "2026-01-01")
        #expect(HoldingsResponse.estimatedCost(quantity: 10, trades: [trade]) == nil)
        #expect(HoldingsResponse.estimatedCost(quantity: 2, trades: [trade]) == 200)
    }

    private func parsed(symbol: String = "SP.500.INDEX.PL.CL.D", basis: String = "null") throws -> Position {
        let json = """
        {"accounts":[{"account_id":"plan","name":"Synthetic retirement plan","type":"investment"}],
         "holdings":[{"account_id":"plan","security_id":"fund","quantity":10,"institution_price":120,"institution_value":1200,"cost_basis":\(basis)}],
         "securities":[{"security_id":"fund","name":"Synthetic plan fund","ticker_symbol":"\(symbol)","type":"mutual fund"}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(HoldingsResponse.self, from: Data(json.utf8))
        return try #require(response.positions(item: PlaidItem(id: "synthetic", accessToken: "preview", institution: "Fidelity", environment: .sandbox)).positions.first)
    }
}
