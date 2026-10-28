import SwiftUI
import WebKit

struct SoFiConnectionView: View {
    var preview = false
    @State private var session = SoFiSession.shared
    @State private var trails = SoFiTrailStore.shared
    @State private var portfolio = PortfolioStore.shared
    @State private var adding = false
    @State private var initialSymbol = ""
    @State private var disconnecting = false
    @Environment(\.scenePhase) private var phase

    private var plaidPositions: [Position] {
        portfolio.snapshot.positions.filter { $0.institution.localizedCaseInsensitiveContains("sofi") }
    }

    private var rules: [SoFiTrail] {
        if preview {
            return [SoFiTrail(symbol: "AAPL", percent: 5, high: 250, lastPrice: 242, quotedAt: .now),
                    SoFiTrail(symbol: "AAPL261218C00250000", percent: 10, high: 8, lastPrice: 7.1, quotedAt: .now, triggeredAt: .now)]
        }
        return trails.rules
    }

    var body: some View {
        List {
            Section {
                Label(preview ? "Preview · example data" : session.status.rawValue, systemImage: "lock.shield")
                    .font(.headline)
                if let message = session.message, !preview {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Button(preview || session.enabled ? "Open SoFi" : "Sign in to SoFi") { session.connect() }
                    .disabled(preview || session.clearing)
                if session.enabled && !preview {
                    Button("Check saved session") { session.refresh() }
                        .disabled(session.status == .checking || session.clearing)
                }
            } footer: {
                Text("Your SoFi session stays in a separate browser profile on this device. Newswire retries it when you return; SoFi may still require sign-in or verification.")
            }

            if !session.holdings.isEmpty && !preview {
                Section {
                    ForEach(session.holdings) { holding in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(OptionSymbol.display(holding.symbol)).font(.headline)
                                Spacer()
                                Text(holding.value.map(Money.text) ?? "Unavailable").monospacedDigit()
                            }
                            Text("\(holding.quantity.formatted()) \(OptionSymbol(holding.symbol) == nil ? "shares" : "contracts") · page price \(holding.price.map(Money.text) ?? "unavailable")")
                                .font(.caption).foregroundStyle(.secondary)
                            if holding.quantity > 0 {
                                Button("Add trailing alert") { initialSymbol = holding.symbol; adding = true }
                            }
                        }
                    }
                } header: { Text("Read from SoFi · partial") } footer: {
                    Text("Visible table rows only; this may exclude other accounts or pages. Read \(session.readAt?.formatted(date: .abbreviated, time: .shortened) ?? "at an unknown time"). SoFi quote time is unknown. \(session.status == .available ? "" : "Retained from an earlier page; refresh needed.")")
                }
            } else {
                Section("Web holdings") {
                    Text("Open your Invest holdings after signing in, then tap Read holdings. Unrecognized pages are never shown as an empty portfolio.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if !plaidPositions.isEmpty && !preview {
                Section {
                    ForEach(plaidPositions) { position in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(position.option.map { "\(position.symbol) · \($0.title)" } ?? position.symbol).font(.headline)
                            Text("\(position.account) · \(position.quantity.formatted()) units")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(plaidStatus(position)).font(.caption).foregroundStyle(.secondary)
                            if position.option == nil && position.quantity > 0 {
                                Button("Add trailing alert") { initialSymbol = position.symbol; adding = true }
                            }
                        }
                    }
                } header: { Text("SoFi holdings via Plaid") } footer: {
                    Text("These are your existing brokerage-sync holdings, separate from the web session. Option alerts require the full contract symbol.")
                }
            }

            Section {
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(OptionSymbol.display(rule.symbol)).font(.headline)
                                Text("\(rule.percent.formatted())% below observed high")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !preview {
                                Menu {
                                    Button(rule.enabled ? "Pause alert" : "Resume alert") { trails.toggle(rule.id) }
                                    Button("Start a new high") { trails.reset(rule.id) }
                                    Button("Delete alert", role: .destructive) { trails.remove(rule.id) }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .accessibilityLabel("Manage \(rule.symbol) trailing alert")
                            }
                        }
                        HStack {
                            metric("High", rule.high)
                            Spacer()
                            metric("Review below", rule.threshold)
                            Spacer()
                            metric("Last", rule.lastPrice)
                        }
                        Text(rule.status(active: preview || (trails.active && phase == .active)))
                            .font(.caption.weight(.medium)).foregroundStyle(rule.triggeredAt == nil ? Color.secondary : .orange)
                        if let stamp = rule.quotedAt {
                            Text("Yahoo quote · \(stamp.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if trails.failures.contains(rule.symbol) && !preview {
                            Text("Quote refresh failed. Retained values were not refreshed.").font(.caption).foregroundStyle(.orange)
                        }
                        if rule.triggeredAt != nil {
                            Button("Review in SoFi") { session.connect() }.disabled(preview)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button { initialSymbol = ""; adding = true } label: {
                    Label("Add trailing alert", systemImage: "plus")
                }
            } header: { Text("Trailing alerts") } footer: {
                Text("Checks every 15 seconds while Newswire is active, during regular US market hours. The high starts with the first fresh quote and persists across launches; missed prices are not reconstructed. Quotes come directly from Yahoo, separate from SoFi. Alerts require your review and never submit trades.")
            }

            if let message = trails.message, !preview {
                Section { Text(message).font(.footnote).foregroundStyle(.orange) }
            }
            if session.enabled && !preview {
                Section {
                    Button("Disconnect SoFi", role: .destructive) { disconnecting = true }
                        .disabled(session.clearing)
                }
            }
        }
        .navigationTitle("SoFi on this device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.regularMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .sheet(isPresented: $session.browserPresented) { SoFiBrowserView(session: session) }
        .sheet(isPresented: $adding) { SoFiTrailEditor(symbol: initialSymbol, preview: preview) }
        .confirmationDialog("Disconnect SoFi?", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("Clear session and trailing alerts", role: .destructive) {
                trails.removeAll()
                Task { await session.disconnect() }
            }
        } message: { Text("Removes this device’s SoFi cookies and trailing alerts. Your Plaid connection stays connected.") }
    }

    private func metric(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value.map(Money.text) ?? "—").font(.subheadline).monospacedDigit()
        }
    }

    private func plaidStatus(_ position: Position) -> String {
        guard let date = portfolio.snapshot.syncedAt(item: position.itemID) else { return "Plaid sync time unknown" }
        return "Plaid synced \(date.formatted(date: .abbreviated, time: .shortened))\(portfolio.snapshot.isStale(position.itemID) ? " · refresh needed" : "")"
    }
}

private struct SoFiTrailEditor: View {
    @State var symbol: String
    var preview = false
    @State private var percent = 5.0
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Stock or full option symbol", text: $symbol)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Stepper("Trail: \(percent.formatted())%", value: $percent, in: 0.25...50, step: 0.25)
                } footer: {
                    Text("For options, enter the exact contract symbol, such as AAPL261218C00250000. The alert follows that contract’s last trade, never the stock price. Illiquid options may not have fresh quotes.")
                }
                Section {
                    Text("This is a review alert for a long position. It is not a stop order. Monitoring pauses when Newswire is inactive and resumes from the saved high when you return.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Trailing alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !preview else { dismiss(); return }
                        do {
                            try SoFiTrailStore.shared.add(symbol: symbol, percent: percent)
                            Task { await SoFiTrailStore.shared.enableNotifications() }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(!SoFiTrail.validSymbol(symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()))
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct SoFiBrowserView: View {
    @Bindable var session: SoFiSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SoFiWebView(webView: session.webView)
                if let message = session.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(10)
                }
                HStack {
                    Button { session.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                        .accessibilityLabel("Back in SoFi")
                    Spacer()
                    Button("Read holdings") { Task { await session.readPage() } }
                    Spacer()
                    Button("Use this page") { session.rememberPortfolioPage() }
                        .disabled(session.status != .available)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("SoFi")
            .navigationSubtitle(session.webView.url?.host ?? "www.sofi.com")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

private struct SoFiWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
