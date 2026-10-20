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

    @Test func closedWinnersAndLosersRemainInHistoryAlongsideCashSweeps() throws {
        var source = snapshot(cash: 2400, transactions: [
            transaction("2026-01-02", "cash", 0, -500, subtype: "deposit", security: nil),
            transaction("2026-01-03", "sell", -10, -1200, security: "winner"),
            transaction("2026-01-03", "buy", 1200, 1200, security: "sweep"),
            transaction("2026-01-04", "sell", -10, -700, security: "loser"),
            transaction("2026-01-04", "sell", -300, -300, security: "sweep")
        ])
        source.histories?[0].securities = [
            .init(securityId: "winner", name: "Sold winner", tickerSymbol: "WIN", type: "equity", optionContract: nil),
            .init(securityId: "loser", name: "Sold loser", tickerSymbol: "LOSE", type: "equity", optionContract: nil),
            .init(securityId: "sweep", name: "Money market", tickerSymbol: "SPAXX", type: "cash", optionContract: nil)
        ]
        let ledger = try PortfolioLedger(snapshot: source, start: date("2026-01-01"))
        #expect(source.positions.isEmpty)
        #expect(ledger.limitation == nil)
        #expect(ledger.symbols == ["WIN", "LOSE"])
        let tracks = ["WIN": [100.0, 110, 120, 120, 120], "LOSE": [100.0, 90, 85, 70, 70]].mapValues { values in
            values.enumerated().map { index, price in
                HistoryPoint(date: date("2026-01-0\(index + 1)"), close: price, adjusted: price)
            }
        }
        let result = try ledger.build(prices: tracks)
        #expect(result.points.map(\.value) == [2000, 2500, 2550, 2400, 2400])
        #expect(result.change == -100)
        #expect(abs(result.percent! - (-100.0 / 2375)) < 1e-9)
        let flows = InvestmentCashFlows(history: source.histories![0], accountID: "a")
        #expect(flows.contributed == 500 && flows.withdrawn == 0)
        #expect(flows.buys == 0 && flows.sells == 1900)
    }

    @Test(arguments: [true, false]) func cashEquivalentFundingIsNotLostInsideASweep(_ deposit: Bool) throws {
        var source = snapshot(cash: deposit ? 1100 : 900, transactions: [
            transaction("2026-01-03", deposit ? "buy" : "sell", deposit ? 100 : -100, deposit ? 100 : -100,
                        subtype: deposit ? "contribution" : "distribution", security: "sweep")
        ])
        source.histories?[0].securities = [.init(securityId: "sweep", name: "Money market", tickerSymbol: "SPAXX", type: "cash", optionContract: nil)]
        let result = try series(source)
        #expect(result.baseline == 1000 && result.change == 0)
    }

    @Test func cashEquivalentWithUnknownUnitValueDoesNotBecomeAFlatLine() throws {
        var source = snapshot(cash: 1000, transactions: [transaction("2026-01-03", "buy", 10, 100, security: "sweep")])
        source.histories?[0].securities = [.init(securityId: "sweep", name: "Cash fund", tickerSymbol: "CASH", type: "cash", optionContract: nil)]
        let ledger = try PortfolioLedger(snapshot: source, start: date("2026-01-01"))
        #expect(ledger.limitation?.contains("unit value") == true)
        #expect(throws: PortfolioHistoryError.self) { try ledger.build(prices: [:]) }
    }

    @Test func fullSaleRetainsRealizedLoss() throws {
        var tracks = prices
        tracks["AAA"] = [100.0, 90, 80, 80, 80].enumerated().map { index, price in
            HistoryPoint(date: date("2026-01-0\(index + 1)"), close: price, adjusted: price)
        }
        let ledger = try PortfolioLedger(snapshot: snapshot(cash: 800, transactions: [transaction("2026-01-03", "sell", -10, -800)]), start: date("2026-01-01"))
        let result = try ledger.build(prices: tracks)
        #expect(result.points.map(\.value) == [1000, 900, 800, 800, 800])
        #expect(result.change == -200 && result.percent == -0.2)
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

    @Test func optionPositionsAreLimitedInsteadOfPricedAsTheirUnderlying() throws {
        var source = snapshot(cash: 0, transactions: [])
        let option = OptionDetail(isCall: true, strike: 120, expiration: date("2026-06-19"), contracts: 1)
        source.positions = [Position(id: "a|o", itemID: "i", institution: "Test", account: "Account", symbol: "AAA", name: nil, option: option, quantity: 1, price: 2, value: 200)]
        source.accountBalances = [BrokerageBalance(accountID: "a", itemID: "i", institution: "Test", name: "Account", value: 200, cashValue: 0, holdingsComplete: true)]
        let ledger = try PortfolioLedger(snapshot: source, start: date("2026-01-01"))
        #expect(ledger.symbols.isEmpty)
        #expect(ledger.limitation?.hasPrefix("Test Account:") == true)
        #expect(throws: PortfolioHistoryError.self) { try ledger.build(prices: prices) }
    }

    @Test func tickerlessFundTradeIsAnAccountLimitationNotAFlatLine() throws {
        var source = snapshot(cash: 1200, transactions: [])
        let trade = transaction("2026-01-03", "buy", 10, 1200)
        source.histories = [InvestmentHistory(itemID: "i", start: date("2025-01-01"), end: date("2026-01-05"), transactions: [trade],
            cashSecurityIDs: [], securities: [.init(securityId: "s", name: "Fidelity Fund", tickerSymbol: nil, type: "mutual fund", optionContract: nil)], version: 1)]
        let ledger = try PortfolioLedger(snapshot: source, start: date("2026-01-01"))
        #expect(ledger.limitation?.contains("no exchange ticker") == true)
        #expect(throws: PortfolioHistoryError.self) { try ledger.build(prices: prices) }
    }

    @Test func feesAndCashRecordsThatMoveSharesAreLimitations() throws {
        let fee = transaction("2026-01-03", "fee", -1, 0, subtype: "management fee")
        let ledger = try PortfolioLedger(snapshot: snapshot(quantity: 10, cash: 0, transactions: [fee]), start: date("2026-01-01"))
        #expect(ledger.limitation?.contains("not known to be cash") == true)
        let contribution = transaction("2026-01-04", "cash", 2, 0, subtype: "contribution")
        let other = try PortfolioLedger(snapshot: snapshot(quantity: 10, cash: 0, transactions: [contribution]), start: date("2026-01-01"))
        #expect(other.limitation?.contains("not known to be cash") == true)
    }

    @Test func partialSyncWithholdsReturnsUntilRecovery() throws {
        var source = snapshot(quantity: 10, cash: 0, transactions: [])
        source.failedItemIDs = ["i"]
        #expect(throws: PortfolioHistoryError.self) { try series(source) }
        source.failedItemIDs = []
        #expect(try series(source).points.isEmpty == false)
    }

    @Test func cashUnitQuantitiesOnDividendsAndFeesDoNotBlockHistory() throws {
        var source = snapshot(quantity: 10, cash: 0, transactions: [])
        source.histories = [InvestmentHistory(itemID: "i", start: date("2025-01-01"), end: date("2026-01-05"), transactions: [
            transaction("2026-01-03", "cash", -0.02, -0.02, subtype: "dividend", security: "usd"),
            transaction("2026-01-04", "fee", 0.06, 0.06, subtype: "miscellaneous fee", security: "usd")
        ], cashSecurityIDs: ["usd"], securities: [
            .init(securityId: "s", name: nil, tickerSymbol: "AAA", type: "equity", optionContract: nil),
            .init(securityId: "usd", name: "US Dollar", tickerSymbol: "USD", type: "cash", optionContract: nil)
        ], version: 1)]
        let ledger = try PortfolioLedger(snapshot: source, start: date("2026-01-01"))
        #expect(ledger.limitation == nil)
        _ = try ledger.build(prices: prices)
    }
}
