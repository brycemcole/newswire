import ActivityKit
import Observation
import SwiftUI
import UserNotifications

nonisolated struct PriceWatch: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var symbol: String
    var target: Double?
    var direction: String
    var percent: Double?

    var alertDescription: String {
        if let percent {
            return "Notify on a \(direction == "either" ? "±" : direction == "above" ? "+" : "−")\(percent.formatted())% daily move"
        }
        if let target { return "Alert at or \(direction == "above" ? "above" : "below") \(target.formatted(.number.precision(.fractionLength(2))))" }
        return "Live Activity only · no price notification"
    }
}

nonisolated struct PriceWatchQuote: Sendable {
    var price: Double
    var currency: String
    var quotedAt: Date

    static func parse(_ chart: YValue, now: Date = .now) -> Self? {
        let meta = chart["meta"]
        let (currency, divisor) = MinorCurrency.major(meta?["currency"]?.text)
        var quotes: [Self] = []
        if let price = meta?["regularMarketPrice"]?.raw, let stamp = meta?["regularMarketTime"]?.raw {
            quotes.append(Self(price: price / divisor, currency: currency, quotedAt: Date(timeIntervalSince1970: stamp)))
        }
        let stamps = chart["timestamp"]?.array ?? []
        let closes = chart["indicators"]?["quote"]?.array.first?["close"]?.array ?? []
        for (stamp, close) in zip(stamps, closes) {
            if let time = stamp.raw, let price = close.raw {
                quotes.append(Self(price: price / divisor, currency: currency, quotedAt: Date(timeIntervalSince1970: time)))
            }
        }
        return quotes.filter { $0.price.isFinite && $0.price > 0 && $0.quotedAt.timeIntervalSince1970.isFinite && $0.quotedAt.timeIntervalSince1970 > 0 && $0.quotedAt <= now.addingTimeInterval(60) }.max { $0.quotedAt < $1.quotedAt }
    }

    func state(for watch: PriceWatch, now: Date = .now) -> PriceWatchAttributes.ContentState {
        PriceWatchAttributes.ContentState(price: price, currency: currency, quotedAt: quotedAt,
            target: watch.target, direction: watch.direction,
            reached: canReplace(.distantPast, now: now) && (watch.target.map { watch.direction == "above" ? price >= $0 : price <= $0 } ?? false))
    }

    func canReplace(_ date: Date, now: Date = .now) -> Bool {
        price.isFinite && price > 0 && quotedAt > date && now.timeIntervalSince(quotedAt) <= 300 && quotedAt.timeIntervalSince(now) <= 60
    }
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
            if let percent = watch.percent { value["percent"] = percent }
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

    func add(symbol: String, target: Double?, direction: String, percent: Double? = nil) async throws {
        guard watches.count < 20 else { throw WatchError.limit }
        let symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard symbol.range(of: "^[A-Z0-9.^=-]{1,30}$", options: .regularExpression) != nil,
              target == nil || (target!.isFinite && target! > 0),
              percent == nil || (percent!.isFinite && (0.25...50).contains(percent!) && target == nil),
              ["above", "below"].contains(direction) || (percent != nil && direction == "either") else { throw WatchError.invalid }
        _ = try await MarketClient.chart(symbol, range: .day)
        watches.append(PriceWatch(symbol: symbol, target: target, direction: direction, percent: percent))
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
            let quote = try await MarketClient.priceWatchQuote(watch.symbol)
            let quotedAt = quote.quotedAt
            let state = quote.state(for: watch)
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
            #if !targetEnvironment(simulator)
            UIApplication.shared.registerForRemoteNotifications()
            #endif
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

    func refreshWhileActive() async {
        while !Task.isCancelled && UIApplication.shared.applicationState == .active {
            let activities = Activity<PriceWatchAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
            let symbols = Set(activities.filter { activity in watches.contains { $0.id == activity.attributes.watchID } }.map { $0.attributes.symbol })
            let quotes = await withTaskGroup(of: (String, PriceWatchQuote?).self) { group in
                for symbol in symbols { group.addTask { (symbol, try? await MarketClient.priceWatchQuote(symbol)) } }
                var quotes: [String: PriceWatchQuote] = [:]
                for await (symbol, quote) in group { quotes[symbol] = quote }
                return quotes
            }
            guard !Task.isCancelled && UIApplication.shared.applicationState == .active else { return }
            for activity in activities {
                guard let watch = watches.first(where: { $0.id == activity.attributes.watchID }),
                      let quote = quotes[watch.symbol], quote.canReplace(activity.content.state.quotedAt) else { continue }
                await Self.updateActivity(id: activity.id, state: quote.state(for: watch))
            }
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }

    @concurrent nonisolated private static func updateActivity(id: String, state: PriceWatchAttributes.ContentState) async {
        guard !Task.isCancelled,
              let activity = Activity<PriceWatchAttributes>.activities.first(where: { $0.id == id }),
              activity.activityState == .active || activity.activityState == .stale,
              state.quotedAt > activity.content.state.quotedAt else { return }
        await activity.update(ActivityContent(state: state, staleDate: state.quotedAt.addingTimeInterval(300)))
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
        var errorDescription: String? { self == .limit ? "You can watch up to 20 symbols." : "Enter a valid symbol, a positive price, or a percentage from 0.25 to 50." }
    }
}

struct PriceWatchView: View {
    var preview = false
    var initialSymbol = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = PriceWatchStore.shared
    @State private var symbol = ""
    @State private var target = ""
    @State private var mode = "target"
    @State private var percent = 1.0
    @State private var direction = "above"
    @State private var saving = false
    @State private var permission = "Checking…"
    @State private var denied = false
    @State private var frequent = ActivityAuthorizationInfo().frequentPushesEnabled
    @AppStorage("pushServerStatus") private var syncStatus = ""
    @AppStorage("pushRegistrationStatus") private var registrationStatus = "Not registered"

    private var displayed: [PriceWatch] {
        preview ? [PriceWatch(symbol: "AAPL", target: 250, direction: "above"),
                   PriceWatch(symbol: "SPY", target: nil, direction: "either", percent: 1)] : store.watches
    }

    var body: some View {
        Form {
            Section {
                TextField("Stock or option symbol", text: $symbol).textInputAutocapitalization(.characters).autocorrectionDisabled()
                Picker("Alert", selection: $mode) {
                    Text("Target price").tag("target")
                    Text("Percentage move").tag("percent")
                    Text("Live Activity only").tag("live")
                }
                if mode == "target" {
                    TextField("Target price", text: $target).keyboardType(.decimalPad)
                    Picker("Notify when", selection: $direction) {
                        Text("At or above").tag("above")
                        Text("At or below").tag("below")
                    }
                } else if mode == "percent" {
                    Picker("Daily move", selection: $percent) {
                        ForEach([0.25, 0.5, 1, 2, 3, 5, 10], id: \.self) { Text("\($0.formatted())%").tag($0) }
                    }
                    Picker("Direction", selection: $direction) {
                        Text("Either direction").tag("either")
                        Text("Up").tag("above")
                        Text("Down").tag("below")
                    }
                }
                Button(saving ? "Adding…" : mode == "live" ? "Add live price" : "Add price alert") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            let text = target.trimmingCharacters(in: .whitespacesAndNewlines)
                            let amount = mode == "target" ? Double(text.replacingOccurrences(of: ",", with: ".")) : nil
                            guard mode != "target" || amount != nil else { throw PriceWatchStore.WatchError.invalid }
                            try await store.add(symbol: symbol, target: amount, direction: direction, percent: mode == "percent" ? percent : nil)
                            symbol = ""; target = ""
                            await refreshDelivery()
                        } catch { store.error = error.localizedDescription }
                    }
                }.disabled(saving || symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == "target" && target.isEmpty) || preview)
            } header: { Text("New price watch") } footer: {
                Text(mode == "percent" ? "Compared with the previous close. Alerts on a new crossing, with at least 30 minutes between alerts. Requires a fresh quote and a previous close." : mode == "target" ? "Notifies once when the price meets your target. Remove and add again to rearm. For options, enter the full contract symbol, such as AAPL261218C00250000." : "Shows the price on your Lock Screen after you start a Live Activity. This choice does not send price notifications.")
            }
            Section("Watching") {
                if displayed.isEmpty { Text("Add a symbol and choose when to be notified.").foregroundStyle(.secondary) }
                ForEach(displayed) { watch in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(watch.symbol).font(.headline)
                        Text(watch.alertDescription).font(.subheadline).foregroundStyle(.secondary)
                        Button(store.isLive(watch) ? "Stop Live Activity" : "Start Live Activity", systemImage: "waveform.path") {
                            Task { if store.isLive(watch) { await store.stop(watch) } else { await store.start(watch) } }
                        }.disabled(preview)
                    }
                    .swipeActions { Button("Remove", role: .destructive) { Task { await store.remove(watch) } }.disabled(preview) }
                }
            }
            Section {
                LabeledContent("Notifications", value: preview ? "Allowed · banners and sound" : permission)
                if !preview {
                    Text(registrationStatus)
                    if !syncStatus.isEmpty { Text(syncStatus) }
                    Button(denied ? "Allow notifications in Settings" : "Enable or retry alerts", systemImage: "bell.badge") {
                        Task {
                            if denied { await openSettings() }
                            else { await PushDelegate.enable(); await PushDelegate.syncStockAlerts() }
                            await refreshDelivery()
                        }
                    }
                }
                LabeledContent("Frequent Live Activity updates", value: frequent ? "On" : "Off")
                Button("Open notification and Live Activity settings", systemImage: "gear") { Task { await openSettings() } }.disabled(preview)
            } header: { Text("Delivery setup") } footer: {
                Text("Allow notifications, banners and sounds in iOS Settings. Focus and Scheduled Summary can delay alerts. Enable Live Activities and More Frequent Updates for faster Lock Screen prices.")
            }
            Section {
                Text("Newswire checks Yahoo directly every 15 seconds while open. Server pushes keep Live Activities updated when the app is in the background. Prices may be delayed by the provider; iOS controls Live Activity delivery. The quote time shows when the price was observed. Activities last up to eight hours; alerts continue after they end.")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .onAppear { if symbol.isEmpty { symbol = initialSymbol } }
        .onChange(of: mode) { _, value in direction = value == "percent" ? "either" : "above" }
        .task { if !preview { await refreshDelivery() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active && !preview { Task { await refreshDelivery(); await PushDelegate.syncStockAlerts() } } }
        .navigationTitle("Live prices and alerts")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Price watching", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private func refreshDelivery() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        denied = settings.authorizationStatus == .denied
        switch settings.authorizationStatus {
        case .authorized, .ephemeral:
            permission = settings.alertSetting == .enabled ? "Allowed · \(settings.soundSetting == .enabled ? "sound on" : "sound off")" : "Allowed · alerts off"
        case .provisional: permission = "Quiet delivery · enable banners in Settings"
        case .denied: permission = "Off in iOS Settings"
        case .notDetermined: permission = "Not enabled"
        @unknown default: permission = "Unknown"
        }
        frequent = ActivityAuthorizationInfo().frequentPushesEnabled
    }

    private func openSettings() async {
        if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
    }
}
