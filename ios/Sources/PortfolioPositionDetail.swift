import SwiftUI

struct PortfolioPositionDetail: View {
    let position: Position
    var store = PortfolioStore.shared

    private var current: Position {
        store.snapshot.positions.first { $0.id == position.id } ?? position
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.symbol).font(.headline).textSelection(.enabled)
                    if let name = current.name { Text(name).font(.subheadline).foregroundStyle(.secondary) }
                    Text(current.account).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                PositionCard(symbol: current.symbol, position: current, spot: nil, store: store, requestsOptionQuote: false)
                if store.snapshot.isStale(current.itemID) {
                    Text("Brokerage not refreshed · showing cached values").font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Brokerage position")
            } footer: {
                Text("Values are reported by your brokerage. Unrealized gain compares value with cost basis; it is not daily change. Plan-specific fund identifiers may not have public quotes or charts.")
            }
        }
        .navigationTitle("Position & cost")
        .navigationBarTitleDisplayMode(.inline)
    }
}
