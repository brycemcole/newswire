#if DEBUG
import SwiftUI

struct PortfolioPreview: View {
    init() {
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
        if CommandLine.arguments.contains("-portfolioWidgetPreview") {
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
        let date = day(-2).formatted(Date.ISO8601FormatStyle().year().month().day())
        let history = InvestmentHistory(itemID: "test", start: day(-730), end: end,
            transactions: [.init(accountId: "account", securityId: "sold", type: "sell", quantity: -10, amount: -1200, date: date, subtype: "sell")],
            cashSecurityIDs: [], securities: [.init(securityId: "sold", name: "Example", tickerSymbol: "TEST", type: "equity", optionContract: nil)], version: 1)
        return PortfolioSnapshot(positions: [], cashByItem: ["test": 1200], updated: end,
            accountBalances: [.init(accountID: "account", itemID: "test", institution: "Test brokerage", name: "Sold position example", value: 1200, cashValue: 1200, holdingsComplete: true)],
            histories: CommandLine.arguments.contains("-portfolioMissingHistory") ? nil : [history])
    }
    static var prices: [String: [HistoryPoint]] {
        ["TEST": (-4...0).map { offset in
            let price = min(120, 100 + Double(offset + 4) * 10)
            return HistoryPoint(date: day(offset), close: price, adjusted: price)
        }]
    }
}
#endif
