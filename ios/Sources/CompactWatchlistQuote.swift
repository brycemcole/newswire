import SwiftUI

struct CompactWatchlistQuote: View {
    let symbol: String
    let quote: MarketQuote?
    var now: Date = .now
    @State private var board = MarketBoard.shared

    var body: some View {
        let notice = board.freshness(of: symbol, now: now)?.notice
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(quote?.name ?? OptionSymbol.display(symbol)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(OptionSymbol.display(symbol)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if let notice {
                    Label(notice.text, systemImage: notice.symbol).font(.caption2).foregroundStyle(notice.tint).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(quote.map { QuoteFormat.price($0.price) } ?? "—").font(.caption.weight(.semibold))
                    .numericTextTransition(value: quote?.price)
                Text(quote.map { QuoteFormat.percent($0.changePercent) } ?? " ")
                    .font(.caption2.weight(.semibold)).foregroundStyle(QuoteFormat.color(quote?.changePercent ?? 0))
                    .numericTextTransition(value: quote?.changePercent)
            }
            .monospacedDigit().lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
