#if DEBUG
import SwiftUI

struct NumericTextPreview: View {
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduced
    private let prices = [199.98, 200.01, 198.76, 199.98]
    private let changes = [-0.01, 0.01, -0.62, 0.0]

    private var quote: MarketQuote? {
        MarketQuote(.object([
            "symbol": .string("AAPL"), "longName": .string("Apple Inc."),
            "currency": .string("USD"), "marketState": .string("REGULAR"),
            "regularMarketPrice": .number(prices[step]),
            "regularMarketChangePercent": .number(changes[step])
        ]))
    }

    var body: some View {
        NavigationStack {
            List {
                if !CommandLine.arguments.contains("-numericPortfolioOnly") {
                Section("Quote updates · synthetic data") {
                    MarketRow(symbol: "AAPL", title: "Apple Inc.", tag: nil, quote: quote, spark: nil, inset: 0)
                    CompactWatchlistQuote(symbol: "AAPL", quote: quote)
                    IndexCard(symbol: "AAPL", quote: quote, spark: nil)
                }
                }
                Section("Portfolio value") {
                    PortfolioOverview(snapshot: PortfolioSnapshot(cashByItem: ["preview": 124_580.32 + prices[step] - prices[0]], updated: .now))
                }
                Section("Home ticker") {
                    PortfolioTicker(items: [
                        .init(id: "portfolio", title: Money.text(124_580.32 + prices[step] - prices[0]),
                              change: QuoteFormat.percent(changes[step]), tint: QuoteFormat.color(changes[step]), action: {})
                    ])
                }
                Section {
                    Text(reduced ? "Reduce Motion is on" : "Reduce Motion is off")
                    Button("Update numbers") { step = (step + 1) % prices.count }
                }
            }
            .navigationTitle("Number transitions")
            .task {
                guard CommandLine.arguments.contains("-numericAutoUpdate") else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    step = (step + 1) % prices.count
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}
#endif
