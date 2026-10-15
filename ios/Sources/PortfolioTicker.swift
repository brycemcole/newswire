import SwiftUI

struct PortfolioTicker: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let change: String
        let tint: Color
        let action: () -> Void
    }

    let items: [Item]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var phase
    @State private var trackWidth: CGFloat = 0
    @State private var epoch = Date.now
    @State private var paused = false
    @State private var frozenOffset: CGFloat = 0

    private var manual: Bool { reduceMotion || voiceOver }

    var body: some View {
        Group {
            if manual {
                ScrollView(.horizontal) { track }
                    .scrollIndicators(.hidden)
            } else {
                GeometryReader { viewport in
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || phase != .active)) { context in
                        let distance = frozenOffset + (paused ? 0 : max(0, context.date.timeIntervalSince(epoch)) * 18)
                        let offset = trackWidth > 0 ? distance.truncatingRemainder(dividingBy: trackWidth) : 0
                        HStack(spacing: 0) {
                            track
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
                            ForEach(0..<(trackWidth > 0 ? max(1, Int(ceil(viewport.size.width / trackWidth))) : 1), id: \.self) { _ in
                                track.accessibilityHidden(true)
                            }
                        }
                        .fixedSize()
                        .offset(x: -offset)
                    }
                }
                .frame(height: 44)
                .clipped()
            }
        }
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 10)
            }
        }
        .contextMenu {
            Button(paused ? "Resume ticker" : "Pause ticker", systemImage: paused ? "play" : "pause") {
                if paused {
                    epoch = .now
                } else {
                    frozenOffset += max(0, Date.now.timeIntervalSince(epoch)) * 18
                }
                paused.toggle()
            }
        }
        .onChange(of: phase) { old, new in
            if old == .active && !paused {
                frozenOffset += max(0, Date.now.timeIntervalSince(epoch)) * 18
            }
            if new == .active { epoch = .now }
        }
    }

    private var track: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button(action: item.action) {
                    HStack(spacing: 7) {
                        Text(item.title).foregroundStyle(.primary)
                        if !item.change.isEmpty { Text(item.change).foregroundStyle(item.tint) }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct CompactPortfolioTicker: View {
    let openPortfolio: () -> Void
    let openWatchlist: () -> Void
    let openQuote: (String) -> Void
    @State private var store = PortfolioStore.shared
    @State private var performance = PortfolioPerformance.shared
    @State private var watchlist = Watchlist.shared
    @State private var board = MarketBoard.shared
    @Environment(\.scenePhase) private var phase

    private var items: [PortfolioTicker.Item] {
        let connected = !store.snapshot.positions.isEmpty || !(store.snapshot.accountBalances ?? []).isEmpty
        let today = performance.series[.day]
        var result = [PortfolioTicker.Item(id: "portfolio",
            title: connected ? Money.text(today?.last ?? store.snapshot.totalValue) : "Portfolio",
            change: connected ? today?.percent.map(Money.percent) ?? "—" : "Connect",
            tint: today.map { Money.tint($0.change) } ?? .secondary, action: openPortfolio)]
        result += watchlist.symbols.map { symbol in
            let quote = board.quotes[symbol]
            return PortfolioTicker.Item(id: symbol, title: OptionSymbol.display(symbol),
                change: quote.map { QuoteFormat.percent($0.changePercent) } ?? "—",
                tint: QuoteFormat.color(quote?.changePercent ?? 0), action: { openQuote(symbol) })
        }
        if watchlist.symbols.isEmpty {
            result.append(.init(id: "watchlist", title: "Watchlist", change: "Add symbols", tint: .secondary, action: openWatchlist))
        }
        return result
    }

    var body: some View {
        PortfolioTicker(items: items)
            .padding(.horizontal, 4)
            .homeCard()
            .task(id: phase == .active) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await performance.refresh(store.snapshot)
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
            .task(id: store.snapshot.updated) { await performance.refresh(store.snapshot) }
    }
}

#if DEBUG
struct PortfolioTickerPreview: View {
    var body: some View {
        NavigationStack {
            List {
                PortfolioTicker(items: [
                    .init(id: "portfolio", title: "$124,580.32", change: "+1.12%", tint: .green, action: {}),
                    .init(id: "AAPL", title: "AAPL", change: "+2.04%", tint: .green, action: {}),
                    .init(id: "MSFT", title: "MSFT", change: "+1.00%", tint: .green, action: {}),
                    .init(id: "SIE.DE", title: "SIE.DE", change: "−4.12%", tint: .red, action: {})
                ])
                .padding(.horizontal, 4).homeCard()
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                Text("Portfolio value and daily returns").foregroundStyle(.secondary)
            }
            .listStyle(.plain)
            .navigationTitle(Date.now.formatted(.dateTime.month(.abbreviated).day()))
        }
    }
}
#endif
