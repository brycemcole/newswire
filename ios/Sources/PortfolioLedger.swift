import Foundation

nonisolated enum InvestmentActivity {
    static func active(_ records: [PlaidClient.Transactions.Transaction]) -> [PlaidClient.Transactions.Transaction] {
        let cancelled = Set(records.filter { $0.type == "cancel" }.compactMap(\.cancelTransactionId))
        var seen = Set<String>()
        return records.filter {
            if let id = $0.investmentTransactionId {
                guard !cancelled.contains(id), seen.insert(id).inserted else { return false }
            }
            return $0.type != "cancel" || $0.cancelTransactionId == nil
        }
    }
}

nonisolated enum PortfolioHistoryError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case let .unavailable(message) = self { message } else { nil } }
}

nonisolated struct PortfolioLedger: Sendable {
    struct Event: Sendable {
        let date: Date
        let symbol: String?
        let quantity: Double
        let cash: Double
        let flow: Double
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    static func day(_ value: String) -> Date? {
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func transactionDay(_ record: PlaidClient.Transactions.Transaction) -> Date? {
        guard let timestamp = record.transactionDatetime else { return day(record.date) }
        if timestamp.contains("T00:00:00") { return day(timestamp) }
        let formatter = ISO8601DateFormatter()
        if let parsed = formatter.date(from: timestamp) { return calendar.startOfDay(for: parsed) }
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let parsed = formatter.date(from: timestamp) { return calendar.startOfDay(for: parsed) }
        return nil
    }

    static func start(for range: ChartRange, at end: Date) -> Date {
        let day = calendar.startOfDay(for: end)
        switch range {
        case .day: return calendar.date(byAdding: .day, value: -1, to: day)!
        case .week: return calendar.date(byAdding: .day, value: -7, to: day)!
        case .month: return calendar.date(byAdding: .month, value: -1, to: day)!
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: day)!
        case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: day)!
        case .ytd: return calendar.date(from: DateComponents(year: calendar.component(.year, from: day), month: 1, day: 1))!.addingTimeInterval(-86400)
        default: return calendar.date(byAdding: .year, value: -1, to: day)!
        }
    }

    let start: Date
    let end: Date
    let value: Double
    let quantities: [String: Double]
    let cash: Double
    let events: [Event]
    // Account-specific gaps where exact history cannot be built; never silently dropped from a total.
    let limitations: [String]
    var limitation: String? { limitations.isEmpty ? nil : limitations.joined(separator: " ") }
    var symbols: Set<String> { Set(quantities.keys).union(events.compactMap(\.symbol)) }

    init(snapshot: PortfolioSnapshot, start: Date) throws {
        func fail(_ message: String) throws -> Never { throw PortfolioHistoryError.unavailable(message) }
        guard snapshot.failedItemIDs?.isEmpty != false else {
            try fail("Some brokerages did not refresh. Sync all selected accounts before calculating performance.")
        }
        guard let updated = snapshot.updated, let balances = snapshot.accountBalances, !balances.isEmpty,
              let value = snapshot.reportedValue, value.isFinite else {
            try fail("Sync brokerage balances and transaction history to calculate performance.")
        }
        self.start = Self.calendar.startOfDay(for: start)
        self.end = Self.calendar.startOfDay(for: updated)
        self.value = value
        guard end > self.start else { try fail("Sync a newer brokerage balance for this range.") }
        var quantities: [String: Double] = [:]
        var cash = 0.0
        var events: [Event] = []
        var limitations: [String] = []
        for balance in balances {
            let account = "\(balance.institution) \(balance.name)"
            func limit(_ message: String) {
                let note = "\(account): \(message)"
                if !limitations.contains(note) { limitations.append(note) }
            }
            guard balance.holdingsComplete == true, let balanceValue = balance.value, balanceValue.isFinite,
                  let accountCash = balance.cashValue, accountCash.isFinite else {
                try fail("Sync complete holdings and cash balances to calculate performance.")
            }
            let positions = snapshot.positions.filter { $0.itemID == balance.itemID && $0.id.hasPrefix(balance.accountID + "|") }
            guard positions.allSatisfy({ $0.value?.isFinite == true && $0.quantity.isFinite }) else {
                try fail("Position values are missing for this account. Sync again.")
            }
            let holdingValue = positions.compactMap(\.value).reduce(0, +)
            guard abs(balanceValue - holdingValue - accountCash) < max(1, abs(balanceValue) * 0.001) else {
                try fail("Brokerage holdings and cash do not reconcile with the account balance. Sync again.")
            }
            cash += balanceValue - holdingValue
            guard let history = snapshot.histories?.first(where: { $0.itemID == balance.itemID }), history.version == 1,
                  Self.calendar.startOfDay(for: history.start) <= self.start,
                  Self.calendar.startOfDay(for: history.end) >= end, updated.timeIntervalSince(history.end) < 300 else {
                try fail("Transaction history does not cover this range. Sync again or choose a shorter range.")
            }
            let securities = Dictionary((history.securities ?? []).map { ($0.securityId, $0) }, uniquingKeysWith: { _, last in last })
            let cashIDs = Set(history.cashSecurityIDs ?? []).union(securities.values.filter { $0.type == "cash" }.map(\.securityId))
            // Cash-unit quantities (for example USD amounts on a dividend) are not share movements.
            func movesShares(_ record: PlaidClient.Transactions.Transaction) -> Bool {
                guard let id = record.securityId, record.quantity != 0 else { return false }
                return !cashIDs.contains(id)
            }
            var symbolsByID: [String: String] = [:]
            for position in positions {
                if position.option != nil {
                    limit("options have no historical price source here, so exact history is unavailable for \(position.symbol) options.")
                    continue
                }
                let id = String(position.id.dropFirst(balance.accountID.count + 1))
                symbolsByID[id] = position.symbol
                quantities[position.symbol, default: 0] += position.quantity
            }
            for record in InvestmentActivity.active(history.transactions) where record.accountId == balance.accountID {
                // Posting dates are the fallback; date-only order timestamps must not be treated as midnight trades.
                guard let date = Self.transactionDay(record) else { try fail("A transaction has an invalid date.") }
                guard date > self.start, date <= end else { continue }
                guard record.amount.isFinite, record.quantity.isFinite,
                      record.isoCurrencyCode.map({ $0 == "USD" }) ?? true else { try fail("A transaction has an unsupported currency or amount.") }
                let single = InvestmentHistory(itemID: history.itemID, start: history.start, end: history.end,
                                               transactions: [record], cashSecurityIDs: Array(cashIDs))
                let flows = InvestmentCashFlows(history: single, accountID: balance.accountID, institution: balance.institution)
                guard flows.unknown == 0 else { try fail("A transfer needs review before performance can be calculated.") }
                let flow = flows.contributed - flows.withdrawn
                let subtype = record.subtype?.lowercased() ?? ""
                var symbol: String?
                var quantity = 0.0
                var cashChange = -record.amount
                switch record.type {
                case "buy", "sell":
                    guard let id = record.securityId else { try fail("A trade is missing its security.") }
                    if cashIDs.contains(id) {
                        guard record.quantity != 0,
                              abs(abs(record.quantity) - abs(record.amount)) < 1e-6,
                              record.type == "buy" ? record.amount >= 0 : record.amount <= 0,
                              securities[id]?.isoCurrencyCode.map({ $0 == "USD" }) ?? true else {
                            limit("a cash-equivalent trade needs its unit value reconciled before exact history can be calculated.")
                            continue
                        }
                        // Sweeps move dollars between cash compartments already included in account cash.
                        events.append(Event(date: date, symbol: nil, quantity: 0, cash: flow, flow: flow))
                        continue
                    }
                    if let security = securities[id] {
                        if security.optionContract != nil {
                            limit("option trades have no historical price source, so exact history is unavailable.")
                            continue
                        }
                        guard ["equity", "etf", "mutual fund"].contains(security.type ?? ""), security.isoCurrencyCode.map({ $0 == "USD" }) ?? true else {
                            limit("\(security.name ?? "a traded security") is not an equity, ETF or mutual fund with a USD price, so exact history is unavailable.")
                            continue
                        }
                        symbol = security.tickerSymbol?.uppercased()
                    }
                    symbol = symbol ?? symbolsByID[id]
                    guard let traded = symbol else {
                        limit("a traded security has no exchange ticker, so exact history is unavailable for it.")
                        continue
                    }
                    guard record.quantity != 0, record.type == "buy" ? record.amount >= 0 : record.amount <= 0 else {
                        try fail("A trade is missing security details or has an inconsistent amount.")
                    }
                    symbol = traded
                    quantity = (record.type == "buy" ? 1 : -1) * abs(record.quantity)
                    if subtype == "contribution" || subtype == "distribution" {
                        cashChange = 0
                    }
                case "cash":
                    let supported = ["deposit", "contribution", "withdrawal", "distribution", "dividend", "interest", "qualified dividend", "non-qualified dividend", "long-term capital gain", "short-term capital gain", "return of principal", "tax", "tax withheld", "margin expense", "account fee", "legal fee", "management fee", "miscellaneous fee", "non-resident tax", "transfer fee", "trust fee", "unqualified gain"]
                    guard supported.contains(subtype) else { limit("a \(subtype.isEmpty ? "cash" : subtype) activity needs review before exact history can be calculated."); continue }
                    if movesShares(record) {
                        limit("a \(subtype) activity moves a security whose type is not known to be cash, so it needs review before exact history can be calculated.")
                        continue
                    }
                case "fee":
                    if movesShares(record) {
                        limit("a fee moves a security whose type is not known to be cash, so it needs review before exact history can be calculated.")
                        continue
                    }
                case "transfer":
                    guard flow != 0 else { limit("a security transfer or corporate action needs review."); continue }
                default: limit("an unsupported or cancelled transaction needs review."); continue
                }
                events.append(Event(date: date, symbol: symbol, quantity: quantity, cash: cashChange, flow: flow))
            }
        }
        self.quantities = quantities
        self.cash = cash
        self.events = events.sorted { $0.date < $1.date }
        self.limitations = limitations
    }

    func build(prices: [String: [HistoryPoint]]) throws -> PerformanceSeries {
        if let limitation { throw PortfolioHistoryError.unavailable(limitation) }
        var days = Set([start, end])
        days.formUnion(events.map(\.date))
        for track in prices.values { days.formUnion(track.map { Self.calendar.startOfDay(for: $0.date) }.filter { $0 >= start && $0 <= end }) }
        let tracks = prices.mapValues { $0.sorted { $0.date < $1.date } }
        var quantities = quantities
        var cash = cash
        var cursor = events.count
        var values: [(Date, Double)] = []
        for day in days.sorted(by: >) {
            while cursor > 0, events[cursor - 1].date > day {
                cursor -= 1
                let event = events[cursor]
                cash -= event.cash
                if let symbol = event.symbol { quantities[symbol, default: 0] -= event.quantity }
            }
            var total = cash
            for (symbol, quantity) in quantities where abs(quantity) > 1e-8 {
                guard let price = tracks[symbol]?.last(where: { Self.calendar.startOfDay(for: $0.date) <= day }),
                      day.timeIntervalSince(Self.calendar.startOfDay(for: price.date)) < 7 * 86400,
                      price.close.isFinite, price.close > 0 else {
                    throw PortfolioHistoryError.unavailable("Missing historical prices for \(symbol). Performance is unavailable for this range.")
                }
                total += quantity * price.close
            }
            guard total.isFinite else { throw PortfolioHistoryError.unavailable("Account history could not be reconciled.") }
            values.append((day, day == end ? value : total))
        }
        values.reverse()
        let baseline = values[0].1
        let points = values.enumerated().map { index, entry in
            let (date, value) = entry
            let flows = events.filter { $0.date <= date }
            let net = flows.reduce(0) { $0 + $1.flow }
            let duration = date.timeIntervalSince(start)
            // Modified Dietz weights external flows by time invested, using end-of-day flows.
            let capital = baseline + flows.reduce(0) { sum, event in
                sum + (duration > 0 ? date.timeIntervalSince(event.date) / duration : 0) * event.flow
            }
            let gain = value - baseline - net
            return PerformancePoint(id: index, date: date, value: value, gain: gain, rate: capital > 1e-8 ? gain / capital : nil)
        }
        return PerformanceSeries(points: points, baseline: baseline, transactionBased: true)
    }
}
