import SwiftUI

struct PortfolioView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PortfolioStore.shared
    @State private var editingKeys = false
    @State private var removing: PlaidItem?

    @State private var account: PortfolioAccount.ID?
    @State private var search = ""
    @AppStorage("portfolioHoldingsSort") private var sort = PortfolioHolding.Sort.value
    @State private var showingPaper = false
    @State private var managingAccounts = false

    init() {
        #if DEBUG
        if CommandLine.arguments.contains("-portfolioSelfDirected") {
            _account = State(initialValue: PortfolioAccount.group(PortfolioStore.shared.snapshot).first { $0.institution == "SoFi" && $0.name.contains("Self-directed") }?.id)
        }
        if CommandLine.arguments.contains("-portfolioAccount") {
            _account = State(initialValue: PortfolioAccount.ID(item: "fidelity", name: "ira"))
        }
        if CommandLine.arguments.contains("-portfolioSearch") {
            _search = State(initialValue: "NVDA")
        }
        #endif
    }

    private var hasPortfolio: Bool { !accounts.isEmpty || store.snapshot.cash != 0 }

    private var accounts: [PortfolioAccount] { PortfolioAccount.group(store.snapshot) }
    private var selectedPositions: [Position] {
        guard let account else { return store.snapshot.positions }
        return accounts.first { $0.id == account }?.positions ?? []
    }
    private var overviewSnapshot: PortfolioSnapshot {
        guard let account, let entry = accounts.first(where: { $0.id == account }) else { return store.snapshot }
        let balances = store.snapshot.accountBalances?.filter { $0.itemID == account.item && $0.accountID == account.name }
        let residual = entry.reportedValue.map { $0 - entry.positions.compactMap(\.value).reduce(0, +) }
        return PortfolioSnapshot(positions: entry.positions, cashByItem: residual.map { [account.item: $0] } ?? [:],
                                 updated: store.snapshot.updated, costMethodVersion: store.snapshot.costMethodVersion, accountBalances: balances, histories: store.snapshot.histories)
    }

    private var holdings: [PortfolioHolding] {
        PortfolioHolding.group(selectedPositions, search: search, sort: sort)
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.credentials.isComplete && !hasPortfolio {
                    Section {
                        Button { editingKeys = true } label: { Label("Add Plaid Keys", systemImage: "key") }
                    } footer: {
                        Text("Enter your Plaid client ID and secret once. They sync through iCloud Keychain.")
                    }
                } else if store.activeItems.isEmpty && !hasPortfolio {
                    Section {
                        connectButton
                    } footer: {
                        Text("Sign in to Fidelity, SoFi, or another brokerage through Plaid. Newswire reads positions only.")
                    }
                }
                if hasPortfolio {
                    Section {
                        Menu {
                            Button("All accounts") { account = nil }
                            ForEach(accounts) { entry in
                                Button("\(entry.institution) · \(entry.name)") { account = entry.id }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.flatMap { id in accounts.first { $0.id == id }?.institution } ?? "All accounts")
                                        .font(.headline).foregroundStyle(.primary)
                                    Text(account.flatMap { id in accounts.first { $0.id == id }?.name } ?? "\(accounts.count) accounts · \(store.snapshot.positions.count) positions")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                            }
                        }
                        .accessibilityLabel("Filter holdings by account")

                    }
                    Section {
                        PortfolioOverview(snapshot: overviewSnapshot, title: account == nil ? "All accounts" : accounts.first { $0.id == account }?.institution ?? "Account", accounts: account.flatMap { id in accounts.first { $0.id == id }.map { [$0] } } ?? accounts)
                            .id(account)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    Section {
                        ForEach(holdings) { holding in
                            PortfolioHoldingRow(holding: holding)
                        }
                        if holdings.isEmpty {
                            ContentUnavailableView.search(text: search)
                        }
                    } header: {
                        HStack {
                            Text("Holdings · \(holdings.count)")
                            Spacer()
                            Menu {
                                Picker("Sort holdings", selection: $sort) {
                                    ForEach(PortfolioHolding.Sort.allCases) { Text($0.rawValue).tag($0) }
                                }
                            } label: { Label(sort.rawValue, systemImage: "arrow.up.arrow.down") }
                            .textCase(nil)
                        }
                    } footer: {
                        Text("Tap a holding for positions by account. Partial unrealized gain excludes missing costs; ≈ indicates an estimate from trade history.")
                    }
                } else if !store.activeItems.isEmpty {
                    Section { Text(store.syncing ? "Syncing…" : "No holdings").foregroundStyle(.secondary) }
                }
                if account != nil {
                    Section {
                        DisclosureGroup("Position totals") {
                            LabeledContent("Holdings value", value: Money.text(selectedPositions.compactMap(\.value).reduce(0, +))).monospacedDigit()
                            PortfolioGainSummary(positions: selectedPositions)
                        }
                    }
                }
                if !PaperPortfolio.shared.trades.isEmpty {
                    Section {
                        Toggle("Show paper trades", isOn: $showingPaper)
                    }
                    if showingPaper { PaperTradesSection() }
                }
                if store.credentials.isComplete && !store.activeItems.isEmpty {
                    Section {
                        DisclosureGroup("Manage brokerages", isExpanded: $managingAccounts) {
                            ForEach(store.activeItems) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.institution)
                                        Spacer()
                                        if store.needsRelink.contains(item.id) {
                                            Button("Sign In") { Task { await store.connect(updating: item) } }
                                                .buttonStyle(.borderless)
                                        }
                                        Button(role: .destructive) { removing = item } label: { Image(systemName: "minus.circle") }
                                            .buttonStyle(.borderless).accessibilityLabel("Remove \(item.institution)")
                                    }
                                    if let error = store.itemErrors[item.id] {
                                        Text(error).font(.footnote).foregroundStyle(.red)
                                    }
                                }
                            }
                            connectButton
                        }
                    }
                }
                if let error = store.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .listSectionSpacing(12)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .searchable(text: $search, prompt: "Find a symbol or company")
            .onChange(of: accounts.map(\.id)) { _, ids in
                if let account, !ids.contains(account) { self.account = nil }
            }
            .refreshable { await store.sync() }
            .navigationTitle("Portfolio")
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MarketSymbol.self) { QuoteDetail(symbol: $0.id) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { editingKeys = true } label: { Image(systemName: "key") }
                        .accessibilityLabel("Plaid keys")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $editingKeys) { PlaidKeysView(store: store) }
            .confirmationDialog("Remove \(removing?.institution ?? "account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let item = removing { Task { await store.remove(item) } }
                    removing = nil
                }
            } message: {
                Text("Newswire stops syncing this account. Plaid does not refund the connection.")
            }
            .task {
                #if DEBUG
                if CommandLine.arguments.contains("-portfolioPreview") || CommandLine.arguments.contains("-portfolioAudit") { return }
                #endif
                store.reloadFromKeychain()
                if store.snapshot.accountBalances == nil || store.snapshot.histories == nil || store.snapshot.histories?.contains(where: { $0.cashSecurityIDs == nil }) == true || store.snapshot.costMethodVersion != 2 || (store.snapshot.updated ?? .distantPast).timeIntervalSinceNow < -300 { await store.sync() }
            }
            .onOpenURL { url in
                if url.path.hasPrefix("/plaid") { store.resume(from: url) }
            }
        }
    }

    private var subtitle: String {
        if store.syncing { return "Syncing…" }
        guard let updated = store.snapshot.updated else { return "" }
        return "Updated " + updated.formatted(.relative(presentation: .named))
    }

    private var connectButton: some View {
        Button {
            Task { await store.connect() }
        } label: {
            HStack {
                Label("Add Brokerage", systemImage: "plus")
                if store.linking { Spacer(); ProgressView() }
            }
        }
        .disabled(store.linking)
    }
}

struct PositionRow: View {
    let position: Position
    var showsAccount = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                if showsAccount { Text("\(position.institution) · \(position.account)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let value = position.value {
                    Text(Money.text(value)).font(.body.monospacedDigit())
                }
                if let gain = position.gain {
                    Text(gainText(gain))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Money.tint(gain))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String { position.option?.title ?? "Shares" }

    private var detail: String {
        guard let option = position.option else {
            let shares = position.quantity.formatted(.number.precision(.fractionLength(0...4)))
            guard let cost = position.costBasis, position.quantity != 0 else { return "\(shares) shares" }
            return "\(shares) shares · avg \(Money.text(cost / position.quantity))"
        }
        let expiry = switch option.daysLeft {
        case ..<0: "Expired"
        case 0: "Expires today"
        default: "\(option.daysLeft)d"
        }
        let count = option.contracts.formatted(.number.precision(.fractionLength(0...2)))
        let contracts = abs(option.contracts) == 1 ? "\(count) contract" : "\(count) contracts"
        return "\(option.expiration.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))) · \(expiry) · \(contracts)"
    }

    private func gainText(_ gain: Double) -> String {
        let percent = position.gainPercent.map { " (\(Money.percent($0)))" } ?? ""
        return (position.isEstimated ? "≈" : "") + Money.signed(gain) + percent
    }
}

struct PlaidKeysView: View {
    @Environment(\.dismiss) private var dismiss
    let store: PortfolioStore
    @State private var clientID = ""
    @State private var secret = ""
    @State private var environment = PlaidEnvironment.production
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Client ID", text: $clientID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    SecureField("Secret", text: $secret)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    Picker("Environment", selection: $environment) {
                        ForEach(PlaidEnvironment.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Stored in iCloud Keychain and sent only to Plaid. Use the secret that matches the environment. The free Trial plan uses Production.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Plaid Keys").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let keys = PlaidCredentials(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    secret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    environment: environment)
                        do {
                            try store.save(keys)
                            dismiss()
                            Task { await store.sync() }
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(clientID.isEmpty || secret.isEmpty)
                }
            }
            .onAppear {
                clientID = store.credentials.clientID
                secret = store.credentials.secret
                environment = store.credentials.environment
            }
        }
    }
}

struct BrokerageSyncView: View {
    @State private var store = PortfolioStore.shared
    @State private var editingKeys = false

    private let steps: [(title: String, detail: String)] = [
        ("Create a Plaid account", "Sign up at dashboard.plaid.com, then open Developers > Keys."),
        ("Choose an environment", "Production connects real brokerages (the free Trial plan uses it). Sandbox uses fake data; sign in with user_good / pass_good."),
        ("Register the redirect URI", "In Developers > API, add \(PlaidClient.redirectURI) under Allowed redirect URIs. Brokerages like Fidelity and Schwab need it."),
        ("Add your keys", "Enter the client ID and the secret for that environment below."),
        ("Connect a brokerage", "Open the Portfolio tab, choose Connect account, and sign in through Plaid. Newswire reads positions only."),
    ]

    var body: some View {
        Form {
            Section("Setup") {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(step.title)").font(.headline)
                        Text(step.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                Button { editingKeys = true } label: {
                    Label(store.credentials.isComplete ? "Edit Plaid Keys" : "Add Plaid Keys", systemImage: "key")
                }
            } footer: {
                Text("Keys are stored in iCloud Keychain and sent only to Plaid. They are never in the app bundle, the repository, or the Newswire server. Treat the secret like a password and rotate it in Plaid if it leaks.")
            }
        }
        .navigationTitle("Brokerage Sync").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingKeys) { PlaidKeysView(store: store) }
    }
}
