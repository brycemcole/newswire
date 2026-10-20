import Foundation

nonisolated struct PortfolioBalanceSample: Codable, Sendable {
    struct Account: Hashable, Sendable {
        let itemID: String
        let accountID: String
    }
    struct Balance: Codable, Sendable {
        let itemID: String
        let accountID: String
        let value: Double
        var account: Account { Account(itemID: itemID, accountID: accountID) }
    }
    let date: Date
    var balances: [Balance]
}

nonisolated enum PortfolioBalanceHistory {
    private struct Bucket: Hashable {
        let day: Date
        let accounts: Set<PortfolioBalanceSample.Account>
    }

    static func recording(_ balances: [BrokerageBalance], at date: Date, previous: [PortfolioBalanceSample]) -> [PortfolioBalanceSample] {
        let values = balances.compactMap { balance -> PortfolioBalanceSample.Balance? in
            guard let value = balance.value, value.isFinite else { return nil }
            return .init(itemID: balance.itemID, accountID: balance.accountID, value: value)
        }
        guard !values.isEmpty, Set(values.map(\.account)).count == values.count else { return previous }
        let cutoff = PortfolioLedger.calendar.date(byAdding: .year, value: -2, to: date)!
        var samples = previous.filter { $0.date >= cutoff && $0.date <= date }
        let sample = PortfolioBalanceSample(date: date, balances: values)
        samples.removeAll { $0.date == date && Set($0.balances.map(\.account)) == Set(values.map(\.account)) }
        samples.append(sample)
        let buckets = Dictionary(grouping: samples) {
            Bucket(day: PortfolioLedger.calendar.startOfDay(for: $0.date), accounts: Set($0.balances.map(\.account)))
        }
        // Keep real first/last observations, not interpolated daily balances.
        return Array(buckets.values.flatMap { samples in
            let ordered = samples.sorted { $0.date < $1.date }
            return ordered.count > 1 ? [ordered.first!, ordered.last!] : ordered
        }.sorted { $0.date < $1.date }.suffix(2048))
    }

    @concurrent static func points(snapshot: PortfolioSnapshot, range: ChartRange, at date: Date = .now) async -> [PerformancePoint] {
        guard let balances = snapshot.accountBalances, !balances.isEmpty, let updated = snapshot.updated else { return [] }
        let accounts = Set(balances.map { PortfolioBalanceSample.Account(itemID: $0.itemID, accountID: $0.accountID) })
        guard accounts.count == balances.count else { return [] }
        let start = PortfolioLedger.start(for: range, at: date)
        let end = min(updated, date)
        var values: [Date: Double] = [:]
        for sample in snapshot.balanceHistory ?? [] where sample.date >= start && sample.date <= end {
            let matching = sample.balances.filter { accounts.contains($0.account) }
            guard matching.count == accounts.count, Set(matching.map(\.account)) == accounts,
                  matching.allSatisfy({ $0.value.isFinite }) else { continue }
            let total = matching.reduce(0) { $0 + $1.value }
            if total.isFinite { values[sample.date] = total }
        }
        return values.sorted { $0.key < $1.key }.enumerated().map { index, entry in
            PerformancePoint(id: index, date: entry.key, value: entry.value)
        }
    }
}
