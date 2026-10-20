import Foundation
import Testing
@testable import Newswire

@MainActor
private final class PulseFeedStub {
    var now: Date
    var replies: [Result<MarketPulse, Error>] = []

    init(now: Date) { self.now = now }

    func next() throws -> MarketPulse { try replies.removeFirst().get() }
}

@MainActor
struct PulseFreshnessTests {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func pulse(asOf: String, horizon: String? = "next open") throws -> MarketPulse {
        let horizonField = horizon.map { #""horizon":"\#($0)","# } ?? ""
        let json = #"{"symbol":"SPY","status":"available","confidence":"medium","as_of":"\#(asOf)","#
            + horizonField
            + #""components":{"news":{"status":"available","points":0}},"factors":[],"coverage":{"headline_stories":1,"matched_stories":0},"call":{"headline":"Expect a lower open","tone":"negative","strength":1}}"#
        return try NewswireAPI.decoder().decode(MarketPulse.self, from: Data(json.utf8))
    }

    @Test func failedRefreshKeepsOldSnapshotAndRecoveryClearsFailure() async throws {
        let feed = PulseFeedStub(now: date("2026-10-19T14:00:00Z"))
        let store = PulseStore(fetch: { _ in try feed.next() }, clock: { feed.now })
        store.symbol = "SPY"

        feed.replies = [.success(try pulse(asOf: "2026-10-16T20:00:00Z"))]
        await store.refresh()
        #expect(store.current != nil && !store.failed)
        let firstFetch = store.fetchedAt("SPY")

        feed.now = feed.now.addingTimeInterval(120)
        feed.replies = [.failure(URLError(.timedOut))]
        await store.refresh()
        #expect(store.current != nil)
        #expect(store.failed)
        #expect(store.fetchedAt("SPY") == firstFetch)

        feed.now = feed.now.addingTimeInterval(120)
        feed.replies = [.success(try pulse(asOf: "2026-10-19T14:00:00Z", horizon: "rest of session"))]
        await store.refresh()
        #expect(!store.failed)
        #expect(store.fetchedAt("SPY") == feed.now)
    }

    @Test func nextOpenHorizonExpiresAtTheOpen() throws {
        let value = try pulse(asOf: "2026-10-16T20:00:00Z")
        #expect(value.horizonEnd == date("2026-10-19T13:30:00Z"))
        #expect(value.validity(at: date("2026-10-19T13:29:00Z")) == .current)
        #expect(value.validity(at: date("2026-10-19T13:31:00Z")) == .expired)
    }

    @Test func restOfSessionHorizonExpiresAtTheClose() throws {
        let value = try pulse(asOf: "2026-10-19T14:00:00Z", horizon: "rest of session")
        #expect(value.horizonEnd == date("2026-10-19T20:00:00Z"))
        #expect(value.validity(at: date("2026-10-19T19:00:00Z")) == .current)
        #expect(value.validity(at: date("2026-10-19T20:30:00Z")) == .expired)
    }

    @Test func unnamedHorizonIsNotPresentedAsCurrent() throws {
        let value = try pulse(asOf: "2026-10-19T14:00:00Z", horizon: nil)
        #expect(value.horizonEnd == nil)
        #expect(value.validity(at: date("2026-10-19T14:05:00Z")) == .unknown)
    }

    @Test func pastHorizonOutlookSurvivesFailedRefreshAsExpired() async throws {
        let feed = PulseFeedStub(now: date("2026-10-16T21:00:00Z"))
        let store = PulseStore(fetch: { _ in try feed.next() }, clock: { feed.now })
        store.symbol = "SPY"

        feed.replies = [.success(try pulse(asOf: "2026-10-16T20:00:00Z"))]
        await store.refresh()

        feed.now = date("2026-10-19T14:00:00Z")
        feed.replies = [.failure(URLError(.notConnectedToInternet))]
        await store.refresh()
        #expect(store.failed)
        #expect(store.current?.validity(at: feed.now) == .expired)
    }

    @Test func unnamedHorizonNoteIsCachedAndUnverified() throws {
        let value = try pulse(asOf: "2026-10-19T14:00:00Z", horizon: nil)
        let note = value.outlookNote(at: date("2026-10-19T14:05:00Z"), refreshFailed: false, fetchedAt: nil)
        #expect(note.standing == .cached && !note.refreshFailed)
        #expect(note.text.contains("unverified") && note.text.contains("Computed"))
    }

    @Test func expiredNoteStaysExpiredWhenRefreshFails() throws {
        let value = try pulse(asOf: "2026-10-16T20:00:00Z")
        let note = value.outlookNote(at: date("2026-10-19T15:00:00Z"), refreshFailed: true, fetchedAt: date("2026-10-19T14:00:00Z"))
        #expect(note.standing == .expired && note.refreshFailed)
        #expect(note.text.contains("has passed") && note.text.contains("Refresh failed"))
    }

    @Test func longNextOpenHorizonStillShowsComputedAge() throws {
        let value = try pulse(asOf: "2026-10-19T14:00:00Z")
        let note = value.outlookNote(at: date("2026-10-19T14:05:00Z"), refreshFailed: false, fetchedAt: nil)
        #expect(note.standing == .current)
        #expect(note.text.contains("Valid until") && note.text.contains("Computed"))
    }
}
