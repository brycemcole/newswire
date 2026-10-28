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
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let page, !contracts.isEmpty, let spotIndex {
                        let below = Array(contracts[..<spotIndex])
                        let above = Array(contracts[spotIndex...])
                        columnHeader.padding(.horizontal, 16)
                        if !below.isEmpty { card(below) }
                        spotChip(page.spot)
                            .frame(maxWidth: .infinity)
                            .id("spot")
                            .task(id: "\(page.expiration?.timeIntervalSince1970 ?? 0)|\(calls)") {
                                // A scroll issued during the push transition is dropped.
                                try? await Task.sleep(for: .milliseconds(400))
                                reader.scrollTo("spot", anchor: .center)
                            }
                        if !above.isEmpty { card(above) }
                    } else if let error {
                        ContentUnavailableView(error, systemImage: "list.bullet.rectangle")
                    } else if page != nil {
                        ContentUnavailableView("No Contracts", systemImage: "list.bullet.rectangle",
                                               description: Text("Try another expiration."))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .safeAreaBar(edge: .top) {
                sideSwitch
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background {
                        Rectangle().fill(.regularMaterial)
                            .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                            .padding(.bottom, -16)
                            .ignoresSafeArea(edges: .top)
                            .allowsHitTesting(false)
                    }
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .dockClearance()
            .animation(.easeOut(duration: 0.2), value: contracts)
        }
        .navigationTitle("\(symbol) Options")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $contract) { QuoteDetail(symbol: $0.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { expirationMenu }
        }
        .sensoryFeedback(.selection, trigger: calls)
        .sensoryFeedback(.selection, trigger: expiration)
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

    private var sideSwitch: some View {
        GlassSwitch(label: "Side", selection: $calls, options: [true, false], segmentWidth: 64) { $0 ? "Calls" : "Puts" }
    }

    private var subtitle: String {
        guard let page else { return "" }
        let date = page.expiration.map { "Expires \($0.formatted(Self.dateStyle)) · \(daysOut($0))" }
        return date ?? "Spot \(QuoteFormat.price(page.spot))"
    }

    private static let dateStyle = Date.FormatStyle(timeZone: utc).month(.abbreviated).day()

    private var expirationMenu: some View {
        Menu {
            Picker("Expiration", selection: Binding(get: { page?.expiration }, set: { expiration = $0 })) {
                ForEach(page?.expirations ?? [], id: \.self) { date in
                    Text(date.formatted(Date.FormatStyle(timeZone: Self.utc).month(.abbreviated).day().year()))
                        .badge(daysOut(date))
                        .tag(Optional(date))
                }
            }
        } label: {
            Text(page?.expiration?.formatted(Self.dateStyle) ?? "Expiration")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .disabled(page?.expirations.isEmpty != false)
        .accessibilityLabel("Expiration")
        .accessibilityValue(page?.expiration?.formatted(Self.dateStyle) ?? "")
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("Strike")
            Spacer()
            Text("Mid")
            Text("Change").frame(width: 76, alignment: .trailing)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func card(_ options: [OptionContract]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { Divider().padding(.leading, 16) }
                row(option)
            }
        }
        .glassEffect(.regular.tint(options.first?.inTheMoney == true ? Color.wireAccent.opacity(0.12) : nil), in: .rect(cornerRadius: 22))
    }

    private func spotChip(_ spot: Double) -> some View {
        Text("\(symbol) \(QuoteFormat.price(spot))")
            .font(.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(Color.wireAccent)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .glassEffect(.regular, in: .capsule)
            .accessibilityLabel("Current price \(QuoteFormat.price(spot))")
    }

    private func row(_ option: OptionContract) -> some View {
        let watching = watchlist.contains(option.symbol)
        return Button { contract = MarketSymbol(id: option.symbol) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(QuoteFormat.price(option.strike)).font(.headline)
                        if watching { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                    }
                    Text([option.volatility.map { $0.formatted(.percent.precision(.fractionLength(0))) + " IV" },
                          "OI " + option.openInterest.formatted(.number.notation(.compactName))].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(QuoteFormat.price(option.mark)).font(.headline)
                        .numericTextTransition(value: option.mark)
                    Text("\(QuoteFormat.price(option.bid)) – \(QuoteFormat.price(option.ask))").font(.footnote).foregroundStyle(.secondary)
                        .numericTextTransition(text: "\(option.bid)–\(option.ask)")
                }
                Text(QuoteFormat.percent(option.changePercent))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(option.changePercent == 0 ? Color.primary : Color.white)
                    .numericTextTransition(value: option.changePercent)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 8)
                    .frame(width: 76, height: 30, alignment: .trailing)
                    .background(changeFill(option.changePercent), in: .rect(cornerRadius: 7))
            }
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(watching ? "Remove from Watchlist" : "Add to Watchlist", systemImage: watching ? "star.slash" : "star") {
                watchlist.toggle(option.symbol, price: option.mark)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(QuoteFormat.price(option.strike)) \(calls ? "call" : "put"), mid \(QuoteFormat.price(option.mark)), \(QuoteFormat.percent(option.changePercent))\(option.inTheMoney ? ", in the money" : "")\(watching ? ", watching" : "")")
        .accessibilityAction(named: watching ? "Remove from watchlist" : "Add to watchlist") { watchlist.toggle(option.symbol, price: option.mark) }
    }

    private func changeFill(_ change: Double) -> AnyShapeStyle {
        change > 0 ? AnyShapeStyle(Color.green) : change < 0 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.fill.tertiary)
    }

    private func daysOut(_ date: Date) -> String {
        // Yahoo stamps expirations at 00:00 UTC; the contract settles at the 4 PM ET close that day.
        let days = Int((date.addingTimeInterval(20 * 3600).timeIntervalSinceNow / 86_400).rounded(.up))
        return days <= 0 ? "Today" : "\(days)d"
    }
}

/// A capsule of text segments on interactive glass; the selected segment's fill slides between them.
struct GlassSwitch<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Value]
    /// Fixed segment width; nil stretches the segments to fill the available width.
    var segmentWidth: CGFloat? = nil
    let title: (Value) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    let selected = selection == option
                    Button {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.18)) { selection = option }
                    } label: {
                        Text(title(option))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .frame(width: segmentWidth, height: 32)
                            .frame(maxWidth: segmentWidth == nil ? .infinity : nil)
                            .background {
                                if selected {
                                    Capsule().fill(.fill.secondary)
                                        .matchedGeometryEffect(id: "selection", in: namespace)
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(3)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
