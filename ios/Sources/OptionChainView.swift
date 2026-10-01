import SwiftUI

struct OptionChainView: View {
    let symbol: String
    @State private var page: OptionChainPage?
    @State private var expiration: Date?
    @State private var calls = true
    @State private var error: String?
    @State private var contract: MarketSymbol?
    @State private var watchlist = Watchlist.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let utc = TimeZone(identifier: "UTC")!

    private var contracts: [OptionContract] { (calls ? page?.calls : page?.puts) ?? [] }

    /// The first strike above spot, so the spot marker sits between the last strike below and this one.
    private var spotIndex: Int? {
        guard let spot = page?.spot else { return nil }
        return contracts.firstIndex { $0.strike > spot } ?? contracts.count
    }

    var body: some View {
        ScrollViewReader { reader in
            List {
                if let page, !contracts.isEmpty {
                    ForEach(Array(contracts.enumerated()), id: \.element.id) { index, option in
                        if index == spotIndex { spotRow(page.spot) }
                        row(option)
                    }
                    if spotIndex == contracts.count { spotRow(page.spot) }
                } else if let error {
                    ContentUnavailableView(error, systemImage: "list.bullet.rectangle")
                        .listRowBackground(Color.clear)
                } else if page != nil {
                    ContentUnavailableView("No contracts", systemImage: "list.bullet.rectangle")
                        .listRowBackground(Color.clear)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120).listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .dockClearance()
            .safeAreaBar(edge: .top) {
                VStack(spacing: 8) {
                    expirationPicker
                    Picker("Side", selection: $calls) {
                        Text("Calls").tag(true)
                        Text("Puts").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    columnHeader.padding(.horizontal, 20)
                }
                .padding(.bottom, 8)
                .background(.background)
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .animation(.easeOut(duration: 0.2), value: contracts)
            .onChange(of: "\(page?.expiration?.timeIntervalSince1970 ?? 0)|\(calls)") {
                guard let spotIndex, !contracts.isEmpty else { return }
                reader.scrollTo(contracts[min(max(spotIndex - 1, 0), contracts.count - 1)].id, anchor: .center)
            }
        }
        .navigationTitle("\(symbol) Options")
        .navigationSubtitle(page.map { "Spot \(QuoteFormat.price($0.spot))" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $contract) { QuoteDetail(symbol: $0.id) }
        .sensoryFeedback(.selection, trigger: calls)
        .task(id: "\(expiration?.timeIntervalSince1970 ?? 0)|\(phase == .active)") {
            guard phase == .active else { return }
            while !Task.isCancelled {
                do {
                    let fresh = try await OptionChain.page(symbol: symbol, expiration: expiration)
                    page = fresh
                    error = nil
                } catch is CancellationError {
                    return
                } catch {
                    if page == nil { self.error = error.localizedDescription }
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private var expirationPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(page?.expirations ?? [], id: \.self) { date in
                    let selected = date == page?.expiration
                    Button {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.15)) { expiration = date }
                    } label: {
                        VStack(spacing: 1) {
                            Text(date.formatted(Date.FormatStyle(timeZone: Self.utc).month(.abbreviated).day()))
                                .font(.subheadline.weight(.semibold))
                            Text(daysOut(date)).font(.caption2).foregroundStyle(selected ? Theme.shared.accent.onColor.opacity(0.8) : .secondary)
                        }
                        .foregroundStyle(selected ? Theme.shared.accent.onColor : .primary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(selected ? AnyShapeStyle(Color.wireAccent) : AnyShapeStyle(.fill.tertiary), in: .capsule)
                    }
                    .buttonStyle(PressSpringStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: expiration)
    }

    private var columnHeader: some View {
        HStack {
            Text("Strike").frame(width: 76, alignment: .leading)
            Text("Mid · Bid–Ask")
            Spacer()
            Text("Change · IV")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func spotRow(_ spot: Double) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.wireAccent).frame(height: 1)
            Text("\(symbol) \(QuoteFormat.price(spot))")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.wireAccent)
                .fixedSize()
            Rectangle().fill(Color.wireAccent).frame(height: 1)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel("Current price \(QuoteFormat.price(spot))")
    }

    private func row(_ option: OptionContract) -> some View {
        let watching = watchlist.contains(option.symbol)
        return Button { contract = MarketSymbol(id: option.symbol) } label: {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text(QuoteFormat.price(option.strike)).font(.body.weight(.semibold).monospacedDigit())
                    if watching { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                .frame(width: 76, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(QuoteFormat.price(option.mark)).font(.subheadline.weight(.semibold))
                    Text("\(QuoteFormat.price(option.bid))–\(QuoteFormat.price(option.ask))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(QuoteFormat.percent(option.changePercent))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(QuoteFormat.color(option.changePercent))
                    Text([option.volatility.map { $0.formatted(.percent.precision(.fractionLength(0))) + " IV" },
                          "OI " + option.openInterest.formatted(.number.notation(.compactName))].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(option.id)
        .listRowBackground(option.inTheMoney ? Color.wireAccent.opacity(0.08) : Color.clear)
        .swipeActions(edge: .trailing) {
            Button { watchlist.toggle(option.symbol, price: option.mark) } label: {
                Label(watching ? "Unwatch" : "Watch", systemImage: watching ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .contextMenu {
            Button(watching ? "Remove from Watchlist" : "Add to Watchlist", systemImage: watching ? "star.slash" : "star") {
                watchlist.toggle(option.symbol, price: option.mark)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(QuoteFormat.price(option.strike)) \(calls ? "call" : "put"), mid \(QuoteFormat.price(option.mark)), \(QuoteFormat.percent(option.changePercent))\(option.inTheMoney ? ", in the money" : "")\(watching ? ", watching" : "")")
        .accessibilityAction(named: watching ? "Remove from watchlist" : "Add to watchlist") { watchlist.toggle(option.symbol, price: option.mark) }
    }

    private func daysOut(_ date: Date) -> String {
        // Yahoo stamps expirations at 00:00 UTC; the contract settles at the 4 PM ET close that day.
        let days = Int((date.addingTimeInterval(20 * 3600).timeIntervalSinceNow / 86_400).rounded(.up))
        return days <= 0 ? "Today" : "\(days)d"
    }
}
