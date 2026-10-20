import Foundation
import Testing
@testable import Newswire

struct PortfolioSyncFreshnessTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var t1: Date { t0.addingTimeInterval(3600) }
    private var t2: Date { t0.addingTimeInterval(7200) }

    private func position(_ item: String, _ symbol: String, value: Double) -> Position {
        Position(id: "acct|\(item)-\(symbol)", itemID: item, institution: item.uppercased(), account: "Brokerage", symbol: symbol,
                 name: nil, option: nil, quantity: 1, price: value, value: value)
    }

    private func parsed(_ item: String, _ symbol: String, value: Double) -> HoldingsResponse.Parsed {
        HoldingsResponse.Parsed(positions: [position(item, symbol, value: value)], cash: 0)
    }

    private func history(_ item: String) -> InvestmentHistory {
        InvestmentHistory(itemID: item, start: t0, end: t0, transactions: [])
    }

    private var previous: PortfolioSnapshot {
        PortfolioSnapshot(positions: [position("a", "AAA", value: 100), position("b", "BBB", value: 200)],
                          cashByItem: ["a": 0, "b": 0], updated: t0, costMethodVersion: 2,
                          histories: [history("a"), history("b")],
                          itemSyncedAt: ["a": t0, "b": t0], failedItemIDs: [])
    }

    @Test func partialFailureKeepsFailedItemValueAndAge() {
        let merged = PortfolioSnapshot.merging(previous, outcomes: ["a": .synced(parsed("a", "AAA", value: 150)), "b": .failed], syncedAt: t1)
        #expect(merged.positions.first { $0.itemID == "a" }?.value == 150)
        #expect(merged.positions.first { $0.itemID == "b" }?.value == 200)
        #expect(merged.syncedAt(item: "a") == t1)
        #expect(merged.syncedAt(item: "b") == t0)
        #expect(merged.failedItemIDs == ["b"])
        #expect(merged.isStale("b") && !merged.isStale("a"))
        #expect(merged.aggregateSyncedAt == t0)
    }

    @Test func allFailureDoesNotManufactureFreshness() {
        let merged = PortfolioSnapshot.merging(previous, outcomes: ["a": .failed, "b": .failed], syncedAt: t1)
        #expect(merged.updated == t0)
        #expect(merged.itemSyncedAt == ["a": t0, "b": t0])
        #expect(merged.failedItemIDs == ["a", "b"])
        #expect(merged.positions.compactMap(\.value).reduce(0, +) == 300)
        #expect(merged.aggregateSyncedAt == t0)
    }

    @Test func recoveryClearsWarningAndAdvancesAges() {
        let partial = PortfolioSnapshot.merging(previous, outcomes: ["a": .synced(parsed("a", "AAA", value: 150)), "b": .failed], syncedAt: t1)
        let recovered = PortfolioSnapshot.merging(partial, outcomes: ["a": .synced(parsed("a", "AAA", value: 151)), "b": .synced(parsed("b", "BBB", value: 210))], syncedAt: t2)
        #expect(recovered.failedItemIDs == [])
        #expect(!recovered.isStale("a") && !recovered.isStale("b"))
        #expect(recovered.aggregateSyncedAt == t2)
        #expect(recovered.updated == t2)
        #expect(recovered.positions.first { $0.itemID == "b" }?.value == 210)
    }

    @Test func newlyLinkedFailedItemIsUnknownAndBlocksFreshAggregate() {
        let base = PortfolioSnapshot(positions: [position("a", "AAA", value: 100)], cashByItem: ["a": 0], updated: t0,
                                     costMethodVersion: 2, itemSyncedAt: ["a": t0])
        let merged = PortfolioSnapshot.merging(base, outcomes: ["a": .synced(parsed("a", "AAA", value: 110)), "b": .failed], syncedAt: t1)
        #expect(merged.failedItemIDs == ["b"])
        #expect(merged.syncedAt(item: "b") == nil)
        #expect(merged.isStale("b"))
        #expect(merged.itemSyncedAt?.keys.sorted() == ["a"])
        #expect(merged.aggregateSyncedAt == nil)
    }

    @Test func timestampsArePrunedToActiveOutcomes() {
        var stale = previous
        stale.itemSyncedAt?["gone"] = t0
        let merged = PortfolioSnapshot.merging(stale, outcomes: ["a": .synced(parsed("a", "AAA", value: 150))], syncedAt: t1)
        #expect(merged.itemSyncedAt == ["a": t1])
    }

    @Test func legacySnapshotDecodesWithUnknownItemFreshness() throws {
        let legacy = Data("""
        {"positions":[],"cashByItem":{"a":0},"updated":1800000000,"costMethodVersion":2,
         "accountBalances":[{"accountID":"x","itemID":"a","institution":"A","name":"Brokerage","value":10,"cashValue":0,"holdingsComplete":true,"cashMethodVersion":1}]}
        """.utf8)
        let snapshot = try JSONDecoder().decode(PortfolioSnapshot.self, from: legacy)
        #expect(snapshot.itemSyncedAt == nil && snapshot.failedItemIDs == nil)
        #expect(snapshot.syncedAt(item: "a") == nil)
        #expect(snapshot.isStale("a"))
        #expect(snapshot.aggregateSyncedAt == nil)
        #expect(snapshot.updated != nil)

        let encoded = try JSONEncoder().encode(PortfolioSnapshot.merging(snapshot, outcomes: ["a": .synced(parsed("a", "AAA", value: 5))], syncedAt: t1))
        let roundTrip = try JSONDecoder().decode(PortfolioSnapshot.self, from: encoded)
        #expect(roundTrip.syncedAt(item: "a") == t1)
        #expect(roundTrip.failedItemIDs == [])
    }

    @Test func selectedAccountScopeCarriesOnlyItsFreshness() {
        let merged = PortfolioSnapshot.merging(previous, outcomes: ["a": .synced(parsed("a", "AAA", value: 150)), "b": .failed], syncedAt: t1)
        let failedScope = merged.itemScope("b")
        #expect(failedScope.updated == t0)
        #expect(failedScope.itemSyncedAt == ["b": t0])
        #expect(failedScope.failedItemIDs == ["b"])
        #expect(failedScope.isStale("b"))
        #expect(failedScope.aggregateSyncedAt == t0)
        #expect(failedScope.histories?.map(\.itemID) == ["b"])
        #expect(failedScope.positions.map(\.itemID) == ["b"])

        let freshScope = merged.itemScope("a")
        #expect(freshScope.updated == t1)
        #expect(freshScope.failedItemIDs == [])
        #expect(!freshScope.isStale("a"))
        #expect(freshScope.histories?.isEmpty == true)
        #expect(merged.syncedAt(item: "missing") == nil)
    }

    @Test func unscopedSnapshotKeepsMixedTimesVisible() {
        let merged = PortfolioSnapshot.merging(previous, outcomes: ["a": .synced(parsed("a", "AAA", value: 150)), "b": .failed], syncedAt: t1)
        #expect(Set(merged.itemSyncedAt?.values.map { $0 } ?? []).count == 2)
    }
}
