import Charts
import SwiftUI

nonisolated struct SessionQuote: Codable, Identifiable {
    let id: String
    let price: Double
    let change: Double
    let at: Date
    let points: [Double]

    static func parse(_ root: YValue, symbol: String, baseline: Double? = nil) -> SessionQuote? {
        guard let result = root["chart"]?["result"]?.array.first else { return nil }
        let stamps = result["timestamp"]?.array ?? []
        let closes = result["indicators"]?["quote"]?.array.first?["close"]?.array ?? []
        let valid = stamps.indices.compactMap { index -> (Date, Double)? in
            guard index < closes.count, let stamp = stamps[index].raw, let price = closes[index].raw, price > 0 else { return nil }
            return (Date(timeIntervalSince1970: stamp), price)
        }
        guard let last = valid.last, let previous = baseline ?? result["meta"]?["chartPreviousClose"]?.raw ?? result["meta"]?["previousClose"]?.raw, previous > 0 else { return nil }
        return SessionQuote(id: symbol, price: last.1, change: (last.1 / previous - 1) * 100, at: last.0,
                            points: valid.filter { $0.0 >= last.0.addingTimeInterval(-86400) }.map(\.1))
    }

    @concurrent static func fetch(_ symbol: String) async throws -> SessionQuote? {
        func load(_ range: String) async throws -> YValue {
            var url = URLComponents()
            url.scheme = "https"
            url.host = "query1.finance.yahoo.com"
            url.path = "/v8/finance/chart/\(symbol)"
            url.queryItems = [URLQueryItem(name: "range", value: range), URLQueryItem(name: "interval", value: "5m"), URLQueryItem(name: "includePrePost", value: "true")]
            guard let address = url.url else { throw MarketError.status(0) }
            let (data, code) = try await MarketClient.load(address)
            guard code == 200 else { throw MarketError.status(code) }
            return try JSONDecoder().decode(YValue.self, from: data)
        }
        let daily = try await load("1d")
        if let quote = parse(daily, symbol: symbol) { return quote }
        let baseline = daily["chart"]?["result"]?.array.first?["meta"]?["chartPreviousClose"]?.raw
        return parse(try await load("5d"), symbol: symbol, baseline: baseline)
    }
}

@Observable final class HomeSessionStore {
    static let shared = HomeSessionStore()
    private(set) var quotes: [String: SessionQuote] = [:]
    private var fetchedAt: Date?
    private var loading = false
    var failed = false
    private(set) var lastVisit = UserDefaults.standard.object(forKey: "marketSessionLastVisit") as? Date
    private(set) var previousQuotes: [String: SessionQuote] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: "homeSessionQuotes"), let saved = try? JSONDecoder().decode([String: SessionQuote].self, from: data) {
            quotes = saved
            previousQuotes = saved
        }
    }

    func rememberVisit() {
        UserDefaults.standard.set(Date.now, forKey: "marketSessionLastVisit")
        if let data = try? JSONEncoder().encode(quotes) { UserDefaults.standard.set(data, forKey: "homeSessionQuotes") }
    }

    func resumeVisit() {
        lastVisit = UserDefaults.standard.object(forKey: "marketSessionLastVisit") as? Date
        previousQuotes = quotes
    }

    func refresh() async {
        guard !loading, fetchedAt.map({ -$0.timeIntervalSinceNow >= 55 }) ?? true else { return }
        loading = true
        defer { loading = false }
        let symbols = MarketClock.session(on: .now)?.contains(.now) == true ? ["^GSPC", "^IXIC", "^RUT"] : ["ES=F", "NQ=F", "RTY=F"]
        let found = await withTaskGroup(of: SessionQuote?.self) { group in
            for symbol in symbols {
                group.addTask {
                    try? await SessionQuote.fetch(symbol)
                }
            }
            var values: [SessionQuote] = []
            for await quote in group { if let quote { values.append(quote) } }
            return values
        }
        guard !Task.isCancelled else { return }
        for quote in found { quotes[quote.id] = quote }
        failed = found.count < symbols.count
        fetchedAt = .now
    }
}

struct MarketSessionCard: View {
    var fixture: String? = nil
    var onQuote: (String) -> Void = { _ in }
    @State private var store = HomeSessionStore.shared
    @State private var expanded = false
    @State private var alerts = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sampleDate: Date? {
        guard let fixture else { return nil }
        let dates = ["overnight": "2026-10-19T00:30:00Z", "premarket": "2026-10-19T12:45:00Z", "open": "2026-10-19T15:10:00Z", "closed": "2026-10-17T16:00:00Z", "after": "2026-10-19T20:15:00Z"]
        return ISO8601DateFormatter().date(from: dates[fixture] ?? dates["premarket"]!)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: sampleDate ?? context.date)
        }
        .onChange(of: scenePhase) { _, phase in
            guard fixture == nil else { return }
            if phase == .background { store.rememberVisit() }
            if phase == .active { store.resumeVisit() }
        }
        .sheet(isPresented: $alerts) { SessionAlertsView(preview: fixture != nil) }
        .task(id: scenePhase) {
            guard fixture == nil, scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private func content(now: Date) -> some View {
        let open = MarketClock.session(on: now)?.contains(now) == true
        let symbols = open ? ["^GSPC", "^IXIC", "^RUT"] : ["ES=F", "NQ=F", "RTY=F"]
        let scheduled = MarketClock.futuresScheduled(now)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Circle().fill(open ? Color.green : Color.wireAccent).frame(width: 5, height: 5)
                            Text(open ? "US MARKETS" : "NEXT SESSION").tracking(1.5)
                            if fixture != nil { Text("· DEMO").tracking(1) }
                        }.font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(MarketClock.title(at: now)).font(.system(.title3, design: .rounded, weight: .semibold))
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityLabel("Market session details").accessibilityValue(expanded ? "Expanded" : "Collapsed")
                Button { alerts = true } label: {
                    Image(systemName: "bell.badge").font(.subheadline).frame(width: 42, height: 42)
                }.buttonStyle(.plain).accessibilityLabel("Market alerts")
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(symbols.enumerated()), id: \.element) { index, symbol in
                    let quote = displayedQuote(symbol, index: index, now: now)
                    Button { onQuote(symbol) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(["S&P 500", open ? "Nasdaq" : "Nasdaq 100", "Russell 2000"][index]).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            Text(quote.map { String(format: "%+.2f%%", $0.change) } ?? "—")
                                .font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(quote.map { $0.change >= 0 ? Color.green : Color.red } ?? Color.secondary)
                            if let quote, quote.points.count > 1 {
                                Chart(Array(quote.points.enumerated()), id: \.offset) { point in
                                    LineMark(x: .value("Time", point.offset), y: .value("Price", point.element))
                                        .foregroundStyle(quote.change >= 0 ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
                                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                                }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false)).frame(height: 23).accessibilityHidden(true)
                            } else {
                                Rectangle().fill(.quaternary).frame(height: 1).frame(height: 23)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityLabel("\(symbol) quote")
                }
            }
            HStack(spacing: 5) {
                Image(systemName: open ? "clock" : scheduled ? "moon.stars" : "pause.circle")
                Text(quoteStatus(symbols: symbols, now: now, open: open, scheduled: scheduled))
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Divider().opacity(0.5)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(open ? "Closing bell" : "Opening bell").font(.subheadline).foregroundStyle(.secondary)
                    let target = open ? MarketClock.session(on: now)!.end : MarketClock.nextOpen(after: now)
                    Text(countdown(to: target, now: now)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer()
                let target = open ? MarketClock.session(on: now)!.end : MarketClock.nextOpen(after: now)
                Text(target, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.subheadline.weight(.medium)).monospacedDigit()
            }
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if fixture == nil, let lastVisit = store.lastVisit {
                        let arrivals = FeedStore.shared.stories.filter { $0.receivedAt > lastVisit }.count
                        if arrivals > 0 {
                            Label("\(arrivals) new headlines since your last visit", systemImage: "newspaper")
                        }
                        if let quote = store.quotes[symbols[0]], let previous = store.previousQuotes[symbols[0]], previous.price > 0, quote.at > previous.at {
                            Text("\(open ? "S&P 500" : "S&P futures") \(String(format: "%+.2f%%", (quote.price / previous.price - 1) * 100)) since your last visit.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !open && !scheduled {
                        Label("Futures scheduled to resume \(MarketClock.futuresReopen(after: now).formatted(.dateTime.weekday(.abbreviated).hour().minute()))", systemImage: "moon.stars")
                        Text("Holiday hours may differ. Fresh quotes confirm trading has resumed.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let upcoming = PulseStore.shared.current?.comingUp?.first(where: { $0.at > now }) {
                        Label(upcoming.title, systemImage: "calendar")
                        Text(upcoming.at, format: .dateTime.weekday().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    } else if fixture != nil {
                        Label("Next up · Economic calendar", systemImage: "calendar")
                        Text("Keep important releases and earnings in view before the next session.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(open ? "Index changes are measured from the previous close." : "Futures changes use the previous settlement reference. Futures prices can differ from the cash indexes.").font(.caption).foregroundStyle(.secondary)
                    Button("Set a market alert", systemImage: "bell") { alerts = true }.font(.subheadline.weight(.medium)).tint(.wireAccent)
                }.font(.subheadline).padding(.top, 2)
            }
        }
        .padding(16)
        .homeCard()
    }

    private func countdown(to target: Date, now: Date) -> String {
        let minutes = max(0, Int(ceil(target.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "In \(minutes) min" }
        if minutes < 1440 { return "In \(minutes / 60)h \(minutes % 60)m" }
        return "In \(minutes / 1440)d \((minutes % 1440) / 60)h"
    }

    private func displayedQuote(_ symbol: String, index: Int, now: Date) -> SessionQuote? {
        guard fixture != nil else { return store.quotes[symbol] }
        let changes = [0.42, -0.18, 0.67]
        let values: [Double] = [100, 100.1, 100.06, 100.2, 100.12, 100.28, 100.3, 100.22, 100.38, 100.34, 100.45, 100.42]
        return SessionQuote(id: symbol, price: 100, change: changes[index], at: now.addingTimeInterval(-120), points: index == 1 ? values.reversed() : values)
    }

    private func quoteStatus(symbols: [String], now: Date, open: Bool, scheduled: Bool) -> String {
        let times = symbols.enumerated().compactMap { displayedQuote($0.element, index: $0.offset, now: now)?.at }
        guard let oldest = times.min() else { return store.failed ? "Quotes unavailable · retrying automatically" : "Fetching quotes…" }
        let status = open ? "Cash indexes" : scheduled ? "Futures" : "Futures paused"
        let stamp = now.timeIntervalSince(oldest) > 86400 ? oldest.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : oldest.formatted(.dateTime.hour().minute())
        return "\(status) · \(times.count < symbols.count ? "Partial · " : "")\(now.timeIntervalSince(oldest) > 300 ? "Stale · " : "")\(stamp)"
    }
}

#if DEBUG
struct MarketSessionPreview: View {
    @State private var session = "premarket"
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Picker("Session", selection: $session) {
                        Text("Overnight").tag("overnight")
                        Text("Pre-open").tag("premarket")
                        Text("Open").tag("open")
                        Text("Closed").tag("closed")
                    }.pickerStyle(.segmented)
                    MarketSessionCard(fixture: session).id(session)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("YOUR WIRE").font(.system(.caption, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                        Text("A little more context before the next move.").font(.title2.weight(.semibold))
                        Text("The market card stays in the same place as the trading day changes. Tap its title for context, or the bell to build an alert.").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.padding(16)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Oct 19").navigationSubtitle("Market session preview")
        }.scrollEdgeEffectStyle(.soft, for: .all)
    }
}
#endif
