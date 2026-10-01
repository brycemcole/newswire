import Foundation
import Testing
@testable import Newswire

struct PortfolioOverviewTests {
    private func position(_ id: String, item: String, account: String, symbol: String, value: Double?, cost: Double?) -> Position {
        Position(id: id, itemID: item, institution: item, account: account, symbol: symbol, name: symbol == "AAPL" ? "Apple" : "Microsoft", option: nil, quantity: 1, price: value, value: value, reportedCost: cost)
    }

    @Test func accountsRemainDistinctAndScopeAggregation() {
        let positions = [position("1", item: "Fidelity", account: "IRA", symbol: "AAPL", value: 100, cost: 90),
                         position("2", item: "SoFi", account: "IRA", symbol: "AAPL", value: 200, cost: nil),
                         position("3", item: "Fidelity", account: "Individual", symbol: "MSFT", value: 400, cost: 350)]
        let accounts = PortfolioAccount.group(positions)
        #expect(accounts.count == 3)
        let holdings = PortfolioHolding.group(positions, search: "", sort: .value)
        #expect(holdings.map(\.symbol) == ["MSFT", "AAPL"])
        #expect(holdings[1].value == 300)
        #expect(holdings[1].gain == 10)
        #expect(holdings[1].partialGain)
        #expect(holdings[1].accountCount == 2)
        let scoped = PortfolioHolding.group(accounts.first { $0.institution == "SoFi" }!.positions, search: "apple", sort: .symbol)
        #expect(scoped.count == 1 && scoped[0].value == 200 && scoped[0].gain == nil)
    }

    @Test func missingValuesSortLastAndSearchTrimsWhitespace() {
        let positions = [position("1", item: "F", account: "A", symbol: "AAPL", value: nil, cost: nil),
                         position("2", item: "F", account: "A", symbol: "MSFT", value: -100, cost: -90)]
        #expect(PortfolioHolding.group(positions, search: "", sort: .value).map(\.symbol) == ["MSFT", "AAPL"])
        #expect(PortfolioHolding.group(positions, search: " APPle  ", sort: .gain).map(\.symbol) == ["AAPL"])
    }
}

struct PortfolioFundingTests {
    @Test func returnUsesMoneyAddedAndTakenOut() {
        let funding = AccountFunding(contributed: 8000, withdrawn: 0)
        #expect(funding.gain(value: 4800) == -3200)
        #expect(funding.percent(value: 4800) == -0.4)
        let withdrawn = AccountFunding(contributed: 8000, withdrawn: 2000)
        #expect(withdrawn.gain(value: 4800) == -1200)
        #expect(AccountFunding(contributed: 0, withdrawn: 0).percent(value: 100) == nil)
        #expect(AccountFunding(contributed: 8000, withdrawn: nil).gain(value: 4800) == nil)
    }

    @Test func reportedBalanceOverridesIncompleteHoldingsAndKeepsCashOnlyAccounts() throws {
        let json = """
        {"accounts":[{"account_id":"stock","name":"Invest","mask":"1234","balances":{"current":4800}},
                     {"account_id":"cash","name":"Cash","mask":"5678","balances":{"current":200}}],
         "holdings":[{"account_id":"stock","security_id":"s","quantity":1,"institution_price":100,"institution_value":100,"cost_basis":null}],
         "securities":[{"security_id":"s","ticker_symbol":"AAPL","type":"equity"}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(HoldingsResponse.self, from: Data(json.utf8))
        let parsed = response.positions(item: PlaidItem(id: "item", accessToken: "preview", institution: "SoFi", environment: .sandbox))
        let snapshot = PortfolioSnapshot(positions: parsed.positions, cashByItem: [:], accountBalances: parsed.accountBalances)
        #expect(snapshot.totalValue == 5000)
        #expect(PortfolioAccount.group(snapshot).count == 2)
        #expect(PortfolioAccount.group(snapshot).first { $0.id.name == "cash" }?.positions.isEmpty == true)
        let oldCache = try JSONDecoder().decode(PortfolioSnapshot.self, from: Data("{\"positions\":[],\"cashByItem\":{}}".utf8))
        #expect(oldCache.accountBalances == nil && oldCache.totalValue == 0)
    }

    @Test func incompleteHistoryDoesNotGuessRecentLotCost() throws {
        let json = """
        [{"account_id":"a","security_id":"s","type":"buy","quantity":10,"amount":1000,"date":"2026-01-01"},
         {"account_id":"a","security_id":"s","type":"buy","quantity":10,"amount":2000,"date":"2026-02-01"}]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let trades = try decoder.decode([PlaidClient.Transactions.Transaction].self, from: Data(json.utf8))
        #expect(HoldingsResponse.estimatedCost(quantity: 10, trades: trades) == nil)
        #expect(HoldingsResponse.estimatedCost(quantity: 20, trades: trades) == 3000)
    }

    @Test func shortSalesCloseBeforeNewLongLot() throws {
        let json = """
        [{"account_id":"a","security_id":"s","type":"buy","quantity":2,"amount":240,"date":"2026-02-01"},
         {"account_id":"a","security_id":"s","type":"sell","quantity":-1,"amount":-100,"date":"2026-01-01"}]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let trades = try decoder.decode([PlaidClient.Transactions.Transaction].self, from: Data(json.utf8))
        #expect(HoldingsResponse.estimatedCost(quantity: 1, trades: trades) == 120)
        #expect(HoldingsResponse.estimatedCost(quantity: -1, trades: trades) == nil)
    }
}

struct InvestmentCashFlowTests {
    private func transaction(_ type: String, _ subtype: String?, _ amount: Double, account: String = "a") -> PlaidClient.Transactions.Transaction {
        PlaidClient.Transactions.Transaction(accountId: account, securityId: nil, type: type, quantity: 0, amount: amount, date: "2026-01-01", subtype: subtype)
    }

    @Test func depositsAreNotRecycledPurchasesOrIncome() {
        let records = [transaction("cash", "deposit", -8000), transaction("buy", "buy", 6000),
                       transaction("sell", "sell", -5000), transaction("buy", "buy", 4000),
                       transaction("cash", "dividend", -20), transaction("cash", "withdrawal", 1000),
                       transaction("cash", "deposit", -9000, account: "other")]
        let flows = InvestmentCashFlows(history: InvestmentHistory(itemID: "i", start: .distantPast, end: .now, transactions: records), accountID: "a")
        #expect(flows.contributed == 8000)
        #expect(flows.withdrawn == 1000)
        #expect(flows.buys == 10000 && flows.sells == 5000)
        #expect(flows.unknown == 0)
    }

    @Test func unresolvedTransfersPreventAutomaticLifetimeTotals() {
        let records = [transaction("transfer", "transfer", -1000), transaction("cash", nil, -500), transaction("cash", "deposit", 100)]
        let flows = InvestmentCashFlows(history: InvestmentHistory(itemID: "i", start: .distantPast, end: .now, transactions: records), accountID: "a")
        #expect(flows.unknown == 3)
        #expect(flows.contributed == 0)
    }

    @Test func bankingBalancesAreExcluded() throws {
        let json = """
        {"accounts":[{"account_id":"invest","name":"Invest","type":"investment","balances":{"current":4800}},
                     {"account_id":"bank","name":"Checking","type":"depository","balances":{"current":4400}}],
         "holdings":[],"securities":[]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(HoldingsResponse.self, from: Data(json.utf8))
        let parsed = response.positions(item: PlaidItem(id: "i", accessToken: "preview", institution: "SoFi", environment: .sandbox))
        #expect(parsed.accountBalances.count == 1 && parsed.accountBalances[0].value == 4800)
    }
}

struct SoFiFundingTests {
    @Test func cashSecurityTransfersCountAsFundingAndStockTransfersNeedReview() {
        let records = [
            PlaidClient.Transactions.Transaction(accountId: "a", securityId: "usd", type: "transfer", quantity: -13054.97, amount: -13054.97, date: "2026-01-01", subtype: "transfer", investmentTransactionId: "in"),
            PlaidClient.Transactions.Transaction(accountId: "a", securityId: "usd", type: "transfer", quantity: 4529.63, amount: 4529.63, date: "2026-02-01", subtype: "transfer", investmentTransactionId: "out")
        ]
        let history = InvestmentHistory(itemID: "i", start: .distantPast, end: .now, transactions: records + [records[0]], cashSecurityIDs: ["usd"])
        let flows = InvestmentCashFlows(history: history, accountID: "a")
        #expect(flows.unknown == 0 && flows.records.count == 2)
        #expect(abs(flows.contributed - flows.withdrawn - 8525.34) < 0.001)
        let funding = AccountFunding(contributed: flows.contributed, withdrawn: flows.withdrawn)
        #expect(abs((funding.gain(value: 5050.76) ?? 0) + 3474.58) < 0.001)
        #expect(abs((funding.percent(value: 5050.76) ?? 0) + 0.40756) < 0.0001)
        let unknown = InvestmentCashFlows(history: InvestmentHistory(itemID: "i", start: .distantPast, end: .now, transactions: records, cashSecurityIDs: []), accountID: "a")
        #expect(unknown.unknown == 2 && unknown.contributed == 0)
    }
}

struct SoFiDescriptionTests {
    @Test func recognizesSoFiUSDTransfersWithoutCashSecurityMetadata() {
        let records = [
            PlaidClient.Transactions.Transaction(accountId: "a", securityId: "usd", type: "transfer", quantity: -8000, amount: -8000, date: "2026-01-01", subtype: "transfer", name: "transfer - DEPOSIT USD"),
            PlaidClient.Transactions.Transaction(accountId: "a", securityId: "usd", type: "transfer", quantity: 1000, amount: 1000, date: "2026-02-01", subtype: "transfer", name: "transfer - WITHDRAWAL Cash in USD")
        ]
        let history = InvestmentHistory(itemID: "i", start: .distantPast, end: .now, transactions: records, cashSecurityIDs: [])
        let soFi = InvestmentCashFlows(history: history, accountID: "a", institution: "SoFi")
        #expect(soFi.contributed == 8000 && soFi.withdrawn == 1000 && soFi.unknown == 0)
        let other = InvestmentCashFlows(history: history, accountID: "a", institution: "Another brokerage")
        #expect(other.unknown == 2 && other.contributed == 0)
    }
}
