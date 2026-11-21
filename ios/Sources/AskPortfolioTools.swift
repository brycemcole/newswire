import Foundation
import FoundationModels
import Observation

/// A yes/no question put to the reader before the assistant changes a linked account. The model cannot answer it:
/// the tool that needs approval suspends until the reader taps a button in the Ask sheet.
@MainActor @Observable final class ChatApproval {
    static let shared = ChatApproval()

    struct Request: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let action: String
        let destructive: Bool
    }

    private(set) var pending: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    func ask(title: String, message: String, action: String, destructive: Bool = false) async -> Bool {
        resolve(false)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            pending = Request(title: title, message: message, action: action, destructive: destructive)
        }
    }

    /// Also called when the chat is cancelled or closed, so a tool never waits on a prompt nobody can see.
    func resolve(_ approved: Bool) {
        let waiting = continuation
        continuation = nil
        pending = nil
        waiting?.resume(returning: approved)
    }
}

/// What Ask can see and do about the reader's linked brokerages. Everything runs on this device against the same
/// store the Portfolio screen uses, because holdings and Plaid tokens never leave it.
@MainActor enum PortfolioAssistant {
    nonisolated static let toolNames = ["portfolio_status", "portfolio_positions", "portfolio_refresh", "portfolio_reconnect", "portfolio_remove_brokerage"]

    nonisolated static let instructions = """
    Portfolio tools: you can inspect and repair the reader's linked brokerages yourself. When they ask you to look into, fix, reconcile or explain a portfolio problem, start by calling portfolio_status, then portfolio_positions for any symbol or account in question, and report what the data shows. Never ask the reader to open a brokerage app and check something a tool can read. If a brokerage failed its refresh or its data is old, call portfolio_refresh (it only reads, so it needs no permission) and say what changed. If the status says a brokerage needs sign-in again, call portfolio_reconnect; the app asks the reader before it opens Plaid. Call portfolio_remove_brokerage only for a brokerage that is duplicated or no longer wanted; the app asks the reader first, and you must say why you are proposing it. You cannot trade, move money, or edit what a brokerage holds. Quantities and values come from the brokerage through Plaid; if they still look wrong after a refresh, say plainly that the brokerage reports them and what the reader can check, rather than calling the data fixed. Report any failure or remaining gap as it is.
    """

    static var definitions: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:]) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": description,
                "parameters": ["type": "object", "properties": properties, "required": Array(properties.keys), "additionalProperties": false]]]
        }
        let symbolFilter: [String: Any] = ["symbol": ["type": "string", "description": "Ticker to filter by; empty for all."]]
        let institution: [String: Any] = ["institution": ["type": "string", "description": "Brokerage name such as Fidelity or SoFi; empty when only one is linked."]]
        return [
            tool("portfolio_status", "The reader's linked brokerages: last successful refresh time, whether the latest refresh failed or needs sign-in, per-account balances and cash, position counts, reconciliation gaps, and the SoFi web connection. Call this first for any question about sync problems or whether portfolio data can be trusted."),
            tool("portfolio_positions", "The reader's held positions with exact share counts, price, value and cost, per account, flagged when a value does not match quantity times price or the brokerage's data is old. Filter by ticker and/or brokerage; empty strings list everything.",
                 symbolFilter.merging(institution) { first, _ in first }),
            tool("portfolio_refresh", "Re-pull holdings and balances from every linked brokerage (and re-read SoFi if connected) and report what changed and what still fails. Read-only; safe to call without asking."),
            tool("portfolio_reconnect", "Re-authenticate a brokerage whose sign-in expired, by opening Plaid Link on screen. The reader is asked to confirm first and must finish signing in themselves.", institution),
            tool("portfolio_remove_brokerage", "Unlink a brokerage and delete its cached holdings from this device, revoking Newswire's access. Use only for duplicates or links the reader no longer wants. The reader is asked to confirm first.", institution),
        ]
    }

    /// Runs a portfolio tool for a remote model; nil when `name` is not one of them.
    static func run(_ name: String, arguments: String?, progress: @MainActor @Sendable (String) -> Void) async -> String? {
        guard toolNames.contains(name) else { return nil }
        let object = (arguments.flatMap { try? JSONSerialization.jsonObject(with: Data(($0.isEmpty ? "{}" : $0).utf8)) } as? [String: Any]) ?? [:]
        let institution = (object["institution"] as? String) ?? ""
        switch name {
        case "portfolio_status": return status()
        case "portfolio_positions": return positions(symbol: (object["symbol"] as? String) ?? "", institution: institution)
        case "portfolio_refresh": return await refresh(progress: progress)
        case "portfolio_reconnect": return await reconnect(institution: institution)
        default: return await remove(institution: institution)
        }
    }

    // MARK: Reading

    private static func time(_ date: Date?) -> String { date.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "never" }

    static func status(store: PortfolioStore = .shared) -> String {
        let snapshot = store.snapshot
        var lines = ["Brokerage status read from the app at \(time(.now)). Values are as the brokerages last reported them, not live."]
        if !store.credentials.isComplete { lines.append("PROBLEM: Plaid client ID and secret are not entered, so nothing can refresh. The reader adds them in Portfolio > Add Plaid Keys.") }
        if store.activeItems.isEmpty { lines.append("No Plaid brokerage is linked in the \(store.credentials.environment) environment.") }
        if store.syncing { lines.append("A refresh is running right now.") }
        for item in store.activeItems {
            let positions = snapshot.positions.filter { $0.itemID == item.id }
            let failed = snapshot.failedItemIDs?.contains(item.id) == true
            var state = "ok"
            if failed { state = "LATEST REFRESH FAILED; showing older values" }
            else if snapshot.syncedAt(item: item.id) == nil { state = "never refreshed successfully" }
            lines.append("\n\(item.institution) (link \(item.id.prefix(8))): \(state). Last successful refresh \(time(snapshot.syncedAt(item: item.id))). \(positions.count) positions, cash \(Money.text(snapshot.cashByItem[item.id] ?? 0)).")
            if store.needsRelink.contains(item.id) { lines.append("  Needs sign-in again (Plaid reports the login expired). Use portfolio_reconnect.") }
            if let error = store.itemErrors[item.id] { lines.append("  Last error: \(error)") }
            for balance in snapshot.accountBalances?.filter({ $0.itemID == item.id }) ?? [] {
                let held = positions.filter { $0.id.hasPrefix(balance.accountID + "|") }
                let valued = held.compactMap(\.value).reduce(0, +)
                var line = "  Account \(balance.name): reported value \(balance.value.map(Money.text) ?? "unavailable"), cash \(balance.cashValue.map(Money.text) ?? "unknown"), positions \(Money.text(valued)) across \(held.count)"
                if held.contains(where: { $0.value == nil }) { line += ", some positions have no value" }
                if balance.holdingsComplete != true { line += ". INCOMPLETE: the brokerage's holdings did not fully account for the balance" }
                if let value = balance.value, let cash = balance.cashValue, abs(value - cash - valued) > max(1, abs(value) * 0.01) {
                    line += ". GAP: reported value minus cash minus positions is \(Money.text(value - cash - valued))"
                }
                lines.append(line)
            }
        }
        let linked = Set(store.activeItems.map(\.id))
        let orphans = snapshot.itemIDs.subtracting(linked)
        if !orphans.isEmpty && !store.activeItems.isEmpty {
            let orphaned = snapshot.positions.filter { orphans.contains($0.itemID) }
            lines.append("\nWARNING: cached data exists for \(orphans.count) brokerage link(s) that are not active (\(Set(orphaned.map(\.institution)).sorted().joined(separator: ", "))); their positions may be counted in the portfolio twice or be stale.")
        }
        let duplicates = Dictionary(grouping: store.activeItems, by: { $0.institution.lowercased() }).filter { $0.value.count > 1 }
        for (_, items) in duplicates { lines.append("\nWARNING: \(items[0].institution) is linked \(items.count) times; check the accounts are different, not a duplicate link.") }
        lines.append(soFi(snapshot))
        return lines.joined(separator: "\n")
    }

    private static func soFi(_ snapshot: PortfolioSnapshot) -> String {
        let session = SoFiSession.shared
        guard session.enabled else { return "\nSoFi web connection: not set up (SoFi data, if any, comes through Plaid)." }
        var text = "\nSoFi web connection: \(session.status.rawValue); \(session.holdings.count) holdings read \(time(session.readAt))."
        if let message = session.message { text += " \(message)" }
        let plaid = snapshot.positions.filter { $0.institution.localizedCaseInsensitiveContains("sofi") && $0.option == nil }
        for holding in session.holdings where OptionSymbol(holding.symbol) == nil {
            let counted = plaid.filter { $0.symbol == holding.symbol }.map(\.quantity).reduce(0, +)
            if abs(counted - holding.quantity) > 0.0001 { text += "\n  MISMATCH \(holding.symbol): SoFi page \(holding.quantity.formatted()) vs Plaid \(counted.formatted())."}
        }
        return text
    }

    static func positions(symbol: String, institution: String, store: PortfolioStore = .shared) -> String {
        let snapshot = store.snapshot
        let wanted = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        let rows = snapshot.positions.filter { position in
            (wanted.isEmpty || position.symbol == wanted || OptionSymbol(position.symbol)?.underlying == wanted) &&
                (institution.isEmpty || position.institution.localizedCaseInsensitiveContains(institution))
        }
        guard !rows.isEmpty else { return "No held position matches symbol \"\(symbol)\" at \"\(institution)\"." + (snapshot.positions.isEmpty ? " The portfolio has no positions at all; check portfolio_status." : "") }
        var lines = ["\(rows.count) positions (exact quantities; units are shares, or contracts for options):"]
        for position in rows.prefix(60) {
            var line = "\(position.institution) · \(position.account) · \(position.option.map { _ in OptionSymbol.display(position.symbol) } ?? position.symbol): quantity \(position.quantity.formatted(.number.precision(.fractionLength(0...6)))), price \(position.price.map(Money.text) ?? "none"), value \(position.value.map(Money.text) ?? "none")"
            if let cost = position.costBasis { line += ", cost \(Money.text(cost))\(position.isEstimated ? " (estimated)" : "")" }
            if position.option == nil, let price = position.price, let value = position.value, abs(price * position.quantity - value) > max(1, abs(value) * 0.02) {
                line += ". CHECK: quantity × price is \(Money.text(price * position.quantity)) but the brokerage reports value \(Money.text(value))"
            }
            if snapshot.isStale(position.itemID) { line += ". STALE: this brokerage's latest refresh failed or never succeeded" }
            lines.append(line)
        }
        if rows.count > 60 { lines.append("…and \(rows.count - 60) more; narrow with a symbol or brokerage.") }
        let session = SoFiSession.shared
        if session.enabled, !session.holdings.isEmpty {
            let match = session.holdings.filter { wanted.isEmpty || $0.symbol.hasPrefix(wanted) }
            if !match.isEmpty { lines.append("SoFi web page (\(time(session.readAt))): " + match.prefix(20).map { "\($0.symbol) \($0.quantity.formatted())" }.joined(separator: ", ")) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Acting

    static func refresh(progress: @MainActor @Sendable (String) -> Void, store: PortfolioStore = .shared) async -> String {
        guard store.credentials.isComplete else { return "Cannot refresh: Plaid client ID and secret are not entered. The reader adds them in Portfolio > Add Plaid Keys." }
        guard !store.activeItems.isEmpty else { return "Cannot refresh: no Plaid brokerage is linked. The reader links one with Portfolio > Connect account." }
        for _ in 0..<60 where store.syncing { try? await Task.sleep(for: .milliseconds(500)) }
        let before = Dictionary(store.snapshot.positions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        progress("Refreshing your brokerages…")
        await store.sync()
        var lines = [store.syncing ? "A refresh was already running and had not finished." : "Refresh finished at \(time(.now))."]
        var changes: [String] = []
        for position in store.snapshot.positions {
            guard let old = before[position.id] else { changes.append("NEW \(position.institution) \(position.symbol): \(position.quantity.formatted())"); continue }
            if abs(old.quantity - position.quantity) > 0.000001 || abs((old.value ?? 0) - (position.value ?? 0)) > 0.5 {
                changes.append("\(position.institution) \(position.symbol): quantity \(old.quantity.formatted()) → \(position.quantity.formatted()), value \(old.value.map(Money.text) ?? "none") → \(position.value.map(Money.text) ?? "none")")
            }
        }
        let now = Set(store.snapshot.positions.map(\.id))
        for (id, old) in before where !now.contains(id) { changes.append("GONE \(old.institution) \(old.symbol): was \(old.quantity.formatted())") }
        lines.append(changes.isEmpty ? "No position quantity or value changed." : "Changes:\n" + changes.prefix(25).joined(separator: "\n"))
        let session = SoFiSession.shared
        if session.enabled {
            progress("Re-reading SoFi…")
            session.refresh()
            for _ in 0..<24 where session.status == .checking { try? await Task.sleep(for: .milliseconds(500)) }
        }
        lines.append(status(store: store))
        return lines.joined(separator: "\n")
    }

    private enum Match { case item(PlaidItem), problem(String) }

    private static func match(_ institution: String, store: PortfolioStore) -> Match {
        let items = store.activeItems
        let query = institution.trimmingCharacters(in: .whitespaces)
        let found = query.isEmpty ? items : items.filter { $0.institution.localizedCaseInsensitiveContains(query) }
        if found.count == 1 { return .item(found[0]) }
        if found.isEmpty { return .problem("No linked brokerage matches \"\(query)\". Linked: \(items.map(\.institution).joined(separator: ", ")).") }
        return .problem("More than one brokerage matches. Say which: \(found.map { "\($0.institution) (link \($0.id.prefix(8)))" }.joined(separator: ", ")). Pass the institution name; if two share a name, ask the reader.")
    }

    static func reconnect(institution: String, store: PortfolioStore = .shared) async -> String {
        guard store.credentials.isComplete else { return "Cannot reconnect: Plaid client ID and secret are not entered." }
        switch match(institution, store: store) {
        case let .problem(text): return text
        case let .item(item):
            guard await ChatApproval.shared.ask(title: "Sign in to \(item.institution) again?", message: "Plaid will open so you can re-authorize \(item.institution). Nothing is traded or changed at the brokerage.", action: "Open Plaid") else {
                return "The reader declined to reconnect \(item.institution). Nothing was changed."
            }
            await store.connect(updating: item)
            if let error = store.error { return "Could not open Plaid: \(error)" }
            return "Plaid sign-in for \(item.institution) is open on the reader's screen. Tell them to finish it; the portfolio refreshes by itself when they do. Do not claim it is fixed until portfolio_status shows a new successful refresh."
        }
    }

    static func remove(institution: String, store: PortfolioStore = .shared) async -> String {
        switch match(institution, store: store) {
        case let .problem(text): return text
        case let .item(item):
            let count = store.snapshot.positions.filter { $0.itemID == item.id }.count
            guard await ChatApproval.shared.ask(title: "Unlink \(item.institution)?", message: "This revokes Newswire's access to \(item.institution) and removes its \(count) positions and balances from this device. Your brokerage account is not touched. You can link it again later.", action: "Unlink", destructive: true) else {
                return "The reader declined. \(item.institution) is still linked."
            }
            await store.remove(item)
            if let error = store.error { return "Unlink may be incomplete: \(error)" }
            return "\(item.institution) was unlinked and its cached data removed. Re-linking is possible from Portfolio > Connect account."
        }
    }
}

// MARK: On-device model tools. The small on-device model gets the read-only and refresh tools only.

@Generable
nonisolated struct PortfolioFilterArguments: Codable, Sendable {
    @Guide(description: "Ticker to filter by; empty for all")
    var symbol: String
    @Guide(description: "Brokerage name such as Fidelity; empty for all")
    var institution: String
}

@Generable
nonisolated struct PortfolioNoArguments: Codable, Sendable {
    @Guide(description: "Why this is needed, a few words")
    var reason: String
}

nonisolated struct PortfolioStatusTool: Tool {
    let name = "portfolio_status"
    let description = "The reader's linked brokerages: last refresh time, failed refreshes, per-account balances and gaps. Call first for any sync problem."
    @concurrent func call(arguments: PortfolioNoArguments) async throws -> String { await MainActor.run { PortfolioAssistant.status() } }
}

nonisolated struct PortfolioPositionsTool: Tool {
    let name = "portfolio_positions"
    let description = "Held positions with exact share counts, price and value, optionally filtered by ticker or brokerage."
    @concurrent func call(arguments: PortfolioFilterArguments) async throws -> String {
        await MainActor.run { PortfolioAssistant.positions(symbol: arguments.symbol, institution: arguments.institution) }
    }
}

nonisolated struct PortfolioRefreshTool: Tool {
    let name = "portfolio_refresh"
    let description = "Re-pull holdings from every linked brokerage and report what changed. Read-only."
    let progress: @MainActor @Sendable (String) -> Void
    @concurrent func call(arguments: PortfolioNoArguments) async throws -> String { await PortfolioAssistant.refresh(progress: progress) }
}
