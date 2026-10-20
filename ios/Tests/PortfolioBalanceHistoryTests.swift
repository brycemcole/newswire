import Foundation
import Testing
@testable import Newswire

struct PortfolioBalanceHistoryTests {
    private func date(_ day: String) -> Date { PortfolioLedger.day(day)! }
    private func balance(_ account: String = "a", item: String = "i", value: Double? = 100) -> BrokerageBalance {
        .init(accountID: account, itemID: item, institution: "Test", name: "Account", value: value)
    }
    private func snapshot(_ balances: [BrokerageBalance], _ samples: [PortfolioBalanceSample], end: Date? = nil) -> PortfolioSnapshot {
        PortfolioSnapshot(updated: end ?? date("2026-01-05"), accountBalances: balances, balanceHistory: samples)
    }

    @Test func oldCachesDecodeWithoutRecordedHistory() async throws {
        let old = Data(#"{"positions":[],"cashByItem":{}}"#.utf8)
        #expect(try JSONDecoder().decode(PortfolioSnapshot.self, from: old).balanceHistory == nil)
    }

    @Test func recordsAccountTotalsWithoutNeedingTradesOrOptionPrices() async throws {
        let first = PortfolioBalanceHistory.recording([balance(value: 2000)], at: date("2026-01-03"), previous: [])
        let samples = PortfolioBalanceHistory.recording([balance(value: 2400)], at: date("2026-01-05"), previous: first)
        var source = snapshot([balance(value: 2400)], samples)
        source.positions = [.init(id: "a|option", itemID: "i", institution: "Test", account: "Account", symbol: "TEST", name: nil,
            option: .init(isCall: true, strike: 100, expiration: date("2026-02-01"), contracts: 1), quantity: 100, price: 4, value: 400)]
        let points = await PortfolioBalanceHistory.points(snapshot: source, range: .week, at: date("2026-01-05"))
        #expect(points.map(\.value) == [2000, 2400])
        #expect(points.allSatisfy { $0.gain == nil && $0.rate == nil })
        #expect(points.map(\.date) == [date("2026-01-03"), date("2026-01-05")])
        let cached = try JSONDecoder().decode(PortfolioSnapshot.self, from: JSONEncoder().encode(source))
        #expect(await PortfolioBalanceHistory.points(snapshot: cached, range: .week, at: date("2026-01-05")) == points)
    }

    @MainActor @Test func performancePublishesRecordedValuesWithoutFabricatingReturns() async {
        let now = Date.now
        let samples = [-3600.0, 0].map { offset in
            PortfolioBalanceSample(date: now.addingTimeInterval(offset), balances: [.init(itemID: "i", accountID: "a", value: offset == 0 ? 2400 : 2000)])
        }
        let source = snapshot([balance(value: 2400)], samples, end: now)
        let performance = PortfolioPerformance(publishesWidgets: false)
        performance.range = .week
        await performance.refresh(source)
        #expect(performance.series[.week] == nil)
        #expect(performance.recorded[.week]?.map(\.value) == [2000, 2400])
        #expect(performance.errors[.week] != nil)
        var changed = source
        changed.balanceHistory = []
        await performance.refresh(changed)
        #expect(performance.recorded[.week]?.isEmpty == true)
    }

    @Test func partialSyncDoesNotPretendStaleAccountsWereRefreshed() async {
        let both = [balance(value: 100), balance("b", item: "other", value: 200)]
        let first = PortfolioBalanceHistory.recording(both, at: date("2026-01-03"), previous: [])
        let samples = PortfolioBalanceHistory.recording([balance(value: 110)], at: date("2026-01-04"), previous: first)
        let all = snapshot(both, samples)
        #expect(await PortfolioBalanceHistory.points(snapshot: all, range: .week, at: date("2026-01-05")).map(\.value) == [300])
        let selected = snapshot([balance(value: 110)], samples)
        #expect(await PortfolioBalanceHistory.points(snapshot: selected, range: .week, at: date("2026-01-05")).map(\.value) == [100, 110])
    }

    @Test func newlyLinkedAccountsDoNotCreateFakeHistoricalTotals() async {
        let first = PortfolioBalanceHistory.recording([balance()], at: date("2026-01-03"), previous: [])
        let current = [balance(), balance("b", value: 500)]
        let samples = PortfolioBalanceHistory.recording(current, at: date("2026-01-05"), previous: first)
        #expect(await PortfolioBalanceHistory.points(snapshot: snapshot(current, samples), range: .week, at: date("2026-01-05")).map(\.value) == [600])
    }

    @Test func accountIDsAreScopedToTheirBrokerageItem() async {
        let accounts = [balance(item: "one", value: 100), balance(item: "two", value: 200)]
        let samples = PortfolioBalanceHistory.recording(accounts, at: date("2026-01-03"), previous: [])
        #expect(await PortfolioBalanceHistory.points(snapshot: snapshot([accounts[1]], samples), range: .week, at: date("2026-01-05")).map(\.value) == [200])
    }

    @Test func keepsFirstAndLastActualSyncEachDay() async {
        let start = date("2026-01-03")
        var samples: [PortfolioBalanceSample] = []
        for hour in 10...12 {
            samples = PortfolioBalanceHistory.recording([balance(value: Double(hour))], at: start.addingTimeInterval(Double(hour) * 3600), previous: samples)
        }
        #expect(samples.map { $0.balances[0].value } == [10, 12])
        #expect(samples.map(\.date) == [start.addingTimeInterval(36000), start.addingTimeInterval(43200)])
        samples = PortfolioBalanceHistory.recording([balance(value: 13)], at: samples.last!.date, previous: samples)
        #expect(samples.map { $0.balances[0].value } == [10, 13])
    }

    @Test func ignoresInvalidValuesAndDoesNotAppendOnFailedSync() async {
        let first = PortfolioBalanceHistory.recording([balance()], at: date("2026-01-03"), previous: [])
        for balances in [[], [balance(value: nil)], [balance(value: .nan)], [balance(value: .infinity)], [balance(), balance()]] {
            let samples = PortfolioBalanceHistory.recording(balances, at: date("2026-01-04"), previous: first)
            #expect(samples.map(\.date) == first.map(\.date))
        }
    }

    @Test func rangeNeverBackfillsOrUsesFutureObservations() async {
        let samples = ["2025-12-01", "2026-01-03", "2026-01-05", "2026-01-06"].map { day in
            PortfolioBalanceSample(date: date(day), balances: [.init(itemID: "i", accountID: "a", value: 100)])
        }
        let points = await PortfolioBalanceHistory.points(snapshot: snapshot([balance()], samples), range: .week, at: date("2026-01-05"))
        #expect(points.map(\.date) == [date("2026-01-03"), date("2026-01-05")])
    }

    @Test func boundsStoredHistoryAndPrunesOldObservations() async {
        let end = date("2026-01-05")
        var samples = (0..<2100).map { index in
            PortfolioBalanceSample(date: end.addingTimeInterval(Double(index - 2200)), balances: [.init(itemID: "i", accountID: "a\(index)", value: 100)])
        }
        samples.append(.init(date: date("2023-01-01"), balances: [.init(itemID: "i", accountID: "old", value: 100)]))
        let result = PortfolioBalanceHistory.recording([balance()], at: end, previous: samples)
        #expect(result.count == 2048)
        #expect(result.allSatisfy { $0.date >= date("2024-01-05") })
        #expect(result.last?.date == end)
    }
}
