import SwiftUI

nonisolated struct SessionAlert: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: String
    var minutes: Int = 15
    var symbol: String = "ES=F"
    var direction: String = "either"
    var threshold: Double = 0.5
    var at: Date = Date.now.addingTimeInterval(3600)
    var eventTitle: String = "Market reminder"

    var title: String {
        switch kind {
        case "preopen": "\(minutes) min before the open"
        case "close": "5 min after the close"
        case "reopen": "When futures reopen"
        case "event": eventTitle
        default: "\(Self.names[symbol] ?? symbol) futures · \(direction == "either" ? "±" : direction == "up" ? "+" : "−")\(threshold.formatted())%"
        }
    }
    static let names = ["ES=F": "S&P 500", "NQ=F": "Nasdaq 100", "RTY=F": "Russell 2000"]
}

@Observable final class SessionAlertStore {
    static let shared = SessionAlertStore()
    private(set) var alerts: [SessionAlert] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: "sessionAlerts"), let saved = try? JSONDecoder().decode([SessionAlert].self, from: data) { alerts = saved }
    }

    var registration: [[String: Any]] {
        alerts.map { ["id": $0.id, "kind": $0.kind, "minutes": $0.minutes, "symbol": $0.symbol, "direction": $0.direction, "threshold": $0.threshold, "at": ISO8601DateFormatter().string(from: $0.at), "title": $0.eventTitle] }
    }

    func add(_ alert: SessionAlert) async {
        guard alerts.count < 20 else { return }
        alerts.append(alert)
        save()
        await PushDelegate.enable()
        await PushDelegate.syncStockAlerts()
    }

    func remove(at offsets: IndexSet) async {
        for index in offsets.sorted(by: >) { alerts.remove(at: index) }
        save()
        await PushDelegate.syncStockAlerts()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(alerts) { UserDefaults.standard.set(data, forKey: "sessionAlerts") }
    }
}

struct SessionAlertsView: View {
    var preview = false
    @State private var store = SessionAlertStore.shared
    @State private var draft = SessionAlert(kind: "preopen")
    @State private var saving = false
    @AppStorage("pushServerStatus") private var syncStatus = ""
    @AppStorage("pushRegistrationStatus") private var registrationStatus = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Be ready for the next move", systemImage: "bell.badge")
                        .font(.headline)
                    Text("Choose a moment in the market day, or let a futures move bring you back.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Picker("When", selection: $draft.kind) {
                        Text("Before the open").tag("preopen")
                        Text("After the close").tag("close")
                        Text("Futures reopen").tag("reopen")
                        Text("At a time or event").tag("event")
                        Text("Futures move").tag("move")
                    }
                    if draft.kind == "preopen" {
                        Picker("Remind me", selection: $draft.minutes) {
                            ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) minutes before").tag($0) }
                        }
                    } else if draft.kind == "event" {
                        TextField("Reminder", text: $draft.eventTitle)
                        DatePicker("When", selection: $draft.at, in: Date.now...)
                        ForEach(PulseStore.shared.current?.comingUp?.filter { $0.at > .now } ?? []) { event in
                            Button("10 min before \(event.title)") {
                                draft.eventTitle = String(event.title.prefix(120))
                                draft.at = max(.now.addingTimeInterval(60), event.at.addingTimeInterval(-600))
                            }
                        }
                    } else if draft.kind == "move" {
                        Picker("Market", selection: $draft.symbol) {
                            ForEach(["ES=F", "NQ=F", "RTY=F"], id: \.self) { Text(SessionAlert.names[$0] ?? $0).tag($0) }
                        }
                        Picker("Direction", selection: $draft.direction) {
                            Text("Either direction").tag("either")
                            Text("Up").tag("up")
                            Text("Down").tag("down")
                        }
                        Picker("Move", selection: $draft.threshold) {
                            ForEach([0.25, 0.5, 1, 2, 3, 5, 10], id: \.self) { Text("\($0.formatted())%").tag($0) }
                        }
                    }
                } header: { Text("New alert") } footer: {
                    Text(draft.kind == "event" ? "One-time reminder. Event times may change; this reminder keeps the time you save." : draft.kind == "reopen" ? "Waits for a fresh S&P 500 futures quote after the scheduled reopening. No alert if trading has not resumed." : draft.kind == "move" ? "Measured against the previous settlement reference. Requires a quote less than 5 minutes old. Repeats only after a new crossing and a 30-minute cooldown." : "Follows the US stock-market calendar, including holidays, early closes and daylight saving time. Times display in your local time zone.")
                }
                Section {
                    Button {
                        guard !preview else { return }
                        saving = true
                        Task { await store.add(draft); saving = false }
                    } label: {
                        HStack { Spacer(); if saving { ProgressView() }; Text(preview ? "Add alert · preview" : "Add alert").fontWeight(.semibold); Spacer() }
                    }.disabled(saving || draft.eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.eventTitle.count > 120 || (!preview && store.alerts.count >= 20))
                }
                let alerts = preview ? [SessionAlert(kind: "preopen"), SessionAlert(kind: "move", symbol: "NQ=F", threshold: 1)] : store.alerts
                if !alerts.isEmpty {
                    Section("Your alerts") {
                        ForEach(alerts) { alert in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(alert.title, systemImage: alert.kind == "move" ? "waveform.path" : "clock")
                                if alert.kind == "event" { Text(alert.at, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.onDelete { offsets in if !preview { Task { await store.remove(at: offsets) } } }
                    }
                }
                if !preview && !store.alerts.isEmpty {
                    Section("Delivery") {
                        Text(registrationStatus.isEmpty ? "Enable notifications to receive alerts." : registrationStatus)
                        if !syncStatus.isEmpty { Text(syncStatus).foregroundStyle(.secondary) }
                    }.font(.footnote)
                }
            }
            .navigationTitle("Market alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}
