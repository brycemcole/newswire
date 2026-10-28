import Observation
import UIKit
import UserNotifications

nonisolated struct SoFiTrail: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    let symbol: String
    let percent: Double
    var enabled = true
    var high: Double?
    var lastPrice: Double?
    var quotedAt: Date?
    var triggeredAt: Date?

    var threshold: Double? { high.map { $0 * (1 - percent / 100) } }

    static func validSymbol(_ symbol: String) -> Bool {
        symbol.range(of: #"^[A-Z][A-Z0-9.\-]{0,9}$"#, options: .regularExpression) != nil || OptionSymbol(symbol) != nil
    }

    mutating func observe(_ quote: PriceWatchQuote, now: Date) -> Bool {
        guard enabled, triggeredAt == nil, (0.25...50).contains(percent),
              quote.currency == "USD", quote.canReplace(quotedAt ?? .distantPast, now: now),
              quote.quotedAt <= now,
              let session = MarketClock.session(on: now), session.contains(now),
              session.contains(quote.quotedAt) else { return false }
        high = max(high ?? quote.price, quote.price)
        lastPrice = quote.price
        quotedAt = quote.quotedAt
        guard let threshold, quote.price <= threshold else { return false }
        triggeredAt = now
        return true
    }

    func status(active: Bool, now: Date = .now) -> String {
        if triggeredAt != nil { return "Review in SoFi" }
        if !enabled { return "Paused" }
        if !active { return "Paused · app inactive" }
        guard let session = MarketClock.session(on: now), session.contains(now) else { return "Waiting for regular market hours" }
        guard let quotedAt, now.timeIntervalSince(quotedAt) <= 300 else { return "Waiting for a fresh quote" }
        return "Monitoring"
    }
}

@Observable final class SoFiTrailStore {
    static let shared = SoFiTrailStore()
    private(set) var rules: [SoFiTrail] = []
    private(set) var active = false
    private(set) var failures: Set<String> = []
    var message: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var activeRun = UUID()
    private let key = "sofiTrailingReviews"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do { rules = try JSONDecoder().decode([SoFiTrail].self, from: data) }
            catch { message = "Saved trailing alerts could not be read. No alerts are running." }
        }
    }

    func add(symbol raw: String, percent: Double) throws {
        let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard SoFiTrail.validSymbol(symbol), percent.isFinite, (0.25...50).contains(percent), rules.count < 20 else {
            throw TrailError.invalid
        }
        rules.append(SoFiTrail(symbol: symbol, percent: percent))
        save()
    }

    func toggle(_ id: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled.toggle()
        save()
    }

    func reset(_ id: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].high = nil
        rules[index].lastPrice = nil
        rules[index].quotedAt = nil
        rules[index].triggeredAt = nil
        rules[index].enabled = true
        clearNotification(id)
        save()
    }

    func remove(_ id: String) {
        rules.removeAll { $0.id == id }
        clearNotification(id)
        save()
    }

    func removeAll() {
        for rule in rules { clearNotification(rule.id) }
        rules = []
        save()
    }

    func enableNotifications() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            if !allowed { message = "Notifications are off. Triggered alerts still appear here while Newswire is open." }
        } catch { message = "Notifications could not be enabled. Review alerts in Newswire." }
    }

    func runWhileActive() async {
        #if DEBUG
        if CommandLine.arguments.contains("-sofiPreview") { return }
        #endif
        let run = UUID()
        activeRun = run
        active = true
        defer { if activeRun == run { active = false } }
        while !Task.isCancelled && UIApplication.shared.applicationState == .active {
            if let session = MarketClock.session(on: .now), session.contains(.now) {
                let symbols = Array(Set(rules.filter { $0.enabled && $0.triggeredAt == nil }.map(\.symbol)))
                for offset in stride(from: 0, to: symbols.count, by: 4) {
                    let batch = Array(symbols[offset..<min(offset + 4, symbols.count)])
                    let quotes = await withTaskGroup(of: (String, PriceWatchQuote?).self) { group in
                        for symbol in batch { group.addTask { (symbol, try? await MarketClient.priceWatchQuote(symbol)) } }
                        var result: [String: PriceWatchQuote] = [:]
                        for await (symbol, quote) in group { result[symbol] = quote }
                        return result
                    }
                    guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
                    for symbol in batch {
                        guard let quote = quotes[symbol] else { failures.insert(symbol); continue }
                        failures.remove(symbol)
                        let triggered = ingest(symbol: symbol, quote: quote, now: .now)
                        for rule in triggered { await notify(rule) }
                    }
                }
            }
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }

    @discardableResult func ingest(symbol: String, quote: PriceWatchQuote, now: Date) -> [SoFiTrail] {
        let previous = rules
        var triggered: [SoFiTrail] = []
        for index in rules.indices where rules[index].symbol == symbol {
            if rules[index].observe(quote, now: now) { triggered.append(rules[index]) }
        }
        if previous != rules { save() }
        return triggered
    }

    private func save() {
        do { defaults.set(try JSONEncoder().encode(rules), forKey: key) }
        catch { message = "Trailing alerts could not be saved." }
    }

    private func clearNotification(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["sofi-trail-" + id])
        center.removeDeliveredNotifications(withIdentifiers: ["sofi-trail-" + id])
    }

    private func notify(_ rule: SoFiTrail) async {
        let content = UNMutableNotificationContent()
        content.title = "Trailing alert · \(OptionSymbol.display(rule.symbol))"
        content.body = "The latest quote crossed your \(rule.percent.formatted())% trail. Open Portfolio → SoFi on this device to review. No order was placed."
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sofi-trail-" + rule.id, content: content, trigger: nil))
        } catch { message = "A trailing alert triggered, but its notification could not be delivered. Review it here." }
    }

    enum TrailError: LocalizedError {
        case invalid
        var errorDescription: String? { "Enter a stock symbol or full option contract symbol and a trail between 0.25% and 50%. You can save up to 20 alerts." }
    }
}
