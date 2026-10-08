import SwiftUI

nonisolated struct AccountFunding: Codable, Equatable {
    let contributed: Double
    let withdrawn: Double?
    var approximate: Bool?
    var source: String?
    var historyBeginning: String?
    var netContributed: Double? { withdrawn.map { contributed - $0 } }
    func gain(value: Double) -> Double? { withdrawn.map { value + $0 - contributed } }
}

@Observable final class PortfolioFundingStore {
    static let shared = PortfolioFundingStore()
    private static let storageURL = URL.applicationSupportDirectory.appending(path: "portfolio-funding.json")
    private(set) var totals: [String: AccountFunding]

    init() {
        totals = (try? Data(contentsOf: Self.storageURL))
            .flatMap { try? JSONDecoder().decode([String: AccountFunding].self, from: $0) } ?? [:]
    }

    #if DEBUG
    func preview(accounts: [PortfolioAccount]) {
        for account in accounts {
            let value = account.reportedValue ?? 0
            totals[key(account)] = AccountFunding(contributed: value + 3200 / Double(accounts.count), withdrawn: 0, approximate: true)
        }
    }
    #endif

    func funding(for account: PortfolioAccount) -> AccountFunding? { totals[key(account)] }

    func resolved(for account: PortfolioAccount) -> AccountFunding? {
        guard let saved = funding(for: account) else { return nil }
        guard saved.source == "plaid" else { return saved }
        guard let history = account.history, let beginning = saved.historyBeginning,
              let date = HoldingsResponse.date(beginning), Calendar.current.startOfDay(for: history.start) <= date else { return nil }
        let flows = InvestmentCashFlows(history: history, accountID: account.id.name, institution: account.institution)
        guard flows.unknown == 0, !flows.records.isEmpty else { return nil }
        return AccountFunding(contributed: flows.contributed, withdrawn: flows.withdrawn, source: "plaid", historyBeginning: beginning)
    }

    func save(_ funding: AccountFunding?, for account: PortfolioAccount) throws {
        if let funding {
            guard funding.contributed.isFinite, funding.withdrawn.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  funding.contributed >= 0 else { return }
        }
        var next = totals
        next[key(account)] = funding
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try data.write(to: Self.storageURL, options: [.atomic, .completeFileProtection])
        totals = next
    }

    private func key(_ account: PortfolioAccount) -> String {
        "\(account.id.item.count):\(account.id.item)\(account.id.name)"
    }

    func combined(for accounts: [PortfolioAccount]) -> AccountFunding? {
        guard !accounts.isEmpty else { return nil }
        let funding = accounts.compactMap { resolved(for: $0) }
        guard funding.count == accounts.count, funding.allSatisfy({ $0.withdrawn != nil }) else { return nil }
        return AccountFunding(contributed: funding.reduce(0) { $0 + $1.contributed }, withdrawn: funding.reduce(0) { $0 + ($1.withdrawn ?? 0) }, approximate: funding.contains { $0.approximate == true })
    }
}

struct PortfolioFundingView: View {
    let accounts: [PortfolioAccount]
    @State private var funding = PortfolioFundingStore.shared
    @State private var editing: PortfolioAccount?

    var body: some View {
        List {
            Section {
                ForEach(accounts) { account in
                    Button { editing = account } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.institution).font(.headline).foregroundStyle(.primary)
                            Text(account.name).font(.subheadline).foregroundStyle(.secondary)
                            if let totals = funding.resolved(for: account) {
                                Text("\(Money.text(totals.contributed)) contributed · \(totals.withdrawn.map(Money.text) ?? "Not set") withdrawn")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else { Text("Set all-time totals").font(.caption).foregroundStyle(Color.wireAccent) }
                        }
                    }
                    if let history = account.history {
                        NavigationLink("Review funding & trades") { PortfolioHistoryView(account: account, history: history) }
                    }
                }
            } footer: {
                Text("Plaid funding history is available below each account. Use all-time external deposits and withdrawals from your brokerage. Buying and selling inside the account does not change contributions. These totals are saved on this device and are not inferred from Plaid’s limited history.")
            }
        }
        .navigationTitle("Contributions").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { PortfolioFundingEditor(account: $0) }
    }
}

struct PortfolioFundingEditor: View {
    let account: PortfolioAccount
    @Environment(\.dismiss) private var dismiss
    @State private var funding = PortfolioFundingStore.shared
    @State private var contributed = ""
    @State private var withdrawn = ""
    @State private var approximate = false
    @State private var error: String?

    private var entered: AccountFunding? {
        func amount(_ text: String) -> Double? {
            let clean = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Double(clean), value.isFinite, value >= 0 else { return nil }
            return value
        }
        guard let deposits = amount(contributed), let withdrawals = amount(withdrawn) else { return nil }
        return AccountFunding(contributed: deposits, withdrawn: withdrawals, approximate: approximate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Brokerage", value: account.institution)
                    Text(account.name).foregroundStyle(.secondary)
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("All-time contributions").font(.subheadline)
                        TextField("Total deposited ($)", text: $contributed).keyboardType(.decimalPad)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("All-time withdrawals").font(.subheadline)
                        TextField("Total withdrawn ($), or 0", text: $withdrawn).keyboardType(.decimalPad)
                    }
                    Toggle("Totals are approximate", isOn: $approximate)
                } footer: {
                    Text("Include money and the starting value of securities transferred into or out of the account. Include payouts taken out. Do not count purchases, sales or reinvested dividends as contributions.")
                }
                Section {
                    Text("Account gain = current brokerage value + withdrawals − contributions. Lifetime totals alone cannot determine a timing-aware percentage return. The chart calculates an estimated percentage from dated transactions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if funding.funding(for: account) != nil {
                    Button("Clear totals", role: .destructive) {
                        do { try funding.save(nil, for: account); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .navigationTitle("Account totals").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let entered {
                            do { try funding.save(entered, for: account); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(entered == nil)
                }
            }
            .onAppear {
                if let totals = funding.resolved(for: account) ?? funding.funding(for: account) {
                    contributed = totals.contributed.formatted(.number.precision(.fractionLength(2)).grouping(.never))
                    withdrawn = totals.withdrawn.map { $0.formatted(.number.precision(.fractionLength(2)).grouping(.never)) } ?? ""
                    approximate = totals.approximate == true
                }
            }
        }
    }
}
