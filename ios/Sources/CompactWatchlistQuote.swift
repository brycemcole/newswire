import SwiftUI

struct CompactWatchlistQuote: View {
    let symbol: String
    let quote: MarketQuote?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(quote?.name ?? OptionSymbol.display(symbol)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(OptionSymbol.display(symbol)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(quote.map { QuoteFormat.price($0.price) } ?? "—").font(.caption.weight(.semibold))
                Text(quote.map { QuoteFormat.percent($0.changePercent) } ?? " ")
                    .font(.caption2.weight(.semibold)).foregroundStyle(QuoteFormat.color(quote?.changePercent ?? 0))
            }
            .monospacedDigit().lineLimit(1).contentTransition(.numericText())
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
