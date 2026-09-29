import SwiftUI

enum Money {
    static func text(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
    static func signed(_ value: Double) -> String { (value >= 0 ? "+" : "−") + abs(value).formatted(.currency(code: "USD")) }
    static func percent(_ value: Double) -> String { (value >= 0 ? "+" : "−") + abs(value).formatted(.percent.precision(.fractionLength(1))) }
    static func tint(_ value: Double) -> Color { value >= 0 ? .green : .red }
}

struct PortfolioView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = PortfolioStore.shared
    @State private var editingKeys = false
    @State private var removing: PlaidItem?

    private var groups: [(symbol: String, positions: [Position])] {
        Dictionary(grouping: store.snapshot.positions, by: \.symbol)
            .map { ($0.key, $0.value) }
            .sorted { $0.symbol < $1.symbol }
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.credentials.isComplete {
                    Section {
                        Button { editingKeys = true } label: { Label("Add Plaid Keys", systemImage: "key") }
                    } footer: {
                        Text("Enter your Plaid client ID and secret once. They sync through iCloud Keychain.")
                    }
                } else if store.activeItems.isEmpty {
                    Section {
                        connectButton
                    } footer: {
                        Text("Sign in to Fidelity, SoFi, or another brokerage through Plaid. Newswire reads positions only.")
                    }
                } else if groups.isEmpty {
                    Section { Text(store.syncing ? "Syncing…" : "No holdings").foregroundStyle(.secondary) }
                } else {
                    Section { summary }
                }
                ForEach(groups, id: \.symbol) { group in
                    Section {
                        ForEach(group.positions) { position in
                            NavigationLink(value: MarketSymbol(id: group.symbol)) { PositionRow(position: position) }
                        }
                    } header: {
                        NavigationLink(value: MarketSymbol(id: group.symbol)) {
                            HStack(spacing: 4) {
                                Text(group.symbol).font(.headline).foregroundStyle(.primary)
                                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .textCase(nil)
                    }
                }
                if store.credentials.isComplete && !store.activeItems.isEmpty {
                    Section("Accounts") {
                        ForEach(store.activeItems) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.institution)
                                    Spacer()
                                    if store.needsRelink.contains(item.id) {
                                        Button("Sign In") { Task { await store.connect(updating: item) } }
                                            .buttonStyle(.borderless)
                                    }
                                }
                                if let error = store.itemErrors[item.id] {
                                    Text(error).font(.footnote).foregroundStyle(.red)
                                }
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) { removing = item }
                            }
                        }
                        connectButton
                    }
                }
                if let error = store.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.3), value: store.snapshot.positions)
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
                store.reloadFromKeychain()
                if (store.snapshot.updated ?? .distantPast).timeIntervalSinceNow < -300 { await store.sync() }
            }
            .onOpenURL { url in
                if url.path.hasPrefix("/plaid") { store.resume(from: url) }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Money.text(store.snapshot.totalValue))
                .font(.largeTitle.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            HStack(spacing: 10) {
                if let gain = store.snapshot.totalGain {
                    Text("\(Money.signed(gain)) total").foregroundStyle(Money.tint(gain))
                }
                if store.snapshot.cash != 0 {
                    Text("\(Money.text(store.snapshot.cash)) cash").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.medium).monospacedDigit())
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                Text("\(position.institution) · \(position.account)").font(.caption).foregroundStyle(.tertiary)
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
