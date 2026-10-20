#if DEBUG
import SwiftUI

struct PortfolioPreview: View {
    init() {
        if CommandLine.arguments.contains("-portfolioCostPreview") { return }
        if CommandLine.arguments.contains("-portfolioPartialSync") {
            PartialSyncPreview.apply()
            return
        }
        if CommandLine.arguments.contains("-portfolioRecordedPreview") {
            PortfolioStore.shared.snapshot = RecordedBalancePreview.snapshot
            return
        }
        if CommandLine.arguments.contains("-portfolioLedgerPreview") {
            PortfolioStore.shared.snapshot = LedgerPreview.snapshot
            return
        }
        let symbols = ["AAPL", "NVDA", "MSFT", "AMZN", "GOOGL", "META", "TSLA", "VTI", "VOO", "AMD", "NFLX", "COST", "JPM", "DIS", "UBER", "SOFI", "QQQ", "AVGO", "PLTR", "MU"]
        let names = ["Apple", "NVIDIA", "Microsoft", "Amazon", "Alphabet", "Meta Platforms", "Tesla", "Vanguard Total Stock Market ETF", "Vanguard S&P 500 ETF", "Advanced Micro Devices"]
        var positions = symbols.enumerated().map { index, symbol in
            Position(id: "\(index % 2 == 0 ? "individual" : "invest")|preview-\(index)", itemID: index % 2 == 0 ? "fidelity" : "sofi", institution: index % 2 == 0 ? "Fidelity" : "SoFi", account: index % 2 == 0 ? "Individual ••1234" : "Invest ••5678", symbol: symbol, name: index < names.count ? names[index] : symbol, option: nil, quantity: Double(30 - index), price: 100 + Double(index * 10), value: Double(30 - index) * (100 + Double(index * 10)), reportedCost: Double(30 - index) * 92)
        }
        positions.append(Position(id: "ira|preview-apple", itemID: "fidelity", institution: "Fidelity", account: "Roth IRA ••9012", symbol: "AAPL", name: "Apple", option: nil, quantity: 15, price: 100, value: 1500, reportedCost: nil))
        positions.append(Position(id: "invest|preview-option", itemID: "sofi", institution: "SoFi", account: "Invest ••5678", symbol: "NVDA", name: "NVIDIA Call", option: OptionDetail(isCall: true, strike: 150, expiration: Date.now.addingTimeInterval(86400 * 30), contracts: 2), quantity: 200, price: 4.2, value: 840, reportedCost: 600, costEstimated: true))
        let snapshot = PortfolioSnapshot(positions: positions, cashByItem: ["fidelity": 3250, "sofi": 1250], updated: .now)
        var preview = snapshot
        preview.accountBalances = PortfolioAccount.group(positions).map { account in
            BrokerageBalance(accountID: account.id.name, itemID: account.id.item, institution: account.institution, name: account.name,
                             value: account.positions.compactMap(\.value).reduce(0, +) + (account.id.name == "individual" ? 3250 : account.id.name == "invest" ? 1250 : 0))
        }
        preview.histories = [InvestmentHistory(itemID: "fidelity", start: Date.now.addingTimeInterval(-86400 * 730), end: .now, transactions: [
            PlaidClient.Transactions.Transaction(accountId: "individual", securityId: nil, type: "cash", quantity: 0, amount: -8000, date: "2026-01-01", subtype: "deposit", name: "Account deposit"),
            PlaidClient.Transactions.Transaction(accountId: "individual", securityId: "aapl", type: "buy", quantity: 30, amount: 6000, date: "2026-02-01", subtype: "buy", name: "Buy Apple"),
            PlaidClient.Transactions.Transaction(accountId: "individual", securityId: "aapl", type: "sell", quantity: -20, amount: -5000, date: "2026-03-01", subtype: "sell", name: "Sell Apple"),
            PlaidClient.Transactions.Transaction(accountId: "individual", securityId: nil, type: "cash", quantity: 0, amount: 1000, date: "2026-04-01", subtype: "withdrawal", name: "Account withdrawal")
        ])]
        PortfolioStore.shared.snapshot = preview
        if CommandLine.arguments.contains("-portfolioFunded") {
            PortfolioFundingStore.shared.preview(accounts: PortfolioAccount.group(preview))
        }

    }
    var body: some View {
        if CommandLine.arguments.contains("-portfolioCostPreview") {
            PortfolioCostPreview()
        } else if CommandLine.arguments.contains("-portfolioWidgetPreview") {
            PortfolioWidgetView(portfolio: WidgetPortfolio(holdings: [], cash: 1200, other: 0, otherGain: nil, value: 1200,
                dayBaseline: 1000, day: [WidgetPoint(date: LedgerPreview.day(-1), value: 1000), WidgetPoint(date: LedgerPreview.end, value: 1200)],
                updated: .now, accountingVersion: 1, measuredDayChange: 200, measuredDayPercent: 0.2), family: .systemMedium)
                .frame(width: 350, height: 160).padding()
        } else if CommandLine.arguments.contains("-portfolioContributions"), let account = PortfolioAccount.group(PortfolioStore.shared.snapshot).first {
            PortfolioFundingEditor(account: account)
        } else if CommandLine.arguments.contains("-portfolioHistory"), let account = PortfolioAccount.group(PortfolioStore.shared.snapshot).first(where: { $0.id.name == "individual" }), let history = account.history {
            NavigationStack { PortfolioHistoryView(account: account, history: history) }
        } else if CommandLine.arguments.contains("-portfolioHoldings") {
            NavigationStack {
                List {
                    ForEach(PortfolioHolding.group(PortfolioStore.shared.snapshot.positions, search: "", sort: .value)) { holding in
                        PortfolioHoldingRow(holding: holding)
                    }
                }
                .navigationTitle("Holdings").navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: MarketSymbol.self) { QuoteDetail(symbol: $0.id) }
            }
        } else { PortfolioView() }
    }
}
enum LedgerPreview {
    static let end = PortfolioLedger.calendar.startOfDay(for: .now)
    static func day(_ offset: Int) -> Date { PortfolioLedger.calendar.date(byAdding: .day, value: offset, to: end)! }
    static var snapshot: PortfolioSnapshot {
        func date(_ offset: Int) -> String { day(offset).formatted(Date.ISO8601FormatStyle().year().month().day()) }
        let history = InvestmentHistory(itemID: "test", start: day(-730), end: end,
            transactions: [
                .init(accountId: "account", securityId: nil, type: "cash", quantity: 0, amount: -500, date: date(-3), subtype: "deposit"),
                .init(accountId: "account", securityId: "winner", type: "sell", quantity: -10, amount: -1200, date: date(-2), subtype: "sell"),
                .init(accountId: "account", securityId: "sweep", type: "buy", quantity: 1200, amount: 1200, date: date(-2), subtype: "buy"),
                .init(accountId: "account", securityId: "loser", type: "sell", quantity: -10, amount: -700, date: date(-1), subtype: "sell"),
                .init(accountId: "account", securityId: "sweep", type: "sell", quantity: -300, amount: -300, date: date(-1), subtype: "sell")
            ], cashSecurityIDs: [], securities: [
                .init(securityId: "winner", name: "Sold winner", tickerSymbol: "WIN", type: "equity", optionContract: nil),
                .init(securityId: "loser", name: "Sold loser", tickerSymbol: "LOSE", type: "equity", optionContract: nil),
                .init(securityId: "sweep", name: "Money market", tickerSymbol: "SPAXX", type: "cash", optionContract: nil)
            ], version: 1)
        let option = Position(id: "account|option", itemID: "test", institution: "Test brokerage", account: "Sold position example", symbol: "TEST", name: "Example call",
            option: OptionDetail(isCall: true, strike: 150, expiration: day(30), contracts: 1), quantity: 1, price: nil, value: 0)
        return PortfolioSnapshot(positions: CommandLine.arguments.contains("-portfolioOptionLimitation") ? [option] : [], cashByItem: ["test": 2400], updated: end,
            accountBalances: [.init(accountID: "account", itemID: "test", institution: "Test brokerage", name: "Sold positions example", value: 2400, cashValue: 2400, holdingsComplete: true)],
            histories: CommandLine.arguments.contains("-portfolioMissingHistory") ? nil : [history])
    }
    static var prices: [String: [HistoryPoint]] {
        ["WIN": [100.0, 110, 120, 120, 120], "LOSE": [100.0, 90, 85, 70, 70]].mapValues { values in
            values.enumerated().map { index, price in
                HistoryPoint(date: day(index - 4), close: price, adjusted: price)
            }
        }
    }
}

enum PartialSyncPreview {
    static func apply() {
        let environment = PortfolioStore.shared.credentials.environment
        let now = Date.now
        PortfolioStore.shared.items = [PlaidItem(id: "fidelity", accessToken: "preview", institution: "Fidelity", environment: environment),
                                       PlaidItem(id: "sofi", accessToken: "preview", institution: "SoFi", environment: environment)]
        let fidelity = Position(id: "individual|preview-aapl", itemID: "fidelity", institution: "Fidelity", account: "Individual ••1234", symbol: "AAPL", name: "Apple",
            option: nil, quantity: 10, price: 200, value: 2000, reportedCost: 1500)
        let sofi = Position(id: "invest|preview-msft", itemID: "sofi", institution: "SoFi", account: "Invest ••5678", symbol: "MSFT", name: "Microsoft",
            option: nil, quantity: 5, price: 400, value: 2000, reportedCost: 1800)
        let balances = [
            BrokerageBalance(accountID: "individual", itemID: "fidelity", institution: "Fidelity", name: "Individual ••1234", value: 2500, cashValue: 500, holdingsComplete: true, cashMethodVersion: 1),
            BrokerageBalance(accountID: "invest", itemID: "sofi", institution: "SoFi", name: "Invest ••5678", value: 2300, cashValue: 300, holdingsComplete: true, cashMethodVersion: 1)
        ]
        PortfolioStore.shared.snapshot = PortfolioSnapshot(positions: [fidelity, sofi], cashByItem: ["fidelity": 500, "sofi": 300], updated: now,
            costMethodVersion: 2, accountBalances: balances, itemSyncedAt: ["fidelity": now, "sofi": now.addingTimeInterval(-26 * 3600)], failedItemIDs: ["sofi"])
    }
}

enum RecordedBalancePreview {
    static var snapshot: PortfolioSnapshot {
        let end = Date.now
        let balance = BrokerageBalance(accountID: "recorded", itemID: "test", institution: "Test brokerage", name: "Recorded balance example", value: 2400, cashValue: 1680, holdingsComplete: true)
        let position = Position(id: "recorded|option", itemID: "test", institution: "Test brokerage", account: balance.name, symbol: "TEST", name: "Example call",
            option: OptionDetail(isCall: true, strike: 100, expiration: LedgerPreview.day(30), contracts: 1), quantity: 100, price: 7.2, value: 720)
        let values = CommandLine.arguments.contains("-portfolioRecordedSingle") ? [2400.0] : [2200.0, 2350, 2250, 2400]
        let samples = values.enumerated().map { index, value in
            PortfolioBalanceSample(date: end.addingTimeInterval(Double(index - values.count + 1) * 86400), balances: [.init(itemID: "test", accountID: "recorded", value: value)])
        }
        return PortfolioSnapshot(positions: [position], cashByItem: ["test": 1680], updated: end, accountBalances: [balance], balanceHistory: samples)
    }
}
#endif
