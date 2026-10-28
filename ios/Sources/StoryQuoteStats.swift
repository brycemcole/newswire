import SwiftUI

struct StoryQuoteStats: View {
    let symbols: [String]
    let quotes: [String: Quote]

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            FlowLayout(spacing: 6) { ForEach(symbols, id: \.self) { pill($0) } }
        }
        .padding(.top, 4)
    }

    private func pill(_ symbol: String) -> some View {
        HStack(spacing: 6) {
            Text(symbol).fontWeight(.semibold).foregroundStyle(.primary)
            if let quote = quotes[symbol] {
                Text(QuoteFormat.percent(quote.changePercent))
                    .numericTextTransition(value: quote.changePercent).foregroundStyle(QuoteFormat.color(quote.changePercent))
            }
            if let extended = quotes[symbol]?.extended {
                Text(extended.session == "pre" ? "Pre" : extended.session == "overnight" ? "Night" : "AH").foregroundStyle(.secondary)
                Text(QuoteFormat.percent(extended.changePercent))
                    .numericTextTransition(value: extended.changePercent).foregroundStyle(QuoteFormat.color(extended.changePercent))
            }
        }
        .font(.caption.monospaced()).monospacedDigit()
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}
