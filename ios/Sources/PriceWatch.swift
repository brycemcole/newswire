import ActivityKit
import Observation
import SwiftUI

nonisolated struct PriceWatch: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var symbol: String
    var target: Double?
    var direction: String
}

@Observable final class PriceWatchStore {
    static let shared = PriceWatchStore()
    private(set) var watches: [PriceWatch] = []
    var error: String?
    private var liveWatchIDs: Set<String> = []
    private var stateObservers: [String: Task<Void, Never>] = [:]
    private var tokens: [String: String] = [:]
    private var observers: [String: Task<Void, Never>] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: "priceWatches"),
           let saved = try? JSONDecoder().decode([PriceWatch].self, from: data) { watches = saved }
    }

    var registration: [[String: Any]] {
        watches.map { watch in
            var value: [String: Any] = ["id": watch.id, "symbol": watch.symbol, "direction": watch.direction]
            if let target = watch.target { value["target"] = target }
            return value
        }
    }

    var activityRegistration: [[String: Any]] {
        Activity<PriceWatchAttributes>.activities.compactMap { activity in
            guard activity.activityState == .active || activity.activityState == .stale,
                  watches.contains(where: { $0.id == activity.attributes.watchID }),
                  let token = tokens[activity.id] else { return nil }
            return ["watch_id": activity.attributes.watchID, "token": token,
                    "expires_at": Int(activity.attributes.expiresAt.timeIntervalSince1970)]
        }
    }

    func add(symbol: String, target: Double?, direction: String) async throws {
        guard watches.count < 20 else { throw WatchError.limit }
        let symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard symbol.range(of: "^[A-Z0-9.^=-]{1,30}$", options: .regularExpression) != nil,
              target == nil || (target!.isFinite && target! > 0) else { throw WatchError.invalid }
        _ = try await MarketClient.chart(symbol, range: .day)
        watches.append(PriceWatch(symbol: symbol, target: target, direction: direction))
        save()
        await PushDelegate.enable()
        await PushDelegate.syncStockAlerts()
    }

    func remove(_ watch: PriceWatch) async {
        watches.removeAll { $0.id == watch.id }
        save()
        await stop(watch)
    }

    func isLive(_ watch: PriceWatch) -> Bool {
        liveWatchIDs.contains(watch.id)
    }

    func start(_ watch: PriceWatch) async {
        guard !isLive(watch) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            error = "Allow Live Activities for Newswire in iOS Settings."
            return
        }
        do {
            let chart = try await MarketClient.chart(watch.symbol, range: .day)
            let price = chart.extendedQuote?.price ?? chart.price
            guard let quotedAt = chart.points.last?.date else { throw WatchError.invalid }
            let state = PriceWatchAttributes.ContentState(price: price, currency: chart.currency, quotedAt: quotedAt,
                target: watch.target, direction: watch.direction, reached: watch.target.map { watch.direction == "above" ? price >= $0 : price <= $0 } ?? false)
            guard watches.contains(where: { $0.id == watch.id }), !isLive(watch) else { return }
            #if targetEnvironment(simulator)
            let pushType: PushType? = nil
            #else
            let pushType: PushType? = .token
            #endif
            let activity = try Activity.request(attributes: PriceWatchAttributes(watchID: watch.id, expiresAt: .now.addingTimeInterval(8 * 3600), symbol: watch.symbol),
                content: ActivityContent(state: state, staleDate: quotedAt.addingTimeInterval(300)), pushType: pushType)
            liveWatchIDs.insert(watch.id)
            observe(activity)
        } catch { self.error = error.localizedDescription }
    }

    func stop(_ watch: PriceWatch) async {
        for activity in Activity<PriceWatchAttributes>.activities where activity.attributes.watchID == watch.id {
            await Self.endActivity(id: activity.id)
            observers.removeValue(forKey: activity.id)?.cancel()
            tokens.removeValue(forKey: activity.id)
        }
        liveWatchIDs.remove(watch.id)
        await PushDelegate.syncStockAlerts()
    }

    func restoreActivities() async {
        liveWatchIDs = Set(Activity<PriceWatchAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }.map { $0.attributes.watchID })
        for activity in Activity<PriceWatchAttributes>.activities {
            if watches.contains(where: { $0.id == activity.attributes.watchID }) { observe(activity) }
            else { await Self.endActivity(id: activity.id) }
        }
    }

    @concurrent nonisolated private static func endActivity(id: String) async {
        guard let activity = Activity<PriceWatchAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private func observe(_ activity: Activity<PriceWatchAttributes>) {
        if let token = activity.pushToken { tokens[activity.id] = token.map { String(format: "%02x", $0) }.joined() }
        guard observers[activity.id] == nil else { return }
        observers[activity.id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                self?.tokens[activity.id] = token.map { String(format: "%02x", $0) }.joined()
                await PushDelegate.syncStockAlerts()
            }
        }
        stateObservers[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed {
                    self?.liveWatchIDs.remove(activity.attributes.watchID)
                    self?.tokens.removeValue(forKey: activity.id)
                    self?.observers.removeValue(forKey: activity.id)?.cancel()
                    self?.stateObservers.removeValue(forKey: activity.id)
                    await PushDelegate.syncStockAlerts()
                    return
                }
            }
        }
        Task { await PushDelegate.syncStockAlerts() }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(watches), forKey: "priceWatches")
    }

    enum WatchError: LocalizedError {
        case invalid, limit
        var errorDescription: String? { self == .limit ? "You can watch up to 20 symbols." : "Enter a valid symbol and a positive target price." }
    }
}

struct PriceWatchView: View {
    var preview = false
    var initialSymbol = ""
    @State private var store = PriceWatchStore.shared
    @State private var symbol = ""
    @State private var target = ""
    @State private var direction = "above"
    @State private var saving = false
    @AppStorage("pushServerStatus") private var syncStatus = ""

    private var displayed: [PriceWatch] {
        preview ? [PriceWatch(symbol: "AAPL", target: 250, direction: "above"), PriceWatch(symbol: "SPY", target: 600, direction: "below")] : store.watches
    }

    var body: some View {
        Form {
            Section {
                TextField("Stock or option symbol", text: $symbol).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Target price (optional)", text: $target).keyboardType(.decimalPad)
                Picker("Notify when", selection: $direction) {
                    Text("At or above").tag("above")
                    Text("At or below").tag("below")
                }
                Button(saving ? "Adding…" : "Watch price") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            let text = target.trimmingCharacters(in: .whitespacesAndNewlines)
                            let amount = text.isEmpty ? nil : Double(text.replacingOccurrences(of: ",", with: "."))
                            guard text.isEmpty || amount != nil else { throw PriceWatchStore.WatchError.invalid }
                            try await store.add(symbol: symbol, target: amount, direction: direction)
                            symbol = ""; target = ""
                        } catch { store.error = error.localizedDescription }
                    }
                }.disabled(saving || symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preview)
            } footer: {
                Text("For an option premium, enter its full contract symbol, such as AAPL261218C00250000. For an underlying stock price target, enter the stock symbol. Targets alert once; remove and add again to rearm.")
            }
            Section("Watching") {
                if displayed.isEmpty { Text("Add a symbol to watch its price.").foregroundStyle(.secondary) }
                ForEach(displayed) { watch in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(watch.symbol).font(.headline)
                        if let price = watch.target {
                            Text("Alert \(watch.direction == "above" ? "at or above" : "at or below") \(price.formatted(.number.precision(.fractionLength(2))))").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button(store.isLive(watch) ? "Stop Live Activity" : "Start Live Activity", systemImage: "waveform.path") {
                            Task { if store.isLive(watch) { await store.stop(watch) } else { await store.start(watch) } }
                        }.disabled(preview)
                    }
                    .swipeActions { Button("Remove", role: .destructive) { Task { await store.remove(watch) } }.disabled(preview) }
                }
            }
            Section {
                Text("Prices may be delayed. The monitor checks about once a minute while running; iOS controls Live Activity delivery. Activities last up to eight hours. Alerts continue after an activity ends.")
                if !syncStatus.isEmpty { Text(syncStatus) }
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .onAppear { if symbol.isEmpty { symbol = initialSymbol } }
        .navigationTitle("Live prices and targets")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Price watching", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}
