import Foundation
import Testing
@testable import Newswire

@MainActor struct PortfolioAssistantTests {
    private let synced = Date(timeIntervalSince1970: 1_800_000_000)

    private func store(failed: Bool, relink: Bool = false) -> PortfolioStore {
        let suite = UserDefaults(suiteName: "PortfolioAssistantTests-\(UUID().uuidString)")!
        let store = PortfolioStore(defaults: suite, cacheURL: URL.temporaryDirectory.appending(path: "assistant-\(UUID().uuidString).json"))
        store.credentials = PlaidCredentials(clientID: "id", secret: "secret", environment: .sandbox)
        store.items = [PlaidItem(id: "fid-item-1", accessToken: "token", institution: "Fidelity", environment: .sandbox),
                       PlaidItem(id: "sofi-item-1", accessToken: "token", institution: "SoFi", environment: .sandbox)]
        let nvda = Position(id: "a|nvda", itemID: "fid-item-1", institution: "Fidelity", account: "Individual", symbol: "NVDA", name: nil, option: nil,
                            quantity: 203, price: 180, value: 266)
        let sofi = Position(id: "b|sofi", itemID: "sofi-item-1", institution: "SoFi", account: "Invest", symbol: "SOFI", name: nil, option: nil,
                            quantity: 10, price: 20, value: 200)
        store.snapshot = PortfolioSnapshot(positions: [nvda, sofi], cashByItem: ["fid-item-1": 0, "sofi-item-1": 0], updated: synced, costMethodVersion: 2,
                                           itemSyncedAt: ["fid-item-1": synced, "sofi-item-1": synced], failedItemIDs: failed ? ["fid-item-1"] : [])
        if relink { store.needsRelink.insert("fid-item-1") }
        return store
    }

    @Test func statusNamesFailedBrokerageAndRelink() {
        let text = PortfolioAssistant.status(store: store(failed: true, relink: true))
        #expect(text.contains("Fidelity (link fid-item"))
        #expect(text.contains("LATEST REFRESH FAILED"))
        #expect(text.contains("Needs sign-in again"))
        #expect(text.contains("SoFi (link sofi-ite"))
        #expect(!text.contains("SoFi (link sofi-ite): LATEST"))
    }

    @Test func positionsShowExactQuantityAndFlagValueMismatchAndStaleBrokerage() {
        let text = PortfolioAssistant.positions(symbol: "nvda", institution: "", store: store(failed: true))
        #expect(text.contains("quantity 203"))
        #expect(text.contains("CHECK: quantity × price"))
        #expect(text.contains("STALE"))
        #expect(!text.contains("SOFI"))
    }

    @Test func positionsReportNoMatchInsteadOfInventingOne() {
        #expect(PortfolioAssistant.positions(symbol: "AFRM", institution: "", store: store(failed: false)).hasPrefix("No held position matches"))
    }

    @Test func refreshWithoutKeysExplainsInsteadOfClaimingSuccess() async {
        let store = store(failed: false)
        store.credentials = PlaidCredentials(clientID: "", secret: "", environment: .sandbox)
        let text = await PortfolioAssistant.refresh(progress: { _ in }, store: store)
        #expect(text.hasPrefix("Cannot refresh"))
    }

    @Test func removeNeedsAnUnambiguousBrokerageBeforeAsking() async {
        let text = await PortfolioAssistant.remove(institution: "Schwab", store: store(failed: false))
        #expect(text.contains("No linked brokerage matches"))
        #expect(ChatApproval.shared.pending == nil)
    }

    @Test func declinedApprovalLeavesBrokerageLinked() async {
        let store = store(failed: false)
        async let result = PortfolioAssistant.remove(institution: "Fidelity", store: store)
        for _ in 0..<50 where ChatApproval.shared.pending == nil { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(ChatApproval.shared.pending?.destructive == true)
        ChatApproval.shared.resolve(false)
        #expect(await result.contains("declined"))
        #expect(store.items.count == 2)
    }

    @Test func toolDefinitionsMatchToolNames() {
        let names = PortfolioAssistant.definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names == PortfolioAssistant.toolNames)
    }
}
