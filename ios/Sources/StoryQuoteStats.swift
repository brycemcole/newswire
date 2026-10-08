import SwiftUI

struct StoryQuoteStats: View {
    let symbols: [String]
    let quotes: [String: Quote]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(symbols, id: \.self) { symbol in group(symbol) }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(symbols, id: \.self) { symbol in group(symbol) }
            }
        }
        .padding(.top, 3)
    }

    private func group(_ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(symbol).fontWeight(.semibold).foregroundStyle(.primary)
                if let quote = quotes[symbol] {
                    Text(QuoteFormat.percent(quote.changePercent)).foregroundStyle(QuoteFormat.color(quote.changePercent))
                    Text("day").foregroundStyle(.secondary)
                }
            }
            .font(.caption.monospaced()).monospacedDigit()
            if let extended = quotes[symbol]?.extended {
                HStack(spacing: 6) {
                    Text(extended.session == "pre" ? "Pre-market" : "After hours").foregroundStyle(.secondary)
                    Text(QuoteFormat.percent(extended.changePercent)).foregroundStyle(QuoteFormat.color(extended.changePercent))
                }
                .font(.caption2).monospacedDigit()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}
