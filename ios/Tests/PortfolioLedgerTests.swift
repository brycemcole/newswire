import Foundation
import Testing
@testable import Newswire

struct PortfolioLedgerTests {
    private func date(_ day: String) -> Date { PortfolioLedger.day(day)! }
    private func transaction(_ day: String, _ type: String, _ quantity: Double, _ amount: Double,
                             subtype: String? = nil, id: String? = nil, security: String? = "s") -> PlaidClient.Transactions.Transaction {
        .init(accountId: "a", securityId: security, type: type, quantity: quantity, amount: amount,
              date: day, subtype: subtype ?? type, investmentTransactionId: id)
    }
    private func snapshot(quantity: Double = 0, price: Double = 120, cash: Double,
                          transactions: [PlaidClient.Transactions.Transaction]) -> PortfolioSnapshot {
        let positions: [Position] = quantity == 0 ? [] : [Position(id: "a|s", itemID: "i", institution: "Test", account: "Account", symbol: "AAA", name: nil, option: nil, quantity: quantity, price: price, value: quantity * price)]
        return PortfolioSnapshot(positions: positions, cashByItem: ["i": cash], updated: date("2026-01-05"),
            accountBalances: [BrokerageBalance(accountID: "a", itemID: "i", institution: "Test", name: "Account", value: cash + quantity * price, cashValue: cash, holdingsComplete: true)],
            histories: [InvestmentHistory(itemID: "i", start: date("2025-01-01"), end: date("2026-01-05"), transactions: transactions,
                cashSecurityIDs: [], securities: [.init(securityId: "s", name: nil, tickerSymbol: "AAA", type: "equity", optionContract: nil)], version: 1)])
    }
    private var prices: [String: [HistoryPoint]] {
        ["AAA": [("2026-01-01", 100.0), ("2026-01-02", 110.0), ("2026-01-03", 120.0), ("2026-01-04", 120.0), ("2026-01-05", 120.0)].map {
            HistoryPoint(date: date($0.0), close: $0.1, adjusted: $0.1)
        }]
    }
    private func series(_ snapshot: PortfolioSnapshot) throws -> PerformanceSeries {
        try PortfolioLedger(snapshot: snapshot, start: date("2026-01-01")).build(prices: prices)
    }

    @Test func purchaseDoesNotPretendSharesWereAlwaysHeld() throws {
        let result = try series(snapshot(quantity: 10, cash: 0, transactions: [transaction("2026-01-03", "buy", 10, 1200)]))
        #expect(result.points.map(\.value) == [1200, 1200, 1200, 1200, 1200])
        #expect(result.change == 0 && result.percent == 0)
        // The old current-quantity backcast reported a fictitious $200 gain.
        #expect(10 * (120 - 100) != result.change)
    }

    @Test func fullSaleRetainsHistoricalSharesAndRealizedGain() throws {
        let result = try series(snapshot(cash: 1200, transactions: [transaction("2026-01-03", "sell", -10, -1200)]))
        #expect(result.points.map(\.value) == [1000, 1100, 1200, 1200, 1200])
        #expect(result.change == 200)
        #expect(abs(result.percent! - 0.2) < 1e-9)
    }

    @Test func partialSalePreservesProceedsAndRemainingShares() throws {
        let result = try series(snapshot(quantity: 5, cash: 600, transactions: [transaction("2026-01-03", "sell", -5, -600)]))
        #expect(result.baseline == 1000 && result.last == 1200 && result.change == 200)
    }

    @Test func depositsAndWithdrawalsAreNotInvestmentGains() throws {
        let result = try series(snapshot(cash: 1400, transactions: [
            transaction("2026-01-02", "cash", 0, -1000, subtype: "deposit", security: nil),
            transaction("2026-01-04", "cash", 0, 600, subtype: "withdrawal", security: nil)
        ]))
        #expect(result.baseline == 1000 && result.last == 1400)
        #expect(result.change == 0 && result.percent == 0)
        #expect(result.points[1].gain == 0)
    }

    @Test func returnWeightsFundingInsteadOfDividingByNetDeposits() throws {
        let result = try series(snapshot(cash: 2100, transactions: [transaction("2026-01-03", "cash", 0, -1000, subtype: "deposit", security: nil), transaction("2026-01-05", "cash", 0, -100, subtype: "interest", security: nil)]))
        #expect(result.baseline == 1000 && result.change == 100)
        #expect(abs(result.percent! - 100.0 / 1500) < 1e-9)
    }

    @Test func dividendsAndFeesAffectReturnWithoutBecomingFunding() throws {
        let result = try series(snapshot(cash: 1008, transactions: [
            transaction("2026-01-02", "cash", 0, -10, subtype: "dividend"),
            transaction("2026-01-03", "fee", 0, 2, subtype: "account fee", security: nil)
        ]))
        #expect(result.baseline == 1000 && result.change == 8)
    }

    @Test func dividendAndReinvestmentAreNotCountedTwice() throws {
        let result = try series(snapshot(quantity: 10, cash: 1000, transactions: [
            transaction("2026-01-03", "cash", 0, -1200, subtype: "dividend"),
            transaction("2026-01-03", "buy", 10, 1200, subtype: "dividend reinvestment")
        ]))
        #expect(result.baseline == 1000 && result.change == 1200)
    }

    @Test func duplicateAndCancelledTradesAreNotCounted() throws {
        let sale = transaction("2026-01-03", "sell", -10, -1200, id: "sale")
        let result = try series(snapshot(cash: 1200, transactions: [sale, sale]))
        #expect(result.change == 200)
        var cancel = transaction("2026-01-04", "cancel", 0, 0, id: "cancel")
        cancel.cancelTransactionId = "sale"
        let cancelled = try series(snapshot(quantity: 10, cash: 0, transactions: [sale, cancel]))
        #expect(cancelled.change == 200 && cancelled.baseline == 1000)
        #expect(InvestmentCashFlows(history: snapshot(cash: 0, transactions: [sale, cancel]).histories![0], accountID: "a").sells == 0)
    }

    @Test func saleFollowedByRepurchaseReconstructsEachDay() throws {
        let result = try series(snapshot(quantity: 5, cash: 500, transactions: [transaction("2026-01-02", "sell", -10, -1100), transaction("2026-01-04", "buy", 5, 600)]))
        #expect(result.points.map(\.value) == [1000, 1100, 1100, 1100, 1100])
        #expect(result.change == 100)
    }

    @Test func doesNotUseAnotherAccountsTransactions() throws {
        let wrong = PlaidClient.Transactions.Transaction(accountId: "other", securityId: "s", type: "sell", quantity: -100, amount: -12000, date: "2026-01-03", subtype: "sell")
        let result = try series(snapshot(quantity: 10, cash: 0, transactions: [wrong]))
        #expect(result.baseline == 1000 && result.change == 200)
    }

    @Test func rejectsMissingOrStaleHistoryAndUnreconciledBalances() {
        var source = snapshot(quantity: 10, cash: 0, transactions: [])
        source.histories = nil
        #expect(throws: PortfolioHistoryError.self) { try series(source) }
        source = snapshot(quantity: 10, cash: 0, transactions: [])
        source.histories?[0] = InvestmentHistory(itemID: "i", start: date("2026-01-03"), end: date("2026-01-05"), transactions: [], version: 1)
        #expect(throws: PortfolioHistoryError.self) { try series(source) }
        source = snapshot(quantity: 10, cash: 0, transactions: [])
        source.accountBalances?[0].cashValue = 500
        #expect(throws: PortfolioHistoryError.self) { try series(source) }
    }

    @Test func orderDateUsesExchangeDayAndDateOnlyTimestamp() {
        var trade = transaction("2026-01-05", "buy", 10, 1000)
        trade.transactionDatetime = "2026-01-03T01:00:00Z"
        #expect(PortfolioLedger.transactionDay(trade) == date("2026-01-02"))
        trade.transactionDatetime = "2026-01-03T00:00:00Z"
        #expect(PortfolioLedger.transactionDay(trade) == date("2026-01-03"))
    }

    @Test func missingPriceDoesNotFreezePositionOrUseFuturePrice() throws {
        let ledger = try PortfolioLedger(snapshot: snapshot(quantity: 10, cash: 0, transactions: []), start: date("2026-01-01"))
        #expect(throws: PortfolioHistoryError.self) { try ledger.build(prices: [:]) }
        #expect(throws: PortfolioHistoryError.self) { try ledger.build(prices: ["AAA": [HistoryPoint(date: date("2026-01-02"), close: 110, adjusted: 110)]]) }
    }

    @Test func unknownTransfersAndSplitsCannotProduceMadeUpReturns() {
        let transfer = transaction("2026-01-03", "transfer", 5, 0, subtype: "split")
        #expect(throws: PortfolioHistoryError.self) { try series(snapshot(quantity: 10, cash: 0, transactions: [transfer])) }
    }

    @Test func zeroCapitalDoesNotReportInfiniteReturn() throws {
        let result = try series(snapshot(cash: 1000, transactions: [transaction("2026-01-05", "cash", 0, -1000, subtype: "deposit", security: nil)]))
        #expect(result.change == 0 && result.percent == nil)
    }

    @Test func combinedContributionPurchaseDoesNotDebitCashTwice() throws {
        let result = try series(snapshot(quantity: 10, cash: 1000, transactions: [transaction("2026-01-03", "buy", 10, 1200, subtype: "contribution")]))
        #expect(result.baseline == 1000 && result.change == 0)
    }
}
