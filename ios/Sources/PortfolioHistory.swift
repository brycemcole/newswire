import SwiftUI

nonisolated struct InvestmentHistory: Codable, Sendable {
    let itemID: String
    let start: Date
    let end: Date
    let transactions: [PlaidClient.Transactions.Transaction]
    var cashSecurityIDs: [String]?
    var securities: [HoldingsResponse.Security]?
    var version: Int?
}

nonisolated struct InvestmentCashFlows {
    let contributed: Double
    let withdrawn: Double
    let buys: Double
    let sells: Double
    let unknown: Int
    let records: [PlaidClient.Transactions.Transaction]

    init(history: InvestmentHistory, accountID: String, institution: String? = nil) {
        let records = InvestmentActivity.active(history.transactions).filter { $0.accountId == accountID }
        var contributed = 0.0, withdrawn = 0.0, buys = 0.0, sells = 0.0
        var unknown = 0
        for transaction in records {
            guard transaction.amount.isFinite else { unknown += 1; continue }
            let subtype = transaction.subtype?.lowercased() ?? ""
            let name = transaction.name?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            let soFiDeposit = ["TRANSFER - DEPOSIT USD", "TRANSFER - DEPOSIT CASH IN USD"].contains(name)
            let soFiWithdrawal = ["TRANSFER - WITHDRAWAL USD", "TRANSFER - WITHDRAWAL CASH IN USD"].contains(name)
            let soFiCash = institution?.caseInsensitiveCompare("SoFi") == .orderedSame &&
                transaction.type == "transfer" && subtype == "transfer" &&
                abs(abs(transaction.quantity) - abs(transaction.amount)) < 0.01
            if soFiCash && soFiDeposit {
                if transaction.amount <= 0 { contributed -= transaction.amount } else { unknown += 1 }
            } else if soFiCash && soFiWithdrawal {
                if transaction.amount >= 0 { withdrawn += transaction.amount } else { unknown += 1 }
            } else if transaction.type == "cash", ["deposit", "contribution"].contains(subtype) {
                if transaction.amount <= 0 { contributed -= transaction.amount } else { unknown += 1 }
            } else if transaction.type == "cash", ["withdrawal", "distribution"].contains(subtype) {
                if transaction.amount >= 0 { withdrawn += transaction.amount } else { unknown += 1 }
            } else if transaction.type == "buy", subtype == "contribution" {
                if transaction.amount >= 0 { contributed += transaction.amount } else { unknown += 1 }
            } else if transaction.type == "sell", subtype == "distribution" {
                if transaction.amount <= 0 { withdrawn -= transaction.amount } else { unknown += 1 }
            } else if transaction.type == "buy" {
                buys += abs(transaction.amount)
            } else if transaction.type == "sell" {
                sells += abs(transaction.amount)
            } else if transaction.type == "transfer", subtype == "transfer",
                      transaction.securityId.map({ (history.cashSecurityIDs ?? []).contains($0) }) == true {
                if transaction.amount < 0 { contributed -= transaction.amount }
                else { withdrawn += transaction.amount }
            } else if transaction.type == "transfer" || transaction.type == "cancel" {
                unknown += 1
            } else if transaction.type == "cash", subtype.isEmpty || ["adjustment", "transfer"].contains(subtype) {
                unknown += 1
            }
        }
        self.contributed = contributed
        self.withdrawn = withdrawn
        self.buys = buys
        self.sells = sells
        self.unknown = unknown
        self.records = records
    }
}

struct PortfolioHistoryView: View {
    let account: PortfolioAccount
    let history: InvestmentHistory
    @State private var confirming = false
    @State private var error: String?
    @State private var funding = PortfolioFundingStore.shared
    private var flows: InvestmentCashFlows { InvestmentCashFlows(history: history, accountID: account.id.name, institution: account.institution) }

    var body: some View {
        List {
            Section {
                Text("\(account.institution) · \(account.name)").font(.headline)
                LabeledContent("Recorded contributions", value: Money.text(flows.contributed))
                LabeledContent("Recorded withdrawals", value: Money.text(flows.withdrawn))
                LabeledContent("Net money added", value: Money.text(flows.contributed - flows.withdrawn))
                LabeledContent("Purchases", value: Money.text(flows.buys))
                LabeledContent("Sales", value: Money.text(flows.sells))
            } footer: {
                Text("Plaid history requested from \(history.start.formatted(date: .abbreviated, time: .omitted)) through \(history.end.formatted(date: .abbreviated, time: .omitted)). Purchases and sales reuse money inside the account; they are not added to contributions.")
            }
            Section {
                if flows.unknown > 0 {
                    Text("\(flows.unknown) transfers or cash movements need review before these totals can be used as lifetime contributions.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Button("Use as lifetime contribution totals") { confirming = true }
                        .disabled(flows.records.isEmpty || flows.contributed == 0)
                }
                NavigationLink("Enter or correct lifetime totals") { PortfolioFundingEditor(account: account) }
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("Plaid supplies up to 24 months of investment history. Use these totals only if every deposit and withdrawal since you opened this account is included. Older funding and in-kind transfers need an opening balance or corrected totals.")
            }
            Section("Activity · \(flows.records.count)") {
                ForEach(Array(flows.records.enumerated()), id: \.offset) { _, record in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.name ?? record.subtype ?? record.type).font(.subheadline)
                            Text("\(record.date) · \(record.subtype ?? record.type)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.text(abs(record.amount))).font(.subheadline).monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("Funding & trades").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Does this include every contribution and withdrawal since the account was opened?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Yes, use these totals") {
                do { try funding.save(AccountFunding(contributed: flows.contributed, withdrawn: flows.withdrawn, source: "plaid", historyBeginning: flows.records.map(\.date).min()), for: account) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
