import SwiftUI

struct ScreenerSheet: View {
    @State var preset: ScreenerPreset
    let store: ScreenerStore
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(preset: ScreenerPreset, store: ScreenerStore, onSelect: @escaping (String) -> Void) {
        _preset = State(initialValue: preset)
        self.store = store
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            let rows = store.rows(preset)
            let state = store.state(preset)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    chips
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.blurb).font(.subheadline).foregroundStyle(.secondary)
                        Text(preset.criteria).font(.caption).foregroundStyle(.tertiary)
                        status(state: state)
                    }
                    .padding(.horizontal, 20)
                    if rows.isEmpty {
                        empty(state: state)
                    } else {
                        LazyVStack(spacing: 0) {
                            header
                            ForEach(rows) { row in
                                Button { dismiss(); onSelect(row.symbol) } label: { ScreenerRowView(row: row, metric: preset.metric) }
                                    .buttonStyle(.plain)
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle(preset.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(store.isPinned(preset) ? "Hide from Markets" : "Show on Markets",
                           systemImage: store.isPinned(preset) ? "pin.slash" : "pin") { store.togglePin(preset) }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task(id: preset.id) {
                while !Task.isCancelled {
                    await store.refresh(preset)
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ScreenerPreset.all) { item in
                        Button { withAnimation(.easeOut(duration: 0.2)) { preset = item } } label: {
                            Label(item.title, systemImage: item.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(item == preset ? Color.wireAccent : .primary)
                                .padding(.horizontal, 14).frame(height: 40)
                                .contentShape(.capsule)
                                .glassEffect(item == preset ? .regular.tint(Color.wireAccent.opacity(0.18)).interactive() : .regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(PressSpringStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    @ViewBuilder
    private func status(state: MarketLoadState) -> some View {
        if let progress = store.volatilityProgress, preset.isImpliedVolatility {
            Text("Checking options \(progress.done) of \(progress.total)").font(.caption).foregroundStyle(.secondary)
        } else if state == .unavailable {
            HStack(spacing: 6) {
                Text("Showing cached results")
                Button("Retry") { Task { await store.refresh(preset, force: true) } }.foregroundStyle(Color.wireAccent)
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if let stamp = store.updatedAt[preset.id] {
            Text("Updated \(stamp.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
        }
        if store.usesEstimatedVolatility(preset) {
            Text("Options are closed for some names, so their IV is estimated from the last trade.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func empty(state: MarketLoadState) -> some View {
        if state == .loading || (preset.isImpliedVolatility && store.volatilityProgress != nil) {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            VStack(spacing: 10) {
                Text(state == .loaded ? "Nothing matches right now" : "\(preset.title) unavailable").foregroundStyle(.secondary)
                Button("Try again") { Task { await store.refresh(preset, force: true) } }.buttonStyle(.bordered).tint(Color.wireAccent)
            }
            .frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    private var header: some View {
        HStack {
            Text("Symbol")
            Spacer()
            if preset.metric != .change { Text(preset.metric.header).frame(width: 70, alignment: .trailing) }
            Text("Price · Change").frame(width: 110, alignment: .trailing)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 6)
    }
}

private struct ScreenerRowView: View {
    let row: ScreenerRow
    let metric: ScreenerMetric

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(.body.weight(.semibold))
                Text(row.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value = row.metric(metric) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().frame(width: 70, alignment: .trailing)
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text(QuoteFormat.price(row.price)).font(.subheadline.weight(.semibold)).monospacedDigit()
                ChangeBadge(percent: row.changePercent)
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 56)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.label), \(row.name), \(QuoteFormat.price(row.price)), \(QuoteFormat.percent(row.changePercent))\(row.metric(metric).map { ", \(metric.header) \($0)" } ?? "")")
    }
}
