import Foundation
import LinkKit
import Observation
import Security
import UIKit

nonisolated enum PlaidEnvironment: String, CaseIterable, Identifiable, Codable, Sendable {
    case production, sandbox
    var id: String { rawValue }
    var title: String { self == .production ? "Production" : "Sandbox" }
    var host: URL { URL(string: "https://\(rawValue).plaid.com")! }
}

nonisolated enum PlaidKeychain {
    static let service = "com.brycecole.newswire.plaid"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: true]
    }

    static func data(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(_ account: String) -> String {
        data(account).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func set(_ value: Data?, for account: String) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PlaidError.keychain }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: value,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw PlaidError.keychain }
        } else if status != errSecSuccess { throw PlaidError.keychain }
    }
}

nonisolated struct PlaidCredentials: Sendable, Equatable {
    var clientID: String
    var secret: String
    var environment: PlaidEnvironment

    var isComplete: Bool { !clientID.isEmpty && !secret.isEmpty }

    static func load() -> PlaidCredentials {
        PlaidCredentials(clientID: PlaidKeychain.string("clientID"),
                         secret: PlaidKeychain.string("secret"),
                         environment: PlaidEnvironment(rawValue: PlaidKeychain.string("environment")) ?? .production)
    }

    func save() throws {
        try PlaidKeychain.set(Data(clientID.utf8), for: "clientID")
        try PlaidKeychain.set(Data(secret.utf8), for: "secret")
        try PlaidKeychain.set(Data(environment.rawValue.utf8), for: "environment")
    }
}

nonisolated struct PlaidItem: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let accessToken: String
    let institution: String
    let environment: PlaidEnvironment
}

nonisolated enum PlaidError: LocalizedError, Sendable {
    case keychain, credentials, noWindow
    case api(code: String, message: String)
    case link(String)

    var errorDescription: String? {
        switch self {
        case .keychain: "Could not save to the Keychain. Please try again."
        case .credentials: "Add your Plaid client ID and secret first."
        case .noWindow: "Could not open Plaid right now."
        case let .api(_, message): message
        case let .link(message): message
        }
    }

    var code: String? { if case let .api(code, _) = self { code } else { nil } }
}

nonisolated struct OptionDetail: Codable, Sendable, Hashable {
    let isCall: Bool
    let strike: Double
    let expiration: Date
    let contracts: Double

    var daysLeft: Int { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: expiration).day ?? 0 }
    var title: String { "\(strike.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))) \(isCall ? "Call" : "Put")" }

    func intrinsic(at price: Double) -> Double {
        max(0, isCall ? price - strike : strike - price) * 100 * contracts
    }
}

nonisolated struct Position: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let itemID: String
    let institution: String
    let account: String
    let symbol: String
    let name: String?
    let option: OptionDetail?
    let quantity: Double
    let price: Double?
    let value: Double?
    var reportedCost: Double?
    var costEstimated = false
    var manualCost: Double?

    var costBasis: Double? { manualCost ?? reportedCost }
    var isEstimated: Bool { manualCost == nil && costEstimated }
    var gain: Double? { value.flatMap { value in costBasis.map { value - $0 } } }
    var gainPercent: Double? {
        guard let gain, let costBasis, costBasis != 0 else { return nil }
        return gain / abs(costBasis)
    }

    var breakeven: Double? {
        guard let option, let costBasis, option.contracts != 0 else { return nil }
        let premium = abs(costBasis) / (100 * abs(option.contracts))
        return option.isCall ? option.strike + premium : option.strike - premium
    }

    func liveValue(underlying price: Double) -> Double? {
        option == nil ? quantity * price : nil
    }
}

nonisolated struct BrokerageBalance: Codable, Sendable {
    let accountID: String
    let itemID: String
    let institution: String
    let name: String
    let value: Double?
    var cashValue: Double?
    var holdingsComplete: Bool?
}

nonisolated struct PortfolioSnapshot: Codable, Sendable {
    var positions: [Position] = []
    var cashByItem: [String: Double] = [:]
    var updated: Date?
    var costMethodVersion: Int?
    var accountBalances: [BrokerageBalance]?
    var histories: [InvestmentHistory]?

    var cash: Double { cashByItem.values.reduce(0, +) }
    var reportedValue: Double? {
        guard let accountBalances, !accountBalances.isEmpty,
              accountBalances.allSatisfy({ $0.value != nil }),
              cashByItem.keys.allSatisfy({ item in accountBalances.contains { $0.itemID == item } }),
              positions.allSatisfy({ position in accountBalances.contains { $0.itemID == position.itemID && position.id.hasPrefix($0.accountID + "|") } }) else { return nil }
        return accountBalances.compactMap(\.value).reduce(0, +)
    }
    var totalValue: Double { reportedValue ?? positions.compactMap(\.value).reduce(cash, +) }
    var totalGain: Double? {
        let gains = positions.compactMap(\.gain)
        return gains.isEmpty ? nil : gains.reduce(0, +)
    }

    func positions(for symbol: String) -> [Position] {
        positions.filter { $0.symbol == symbol.uppercased() }
    }
}

nonisolated struct PlaidClient: Sendable {
    let credentials: PlaidCredentials
    static let redirectURI = "https://bryce-newswire.bryce-e19.workers.dev/plaid/oauth"

    private struct Failure: Decodable {
        let errorCode: String
        let errorMessage: String
        let displayMessage: String?
    }

    func post<T: Decodable & Sendable>(_ path: String, _ body: [String: Any], as: T.Type) async throws -> T {
        guard credentials.isComplete else { throw PlaidError.credentials }
        var payload = body
        payload["client_id"] = credentials.clientID
        payload["secret"] = credentials.secret
        var request = URLRequest(url: credentials.environment.host.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if let failure = try? decoder.decode(Failure.self, from: data) {
                throw PlaidError.api(code: failure.errorCode, message: failure.displayMessage ?? failure.errorMessage)
            }
            throw PlaidError.api(code: "HTTP", message: "Plaid returned an unexpected response.")
        }
        return try decoder.decode(T.self, from: data)
    }

    struct LinkToken: Decodable, Sendable { let linkToken: String }
    struct Exchange: Decodable, Sendable { let accessToken: String; let itemId: String }
    struct Empty: Decodable, Sendable {}

    func linkToken(updating accessToken: String? = nil) async throws -> String {
        var body: [String: Any] = ["client_name": "Newswire",
                                   "user": ["client_user_id": "newswire-owner"],
                                   "country_codes": ["US"],
                                   "language": "en",
                                   "redirect_uri": Self.redirectURI]
        if let accessToken { body["access_token"] = accessToken } else { body["products"] = ["investments"] }
        return try await post("/link/token/create", body, as: LinkToken.self).linkToken
    }

    func exchange(_ publicToken: String) async throws -> Exchange {
        try await post("/item/public_token/exchange", ["public_token": publicToken], as: Exchange.self)
    }

    func remove(_ accessToken: String) async throws {
        _ = try await post("/item/remove", ["access_token": accessToken], as: Empty.self)
    }

    struct Transactions: Decodable, Sendable {
        struct Transaction: Codable, Sendable {
            let accountId: String
            let securityId: String?
            let type: String
            let quantity: Double
            let amount: Double
            let date: String
            var subtype: String?
            var name: String?
            var investmentTransactionId: String?
            var cancelTransactionId: String?
            var transactionDatetime: String?
            var isoCurrencyCode: String?
        }
        let investmentTransactions: [Transaction]
        let totalInvestmentTransactions: Int
        let securities: [HoldingsResponse.Security]?
    }

    func holdings(_ item: PlaidItem) async throws -> HoldingsResponse.Parsed {
        var parsed = try await post("/investments/holdings/get", ["access_token": item.accessToken], as: HoldingsResponse.self).positions(item: item)
        do {
            parsed.history = try await transactions(item)
        } catch { parsed.historyError = error.localizedDescription }
        guard let history = parsed.history?.transactions else { return parsed }
        parsed.positions = parsed.positions.map { position in
            guard position.reportedCost == nil else { return position }
            var position = position
            let key = position.id.split(separator: "|").map(String.init)
            let trades = history.filter { $0.accountId == key.first && $0.securityId == key.last }
            position.reportedCost = HoldingsResponse.estimatedCost(quantity: position.quantity, trades: trades)
            position.costEstimated = position.reportedCost != nil
            return position
        }
        return parsed
    }

    func transactions(_ item: PlaidItem) async throws -> InvestmentHistory {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .month, value: -24, to: end) ?? end
        let day = Date.ISO8601FormatStyle().year().month().day()
        var all: [Transactions.Transaction] = []
        var cashSecurityIDs = Set<String>()
        var securities: [String: HoldingsResponse.Security] = [:]
        while true {
            let page = try await post("/investments/transactions/get",
                                      ["access_token": item.accessToken, "start_date": start.formatted(day), "end_date": end.formatted(day),
                                       "options": ["count": 500, "offset": all.count]], as: Transactions.self)
            guard !page.investmentTransactions.isEmpty || all.count >= page.totalInvestmentTransactions else {
                throw PlaidError.api(code: "INCOMPLETE_HISTORY", message: "Plaid returned an incomplete transaction history. Try syncing again.")
            }
            cashSecurityIDs.formUnion((page.securities ?? []).filter { $0.type == "cash" && $0.tickerSymbol?.uppercased() == "USD" }.map(\.securityId))
            for security in page.securities ?? [] { securities[security.securityId] = security }
            all += page.investmentTransactions
            if all.count >= page.totalInvestmentTransactions { break }
            try Task.checkCancellation()
        }
        return InvestmentHistory(itemID: item.id, start: start, end: end, transactions: all, cashSecurityIDs: Array(cashSecurityIDs), securities: Array(securities.values), version: 1)
    }
}

nonisolated struct HoldingsResponse: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        struct Balances: Decodable, Sendable { let current: Double?; var isoCurrencyCode: String? }
        let accountId: String
        let name: String
        let mask: String?
        let balances: Balances?
        let type: String?
    }
    struct Holding: Decodable, Sendable {
        let accountId: String
        let securityId: String
        let quantity: Double
        let institutionPrice: Double?
        let institutionValue: Double?
        let costBasis: Double?
    }
    struct Contract: Codable, Sendable {
        let contractType: String
        let expirationDate: String
        let strikePrice: Double
        let underlyingSecurityTicker: String
    }
    struct Security: Codable, Sendable {
        let securityId: String
        let name: String?
        let tickerSymbol: String?
        let type: String?
        let optionContract: Contract?
        var isoCurrencyCode: String?
    }
    struct Parsed: Sendable {
        var positions: [Position]
        let cash: Double
        var accountBalances: [BrokerageBalance] = []
        var history: InvestmentHistory?
        var historyError: String?
    }

    let accounts: [Account]
    let holdings: [Holding]
    let securities: [Security]

    static func date(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func contracts(quantity: Double, price: Double?, value: Double?) -> Double {
        guard let price, let value, price != 0, quantity != 0 else { return quantity }
        let multiplier = abs(value / (quantity * price))
        return multiplier > 0.5 && multiplier < 2 ? quantity / 100 : quantity
    }

    static func estimatedCost(quantity: Double, trades: [PlaidClient.Transactions.Transaction]) -> Double? {
        guard quantity != 0 else { return nil }
        let trades = InvestmentActivity.active(trades)
        guard trades.allSatisfy({ $0.type != "cancel" && ($0.quantity == 0 || $0.type == "buy" || $0.type == "sell") }) else { return nil }
        let ordered = trades.enumerated()
            .filter { ($0.element.type == "buy" || $0.element.type == "sell") && $0.element.quantity != 0 }
            .sorted { ($0.element.date, -$0.offset) < ($1.element.date, -$1.offset) }
            .map(\.element)
        var lots: [(quantity: Double, unit: Double)] = []
        for trade in ordered {
            guard trade.quantity.isFinite, trade.amount.isFinite else { return nil }
            var size = (trade.type == "buy" ? 1.0 : -1.0) * abs(trade.quantity)
            let unit = abs(trade.amount / trade.quantity)
            while abs(size) > 1e-9, let first = lots.first, first.quantity * size < 0 {
                let used = min(abs(size), abs(first.quantity))
                lots[0].quantity += first.quantity > 0 ? -used : used
                size += size > 0 ? -used : used
                if abs(lots[0].quantity) <= 1e-9 { lots.removeFirst() }
            }
            if abs(size) > 1e-9 { lots.append((size, unit)) }
        }
        let open = lots.reduce(0) { $0 + $1.quantity }
        guard abs(open - quantity) <= max(1e-6, abs(quantity) * 1e-6) else { return nil }
        return lots.reduce(0) { $0 + $1.quantity * $1.unit }
    }

    func positions(item: PlaidItem) -> Parsed {
        let securities = Dictionary(securities.map { ($0.securityId, $0) }, uniquingKeysWith: { first, _ in first })
        let accounts = Dictionary(accounts.map { ($0.accountId, $0) }, uniquingKeysWith: { first, _ in first })
        var cash = 0.0
        var positions: [Position] = []
        for holding in holdings {
            if let type = accounts[holding.accountId]?.type, !["investment", "brokerage"].contains(type) { continue }
            guard let security = securities[holding.securityId] else { continue }
            if security.type == "cash" {
                cash += holding.institutionValue ?? holding.quantity
                continue
            }
            var option: OptionDetail?
            var symbol = security.tickerSymbol?.uppercased() ?? ""
            if let contract = security.optionContract, let expiration = Self.date(contract.expirationDate) {
                symbol = contract.underlyingSecurityTicker.uppercased()
                option = OptionDetail(isCall: contract.contractType.lowercased() == "call", strike: contract.strikePrice, expiration: expiration,
                                      contracts: Self.contracts(quantity: holding.quantity, price: holding.institutionPrice, value: holding.institutionValue))
            }
            guard !symbol.isEmpty else { continue }
            let account = accounts[holding.accountId]
            let accountName = account.map { account in account.mask.map { "\(account.name) ••\($0)" } ?? account.name } ?? "Account"
            positions.append(Position(id: "\(holding.accountId)|\(holding.securityId)",
                                      itemID: item.id,
                                      institution: item.institution,
                                      account: accountName,
                                      symbol: symbol,
                                      name: security.name,
                                      option: option,
                                      quantity: holding.quantity,
                                      price: holding.institutionPrice,
                                      value: holding.institutionValue,
                                      reportedCost: holding.costBasis))
        }
        let balances = self.accounts.filter { $0.type == nil || ["investment", "brokerage"].contains($0.type ?? "") }.map { account in
            let held = holdings.filter { $0.accountId == account.accountId }
            let complete = (account.balances?.isoCurrencyCode.map { $0 == "USD" } ?? true) && held.allSatisfy { holding in
                guard let security = securities[holding.securityId], holding.institutionValue != nil else { return false }
                return (security.isoCurrencyCode.map { $0 == "USD" } ?? true) &&
                    (security.type == "cash" || positions.contains { $0.id == "\(account.accountId)|\(holding.securityId)" })
            }
            return BrokerageBalance(accountID: account.accountId, itemID: item.id, institution: item.institution,
                             name: account.mask.map { "\(account.name) ••\($0)" } ?? account.name, value: account.balances?.current,
                             cashValue: held.filter { securities[$0.securityId]?.type == "cash" }.compactMap(\.institutionValue).reduce(0, +),
                             holdingsComplete: complete)
        }
        return Parsed(positions: positions, cash: cash, accountBalances: balances)
    }
}

@Observable final class PortfolioStore {
    static let shared = PortfolioStore()

    var credentials = PlaidCredentials.load()
    var items: [PlaidItem] = []
    var snapshot = PortfolioSnapshot()
    var syncing = false
    var linking = false
    var error: String?
    var itemErrors: [String: String] = [:]
    var needsRelink: Set<String> = []
    @ObservationIgnored private var handler: (any Handler)?

    private static let cacheURL = URL.applicationSupportDirectory.appending(path: "portfolio-v3.json")
    private static let overridesKey = "portfolioCostOverrides"
    private var overrides = UserDefaults.standard.dictionary(forKey: PortfolioStore.overridesKey) as? [String: Double] ?? [:]

    init() {
        items = Self.loadItems()
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode(PortfolioSnapshot.self, from: data) { snapshot = applyingOverrides(cached) }
    }

    private func applyingOverrides(_ snapshot: PortfolioSnapshot) -> PortfolioSnapshot {
        var snapshot = snapshot
        for index in snapshot.positions.indices {
            if snapshot.positions[index].costEstimated && snapshot.costMethodVersion != 2 {
                snapshot.positions[index].reportedCost = nil
                snapshot.positions[index].costEstimated = false
            }
            snapshot.positions[index].manualCost = overrides[snapshot.positions[index].id]
        }
        return snapshot
    }

    func setCost(_ position: Position, total: Double?) {
        overrides[position.id] = total
        UserDefaults.standard.set(overrides, forKey: Self.overridesKey)
        snapshot = applyingOverrides(snapshot)
        persistSnapshot()
    }

    var activeItems: [PlaidItem] { items.filter { $0.environment == credentials.environment } }
    var client: PlaidClient { PlaidClient(credentials: credentials) }

    private static func loadItems() -> [PlaidItem] {
        PlaidKeychain.data("items").flatMap { try? JSONDecoder().decode([PlaidItem].self, from: $0) } ?? []
    }

    private func persistItems() throws {
        try PlaidKeychain.set(items.isEmpty ? nil : JSONEncoder().encode(items), for: "items")
    }

    private func persistSnapshot() {
        do {
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: Self.cacheURL, options: [.atomic, .completeFileProtection])
        } catch {}
    }

    func reloadFromKeychain() {
        credentials = PlaidCredentials.load()
        items = Self.loadItems()
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode(PortfolioSnapshot.self, from: data) {
            snapshot = applyingOverrides(cached)
        }
    }

    func save(_ new: PlaidCredentials) throws {
        try new.save()
        credentials = new
    }

    func connect(updating item: PlaidItem? = nil) async {
        error = nil
        linking = true
        defer { linking = false }
        do {
            let token = try await client.linkToken(updating: item?.accessToken)
            var configuration = LinkTokenConfiguration(token: token) { [weak self] success in
                Task { @MainActor in await self?.linked(success, updating: item) }
            }
            configuration.onExit = { [weak self] exit in
                Task { @MainActor in
                    if let error = exit.error { self?.error = error.displayMessage ?? error.errorMessage }
                    self?.handler = nil
                }
            }
            switch Plaid.create(configuration) {
            case let .success(handler):
                guard let presenter = Self.presenter() else { throw PlaidError.noWindow }
                self.handler = handler
                handler.open(presentUsing: .viewController(presenter))
            case let .failure(failure):
                throw PlaidError.link(failure.localizedDescription)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resume(from url: URL) {
        handler?.resumeAfterTermination(from: url)
    }

    private func linked(_ success: LinkSuccess, updating existing: PlaidItem?) async {
        handler = nil
        if let existing {
            needsRelink.remove(existing.id)
            itemErrors[existing.id] = nil
            await sync()
            return
        }
        do {
            let exchange = try await client.exchange(success.publicToken)
            let item = PlaidItem(id: exchange.itemId, accessToken: exchange.accessToken,
                                 institution: success.metadata.institution.name, environment: credentials.environment)
            items.removeAll { $0.id == item.id }
            items.append(item)
            try persistItems()
            await sync()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func sync() async {
        guard credentials.isComplete, !activeItems.isEmpty, !syncing else { return }
        syncing = true
        defer { syncing = false }
        error = nil
        let client = client
        var positions: [Position] = []
        var cash: [String: Double] = [:]
        var balances: [BrokerageBalance] = []
        var histories: [InvestmentHistory] = []
        var failed = Set<String>()
        await withTaskGroup(of: (PlaidItem, Result<HoldingsResponse.Parsed, Error>).self) { group in
            for item in activeItems {
                group.addTask { (item, await Result { try await client.holdings(item) }) }
            }
            for await (item, result) in group {
                switch result {
                case let .success(parsed):
                    positions += parsed.positions
                    balances += parsed.accountBalances
                    if let history = parsed.history { histories.append(history) }
                    cash[item.id] = parsed.cash
                    itemErrors[item.id] = parsed.historyError.map { "Transaction history unavailable: " + $0 }
                    needsRelink.remove(item.id)
                case let .failure(failure):
                    failed.insert(item.id)
                    let code = (failure as? PlaidError)?.code
                    if code == "ITEM_LOGIN_REQUIRED" || code == "PENDING_EXPIRATION" || code == "PENDING_DISCONNECT" { needsRelink.insert(item.id) }
                    itemErrors[item.id] = code == "PRODUCT_NOT_READY"
                        ? "Plaid is still pulling holdings. Try again in a minute."
                        : failure.localizedDescription
                }
            }
        }
        let receivedHistory = Set(histories.map(\.itemID))
        histories += (snapshot.histories ?? []).filter { history in !receivedHistory.contains(history.itemID) && failed.contains(history.itemID) }
        balances += (snapshot.accountBalances ?? []).filter { failed.contains($0.itemID) }
        let kept = applyingOverrides(snapshot).positions.filter { failed.contains($0.itemID) }
        for id in failed { cash[id] = snapshot.cashByItem[id] }
        let sorted = (positions + kept).sorted {
            ($0.symbol, $0.option == nil ? 0 : 1, $0.option?.expiration ?? .distantPast, $0.option?.strike ?? 0)
                < ($1.symbol, $1.option == nil ? 0 : 1, $1.option?.expiration ?? .distantPast, $1.option?.strike ?? 0)
        }
        snapshot = applyingOverrides(PortfolioSnapshot(positions: sorted, cashByItem: cash,
                                                       updated: failed.count == activeItems.count ? snapshot.updated : .now, costMethodVersion: 2, accountBalances: balances, histories: histories))
        persistSnapshot()
        await PushDelegate.syncStockAlerts()
    }

    func remove(_ item: PlaidItem) async {
        let owner = PlaidClient(credentials: PlaidCredentials(clientID: credentials.clientID, secret: credentials.secret, environment: item.environment))
        try? await owner.remove(item.accessToken)
        items.removeAll { $0.id == item.id }
        do { try persistItems() } catch { self.error = error.localizedDescription }
        snapshot.positions.removeAll { $0.itemID == item.id }
        snapshot.cashByItem[item.id] = nil
        snapshot.accountBalances?.removeAll { $0.itemID == item.id }
        snapshot.histories?.removeAll { $0.itemID == item.id }
        persistSnapshot()
        await PushDelegate.syncStockAlerts()
    }

    private static func presenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
