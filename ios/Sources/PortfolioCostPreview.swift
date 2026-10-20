#if DEBUG
import SwiftUI

struct PortfolioCostPreview: View {
    @State private var store: PortfolioStore

    init() {
        let suite = "Newswire.syntheticCostPreview"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = PortfolioStore(defaults: defaults, cacheURL: FileManager.default.temporaryDirectory.appending(path: "synthetic-cost-preview.json"))
        let symbols = ["SP.500.INDEX.PL.CL.D", "SP.INTL.INDEX.D", "SP.SMALL.CP.IND.CL.D"]
        let positions = symbols.enumerated().map { index, symbol in
            Position(id: "plan|fund-\(index)", itemID: "synthetic", institution: "Fidelity", account: "Synthetic retirement plan", symbol: symbol,
                name: "[TEST] Plan fund \(index + 1)", option: nil, quantity: 10, price: 120, value: 1200,
                reportedCost: index == 1 ? 0 : nil)
        }
        store.snapshot = PortfolioSnapshot(positions: positions, updated: .now, costMethodVersion: 2, itemSyncedAt: ["synthetic": .now], failedItemIDs: [])
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(PortfolioHolding.group(store.snapshot.positions, search: "", sort: .symbol)) { holding in
                        PortfolioHoldingRow(holding: holding, store: store)
                    }
                } footer: { Text("Synthetic fixtures · no brokerage or quote requests") }
            }
            .navigationTitle("Holdings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
