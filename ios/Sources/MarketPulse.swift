import Charts
import SwiftUI

nonisolated struct MarketPulse: Decodable, Sendable {
    let symbol: String
    let score: Double?
    let status: String
    let confidence: String
    let asOf: Date
    let horizon: String?
    let predictive: Bool?
    let components: Components
    let factors: [Factor]
    let coverage: Coverage
    let history: [Point]?
    let call: Call?
    let summary: String?
    let drivers: [Driver]?
    let comingUp: [Upcoming]?
    let learning: Learning?

    struct Learning: Decodable, Sendable {
        let model: String
        let adjustment: Double
        let settled: Int
        let sameHorizon: Int
        let sessions: Int
        let note: String
    }

    struct Call: Decodable, Sendable {
        let headline: String
        let tone: String
        let strength: Int
    }
    struct Stat: Decodable, Sendable {
        let label: String
        let value: String
        let change: String
    }
    struct Driver: Decodable, Sendable, Identifiable {
        let kind: String
        let effect: String
        let points: Double
        let title: String
        let detail: String
        let storyId: String?
        let stat: Stat?
        let url: URL?
        let source: String?
        let at: Date?
        let more: Int?
        var id: String { kind + title }
    }
    struct Upcoming: Decodable, Sendable, Identifiable {
        let title: String
        let at: Date
        let detail: String
        let timing: String?
        var id: String { title + at.description }

        var when: String {
            let calendar = Calendar.current
            let day = calendar.isDateInToday(at) ? "Today" : calendar.isDateInTomorrow(at) ? "Tomorrow" : at.formatted(.dateTime.weekday(.wide))
            return "\(day) \(timing ?? "at \(at.formatted(date: .omitted, time: .shortened))")"
        }
    }

    struct Components: Decodable, Sendable {
        let news: News
        let market: Market?
        let calendar: CalendarPart?
    }
    struct CalendarPart: Decodable, Sendable {
        let points: Double
        let released: [Release]
        let upcoming: [Scheduled]
    }
    struct Release: Decodable, Sendable, Identifiable {
        let title: String
        let at: Date
        let forecast: String?
        let actual: String?
        let surprise: Double?
        let points: Double
        var id: String { title + at.description }
    }
    struct Scheduled: Decodable, Sendable, Identifiable {
        let title: String
        let at: Date
        let forecast: String?
        var id: String { title + at.description }
    }
    struct News: Decodable, Sendable {
        let status: String
        let points: Double
    }
    struct Market: Decodable, Sendable {
        let status: String
        let points: Double
        let inputs: [Input]
    }
    struct Input: Decodable, Sendable, Identifiable {
        let id: String
        let label: String
        let unit: String
        let status: String
        let reason: String
        let price: Double?
        let priceAt: Date?
        let changeDay: Double?
        let changeHour: Double?
        let points: Double
    }
    struct Factor: Decodable, Sendable {
        let factor: String
        let points: Double
        let evidence: [Evidence]
    }
    struct Evidence: Decodable, Sendable, Identifiable {
        let storyId: String
        let title: String
        let source: String
        let url: URL
        let receivedAt: Date
        let reason: String
        let independentSources: Int?
        var id: String { storyId }
    }
    struct Coverage: Decodable, Sendable {
        let headlineStories: Int
        let matchedStories: Int
        let latestHeadlineAt: Date?
    }
    struct Point: Decodable, Sendable, Identifiable {
        let asOf: Date
        let score: Double?
        var id: Date { asOf }
    }

    var evidence: [(factor: String, points: Double, item: Evidence)] {
        factors.flatMap { factor in factor.evidence.map { (factor.factor, factor.points, $0) } }
    }
}

extension NewswireAPI {
    @concurrent func marketPulse(symbol: String, historyHours: Int = 12) async throws -> MarketPulse {
        var components = URLComponents(url: baseURL.appending(path: "v1/market-pulse"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "symbol", value: symbol), URLQueryItem(name: "history", value: String(historyHours))]
        guard let url = components?.url else { throw WireError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw WireError.status(response.statusCode) }
        return try Self.decoder().decode(MarketPulse.self, from: data)
    }
}

@Observable final class PulseStore {
    static let shared = PulseStore()
    static let symbols = ["SPY", "QQQ", "XLE", "DAL"]
    static let names = ["SPY": "S&P 500", "QQQ": "Tech", "XLE": "Energy", "DAL": "Airlines"]

    var symbol = UserDefaults.standard.string(forKey: "pulseSymbol").flatMap { symbols.contains($0) ? $0 : nil } ?? "SPY" {
        didSet { UserDefaults.standard.set(symbol, forKey: "pulseSymbol") }
    }
    private(set) var snapshots: [String: MarketPulse] = [:]
    private(set) var failed = false
    private var loadedAt: [String: Date] = [:]

    var current: MarketPulse? { snapshots[symbol] }

    /// Prices move by the minute, so a snapshot older than about a minute is refetched; the server caches bars for 60 seconds.
    func refresh(force: Bool = false) async {
        let symbol = symbol
        #if DEBUG
        if CommandLine.arguments.contains("-pulseSample") { loadSample(symbol); return }
        #endif
        if !force, let at = loadedAt[symbol], at.timeIntervalSinceNow > -55 { return }
        guard let url = NewswireAPI.validatedURL(FeedStore.shared.serverURL) else { return }
        do {
            let pulse = try await NewswireAPI(baseURL: url).marketPulse(symbol: symbol)
            snapshots[symbol] = pulse
            loadedAt[symbol] = .now
            failed = false
        } catch {
            if !Task.isCancelled { failed = snapshots[symbol] == nil }
        }
    }

    #if DEBUG
    private func loadSample(_ symbol: String) {
        let json = #"{"model":"market-pulse-v2.1","as_of":"2026-10-13T02:07:20.644Z","symbol":"SPY","horizon":"next open","predictive":true,"score":37.99,"research_score":37.99,"status":"available","outlook":"headwinds","confidence":"medium","components":{"news":{"status":"available","points":-1.83,"method":"jev","classified":3,"channels":[{"channel":"growth","points":0.72,"stories":1,"top":[{"id":"15a3d9bc40662d8c8a69dc814cf4bc78efb2f75d57015408367953794a4a4ec8","title":"Global economy to slow less than expected in 2026 as AI boom offsets war hit: IMF","source":"CNBC","url":"https://www.cnbc.com/2026/10/12/imf-world-bank-annual-meetings-october-bangkok-asia-.html","published_at":"2026-10-13T02:01:01.000Z","received_at":"2026-10-13T02:05:42.956Z","direction":1,"channel":"growth","size":"minor","confidence":0.92,"classified_at":"2026-10-13T02:07:11.565Z","weight":0.18,"exposure":1}]},{"channel":"geopolitics","points":-2.55,"stories":2,"top":[{"id":"4b6571fd427a9b4456332924fc9c08275f5fed4fb3696efa4d655fdd5a8e9e21","title":"I.M.F. Warns Mideast War Will Widen Gap Between Rich and Poor Countries","source":"New York Times","url":"https://www.nytimes.com/2026/10/12/business/economy/imf-global-economic-outlook.html","published_at":"2026-10-13T02:00:07.000Z","received_at":"2026-10-13T02:05:42.956Z","direction":-1,"channel":"geopolitics","size":"moderate","confidence":0.73,"classified_at":"2026-10-13T02:07:11.565Z","weight":-0.36,"exposure":1},{"id":"cd0691437c90819891d2cbb1cc7ae2b123ae61e4ac14e6eb2d3f7b768805bcc2","title":"IMF warns of fractured global growth and rising inflation driven by the Iran war and AI build-out","source":"Yahoo Finance Singapore","url":"https://news.google.com/rss/articles/CBMi3wFBVV95cUxQSzQtdTVycm1yZFVpMlJ1WjFwLTgya3RDWXpsLTdQSTlCZTI2UU0zbmdiRHFlbFRKZVh2ZHlmZ25jRlFXR1RDaW1ISFVJZ1hIeXg1M0ZJS1VHTnc1cm85dGlnaDFNRW5BVm9uMGJXdE11dGR0aGtSaGg5LXFKUGdoTGtDbmxVRGtaSmVkREFfWHV3NDVla21OTXhheHBwVlFoSlJGODMxRUNzSFpCcUpfR1Z3c3hfb3RVR0ZhMVpfS1hZQUxibDJsaUUzZ3FLSmNQYlZZWnBwTWlLQmNZcnA4?oc=5","published_at":"2026-10-13T02:00:00.000Z","received_at":"2026-10-13T02:02:23.362Z","direction":-1,"channel":"geopolitics","size":"moderate","confidence":0.65,"classified_at":"2026-10-13T02:07:11.565Z","weight":-0.32,"exposure":1}]}]},"market":{"status":"available","live_inputs":8,"points":-10.18,"inputs":[{"id":"futures","label":"S&P 500 futures","symbol":"ES=F","unit":"pct","price":7841.5,"price_at":"2026-10-13T01:57:16.000Z","change_day":-0.51,"change_hour":-0.05,"status":"live","exposure":1,"reason":"Overnight and intraday futures direction","points":-3.27},{"id":"oil","label":"WTI crude","symbol":"CL=F","unit":"pct","price":92.54,"price_at":"2026-10-13T01:57:09.000Z","change_day":2.8,"change_hour":-0.46,"status":"live","exposure":1,"reason":"Rising crude raises costs; falling crude eases them","points":-3.32},{"id":"vix","label":"VIX","symbol":"^VIX","unit":"pct","price":15.21,"price_at":"2026-10-12T20:15:01.000Z","change_day":2.49,"change_hour":0,"status":"stale","exposure":1,"reason":"Rising implied volatility reflects demand for protection","points":0},{"id":"yen","label":"USD/JPY","symbol":"JPY=X","unit":"pct","price":158.308,"price_at":"2026-10-13T02:07:18.000Z","change_day":0.09,"change_hour":-0.08,"status":"live","exposure":1,"reason":"A fast yen rally signals carry-trade unwinding and risk reduction","points":-0.06},{"id":"yield","label":"US 10Y yield","symbol":"^TNX","unit":"bp","price":5.24,"price_at":"2026-10-12T18:59:53.000Z","change_day":-0.4,"change_hour":0,"status":"stale","exposure":1,"reason":"Rising long yields tighten financial conditions and pressure valuations","points":0},{"id":"credit","label":"High-yield bonds (HYG)","symbol":"HYG","unit":"pct","price":77.29,"price_at":"2026-10-12T20:00:00.000Z","change_day":0.08,"change_hour":0.05,"status":"stale","exposure":1,"reason":"Falling junk-bond prices signal credit stress","points":0},{"id":"dollar","label":"US dollar index","symbol":"DX-Y.NYB","unit":"pct","price":102.444,"price_at":"2026-10-13T01:57:19.000Z","change_day":0.3,"change_hour":-0.04,"status":"live","exposure":1,"reason":"A sharply stronger dollar tightens global financial conditions and hurts overseas earnings","points":-1.22},{"id":"europe","label":"Euro Stoxx 50","symbol":"^STOXX50E","unit":"pct","price":6201.21,"price_at":"2026-10-12T16:00:00.000Z","change_day":0.39,"change_hour":0.08,"status":"live","exposure":1,"reason":"Europe's session leads the US open","points":1.32},{"id":"asia","label":"Nikkei 225","symbol":"^N225","unit":"pct","price":67242.9,"price_at":"2026-10-13T01:52:15.000Z","change_day":-2.6,"change_hour":-0.24,"status":"live","exposure":1,"reason":"Asia's session sets the overnight tone","points":-2.48},{"id":"copper","label":"Copper","symbol":"HG=F","unit":"pct","price":6.71,"price_at":"2026-10-13T01:57:18.000Z","change_day":-0.39,"change_hour":-0.25,"status":"live","exposure":1,"reason":"Copper tracks expectations for global industrial demand","points":-0.95},{"id":"bitcoin","label":"Bitcoin","symbol":"BTC-USD","unit":"pct","price":82407.68,"price_at":"2026-10-13T02:07:18.000Z","change_day":-1.43,"change_hour":1.14,"status":"live","exposure":1,"reason":"Trades around the clock, so it carries risk appetite through weekends","points":-0.2}]},"calendar":{"points":0,"released":[],"upcoming":[]}},"coverage":{"window_start":"2026-10-09T02:07:20.644Z","eligible_stories":312,"headline_stories":294,"matched_stories":0,"event_groups":0,"latest_headline_at":"2026-10-13T02:00:00.000Z","headline_age_hours":0.12,"truncated":false},"factors":[{"factor":"energy","points":0,"exposure":1,"conflicting":false,"evidence":[]},{"factor":"trade","points":0,"exposure":1,"conflicting":false,"evidence":[]},{"factor":"rates","points":0,"exposure":1,"conflicting":false,"evidence":[]},{"factor":"growth","points":0,"exposure":1,"conflicting":false,"evidence":[]},{"factor":"credit","points":0,"exposure":1,"conflicting":false,"evidence":[]}],"limitations":["Uncalibrated research index; not a probability or expected return.","Conservative headline rules cover only explicit macro events; unmatched stories are unclassified, not neutral.","Price inputs are delayed Yahoo Finance quotes scored by fixed rules; they describe current conditions, not a forecast of returns.","Historical calculations use current model rules with point-in-time news; they were not predictions saved at the time."],"call":{"headline":"Expect a lower open","tone":"negative","strength":2},"summary":"Oil is up 2.8% since yesterday and stock futures are down 0.5% overnight, which point to weaker stocks at the open.","drivers":[{"kind":"price","effect":"lower","points":-3.32,"title":"Oil is up 2.8% since yesterday","detail":"Higher fuel costs squeeze company profits and consumer spending.","stat":{"label":"WTI crude, per barrel","value":"$92.54","change":"+2.80%"}},{"kind":"price","effect":"lower","points":-3.27,"title":"Stock futures are down 0.5% overnight","detail":"Traders are already selling ahead of the open.","stat":{"label":"S&P 500 futures","value":"7,842","change":"\u22120.51%"}},{"kind":"news","effect":"lower","points":-2.55,"title":"I.M.F. Warns Mideast War Will Widen Gap Between Rich and Poor Countries","channel":"geopolitics","detail":"Read as bad for stocks through conflict and geopolitics.","url":"https://www.nytimes.com/2026/10/12/business/economy/imf-global-economic-outlook.html","source":"New York Times","at":"2026-10-13T02:00:07.000Z","more":1},{"kind":"price","effect":"lower","points":-2.48,"title":"Japanese stocks are down 2.6%","detail":"Asia sets the overnight mood before Europe and the US open.","stat":{"label":"Nikkei 225","value":"67,243","change":"\u22122.60%"}},{"kind":"price","effect":"higher","points":1.32,"title":"European stocks closed up 0.4%","detail":"Europe trades first, and the US often follows its lead.","stat":{"label":"Euro Stoxx 50","value":"6,201","change":"+0.39%"}},{"kind":"price","effect":"lower","points":-1.22,"title":"The dollar is up 0.30%","detail":"A stronger dollar shrinks US companies' overseas sales.","stat":{"label":"Dollar index","value":"102.44","change":"+0.30%"}},{"kind":"price","effect":"lower","points":-0.95,"title":"Copper is down 0.4%","detail":"Falling copper hints at slowing global demand.","stat":{"label":"Copper, per pound","value":"$6.71","change":"\u22120.39%"}},{"kind":"news","effect":"higher","points":0.72,"title":"Global economy to slow less than expected in 2026 as AI boom offsets war hit: IMF","channel":"growth","detail":"Read as good for stocks through the economy.","url":"https://www.cnbc.com/2026/10/12/imf-world-bank-annual-meetings-october-bangkok-asia-.html","source":"CNBC","at":"2026-10-13T02:01:01.000Z","more":0}],"coming_up":[{"title":"CPI","at":"2026-10-14T12:30:00.000Z","detail":"CPI m/m forecast 0.6%. A surprise here can outweigh everything above."},{"title":"ASML earnings","at":"2026-10-14T12:30:00.000Z","timing":"before the open","detail":"Expected EPS 10.76. Big enough to move tech stocks on its own."}],"history":[{"as_of":"2026-10-12T14:30:00.000Z","score":42.81,"news_points":0,"market_points":-7.19,"calendar_points":0},{"as_of":"2026-10-12T15:00:00.000Z","score":44.42,"news_points":0,"market_points":-5.58,"calendar_points":0},{"as_of":"2026-10-12T15:30:00.000Z","score":45.43,"news_points":0,"market_points":-4.57,"calendar_points":0},{"as_of":"2026-10-12T16:00:00.000Z","score":45.71,"news_points":0,"market_points":-4.29,"calendar_points":0},{"as_of":"2026-10-12T16:30:00.000Z","score":44.56,"news_points":0,"market_points":-5.44,"calendar_points":0},{"as_of":"2026-10-12T17:00:00.000Z","score":42.19,"news_points":0,"market_points":-7.81,"calendar_points":0},{"as_of":"2026-10-12T17:30:00.000Z","score":44.26,"news_points":0,"market_points":-5.74,"calendar_points":0},{"as_of":"2026-10-12T18:00:00.000Z","score":45.31,"news_points":0,"market_points":-4.69,"calendar_points":0},{"as_of":"2026-10-12T18:30:00.000Z","score":42.86,"news_points":0,"market_points":-7.14,"calendar_points":0},{"as_of":"2026-10-12T19:00:00.000Z","score":41.94,"news_points":0,"market_points":-8.06,"calendar_points":0},{"as_of":"2026-10-12T19:30:00.000Z","score":43.26,"news_points":0,"market_points":-6.74,"calendar_points":0},{"as_of":"2026-10-12T20:00:00.000Z","score":48.03,"news_points":0,"market_points":-1.97,"calendar_points":0},{"as_of":"2026-10-12T20:30:00.000Z","score":48.13,"news_points":0,"market_points":-1.87,"calendar_points":0},{"as_of":"2026-10-12T21:00:00.000Z","score":46.91,"news_points":0,"market_points":-3.09,"calendar_points":0},{"as_of":"2026-10-12T21:30:00.000Z","score":46.41,"news_points":0,"market_points":-3.59,"calendar_points":0},{"as_of":"2026-10-12T22:00:00.000Z","score":45.36,"news_points":0,"market_points":-4.64,"calendar_points":0},{"as_of":"2026-10-12T22:30:00.000Z","score":45.51,"news_points":0,"market_points":-4.49,"calendar_points":0},{"as_of":"2026-10-12T23:00:00.000Z","score":42.23,"news_points":0,"market_points":-7.77,"calendar_points":0},{"as_of":"2026-10-12T23:30:00.000Z","score":41.41,"news_points":0,"market_points":-8.59,"calendar_points":0},{"as_of":"2026-10-13T00:00:00.000Z","score":42.19,"news_points":0,"market_points":-7.81,"calendar_points":0},{"as_of":"2026-10-13T00:30:00.000Z","score":38.26,"news_points":0,"market_points":-11.74,"calendar_points":0},{"as_of":"2026-10-13T01:00:00.000Z","score":36.08,"news_points":0,"market_points":-13.92,"calendar_points":0},{"as_of":"2026-10-13T01:30:00.000Z","score":39.41,"news_points":0,"market_points":-10.59,"calendar_points":0},{"as_of":"2026-10-13T02:00:00.000Z","score":40.32,"news_points":0,"market_points":-9.68,"calendar_points":0},{"as_of":"2026-10-13T02:07:20.644Z","score":37.99,"news_points":-1.83,"market_points":-10.18,"calendar_points":0}]}"#
        snapshots[symbol] = try? NewswireAPI.decoder().decode(MarketPulse.self, from: Data(json.utf8))
    }
    #endif
}

nonisolated enum PulseFormat {
    static func change(_ value: Double?, unit: String) -> String {
        guard var value else { return "—" }
        value = unit == "bp" ? value.rounded() : (value * 100).rounded() / 100
        let sign = value > 0 ? "+" : value < 0 ? "\u{2212}" : ""
        return unit == "bp" ? "\(sign)\(abs(value).formatted(.number.precision(.fractionLength(0)))) bp" : "\(sign)\(abs(value).formatted(.number.precision(.fractionLength(2))))%"
    }

    static func price(_ input: MarketPulse.Input) -> String {
        guard let price = input.price else { return "—" }
        if input.unit == "bp" { return price.formatted(.number.precision(.fractionLength(2))) + "%" }
        return price.formatted(.number.precision(.fractionLength(price >= 1000 ? 0 : 2)))
    }

    static func when(_ pulse: MarketPulse) -> String {
        pulse.horizon == "next open" ? "before the open" : "during the session"
    }
}

extension MarketPulse {
    var tint: Color {
        switch call?.tone {
        case "negative": .red
        case "positive": .green
        default: .secondary
        }
    }
    var arrow: String {
        switch call?.tone {
        case "negative": "arrow.down.right"
        case "positive": "arrow.up.right"
        default: "arrow.left.and.right"
        }
    }
}

/// A lower-to-higher track with a marker, so the reading needs no number.
struct PulseGauge: View {
    let score: Double?
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let position = min(max(((score ?? 50) - 25) / 50, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [.red.opacity(0.55), .secondary.opacity(0.25), .green.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                    Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: 10).offset(x: proxy.size.width / 2)
                    Circle().fill(tint == .secondary ? Color.primary : tint).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .offset(x: position * (proxy.size.width - 14))
                        .opacity(score == nil ? 0 : 1)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            HStack {
                Text("Lower")
                Spacer()
                Text("Higher")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

struct PulseSparkline: View {
    let points: [MarketPulse.Point]

    var body: some View {
        let scored = points.compactMap { point in point.score.map { (point.asOf, $0) } }
        let low = min(scored.map(\.1).min() ?? 45, 45) - 2, high = max(scored.map(\.1).max() ?? 55, 55) + 2
        Chart {
            RuleMark(y: .value("Neutral", 50)).foregroundStyle(.secondary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            ForEach(scored, id: \.0) { time, score in
                LineMark(x: .value("Time", time), y: .value("Score", score)).interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: low...high)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in AxisValueLabel(format: .dateTime.hour()) }
        }
        .chartYAxis(.hidden)
        .foregroundStyle(Color.wireAccent)
        .accessibilityHidden(true)
    }
}

struct PulseCard: View {
    @State private var store = PulseStore.shared
    @State private var macro = MacroStore.shared
    @State private var showing = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Button { showing = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Market outlook · \(PulseStore.names[store.symbol] ?? store.symbol)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let pulse = store.current { Text(PulseFormat.when(pulse)).font(.caption).foregroundStyle(.secondary) }
                }
                if let pulse = store.current {
                    HStack(spacing: 8) {
                        Image(systemName: pulse.arrow).font(.title3.weight(.bold))
                        Text(pulse.call?.headline ?? "Outlook unavailable").font(.title3.weight(.semibold)).lineLimit(2)
                    }
                    .foregroundStyle(pulse.tint)
                    if let summary = pulse.summary {
                        Text(summary).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineLimit(2)
                    }
                    if let macroLine { Text(macroLine).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    PulseGauge(score: pulse.score, tint: pulse.tint)
                } else {
                    if store.failed {
                        Text("Couldn't load the market outlook.")
                            .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    } else {
                        PulseCardSkeleton()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 184, maxHeight: 184, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(PressSpringStyle())
        .homeCard()
        .animation(.easeOut(duration: 0.25), value: store.current?.score)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows what is moving the market")
        .sheet(isPresented: $showing) { PulseDetail() }
        #if DEBUG
        .onAppear { if CommandLine.arguments.contains("-openPulse") { showing = true } }
        #endif
        .task(id: "\(store.symbol)-\(phase == .active)") {
            guard phase == .active else { return }
            #if DEBUG
            if CommandLine.arguments.contains("-pulseLoading") { return }
            #endif
            await macro.refresh()
            while !Task.isCancelled {
                await store.refresh()
                await macro.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private var macroLine: String? {
        var items: [String] = []
        if let meeting = macro.nextMeeting, let date = MacroText.meetingDate(meeting.label) {
            items.append("Fed \(MacroText.countdown(to: date).lowercased())")
        }
        if let cpi = macro.cpi { items.append("CPI \(cpi.value)") }
        if let rate = macro.unemployment { items.append("Unemployment \(rate.value)") }
        return items.isEmpty ? nil : items.joined(separator: " · ")
    }
}

private struct PulseCardSkeleton: View {
    private let tint = Color.secondary.opacity(0.14)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                bar(width: 130, height: 12)
                Spacer()
                bar(width: 48, height: 11)
            }
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 20, height: 20)
                bar(width: 205, height: 20)
            }
            VStack(alignment: .leading, spacing: 6) {
                bar(width: .infinity, height: 12)
                bar(width: 230, height: 12)
            }
            VStack(spacing: 4) {
                Capsule().fill(tint).frame(height: 6)
                HStack {
                    bar(width: 28, height: 9)
                    Spacer()
                    bar(width: 32, height: 9)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2).fill(tint).frame(width: width.isFinite ? width : nil, height: height)
    }
}

struct PulseDetail: View {
    @State private var store = PulseStore.shared
    @State private var macro = MacroStore.shared
    @State private var reading: Story?
    @State private var showingResearch = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    Picker("Market", selection: $store.symbol) {
                        ForEach(PulseStore.symbols, id: \.self) { Text(PulseStore.names[$0] ?? $0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if let pulse = store.current {
                    Section { hero(pulse) }
                    if let learning = pulse.learning {
                        Section("Learning as it goes") {
                            Text(learning.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    macroContext
                    let drivers = pulse.drivers ?? []
                    if let lead = drivers.first {
                        Section("Biggest factor") { featured(lead) }
                    }
                    let lower = drivers.dropFirst().filter { $0.effect == "lower" }, higher = drivers.dropFirst().filter { $0.effect == "higher" }
                    if !lower.isEmpty { Section("Also pushing prices lower") { ForEach(lower) { driver($0) } } }
                    if !higher.isEmpty { Section("Pushing prices higher") { ForEach(higher) { driver($0) } } }
                    if let coming = pulse.comingUp, !coming.isEmpty {
                        Section("Coming up") {
                            ForEach(coming) { event in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "calendar").foregroundStyle(Color.wireAccent).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.title).font(.subheadline.weight(.medium))
                                        Text(event.when).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                        Text(event.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .id("comingUp")
                    }
                    if let history = pulse.history, history.count > 1 {
                        Section {
                            PulseSparkline(points: history).frame(height: 120).padding(.vertical, 6)
                        } header: {
                            Text("Last 12 hours")
                        } footer: {
                            Text("Above the dotted line leans higher; below leans lower.")
                        }
                    }
                    if let inputs = pulse.components.market?.inputs {
                        Section {
                            DisclosureGroup("All market inputs") {
                                ForEach(inputs) { input in row(input) }
                            }
                        } footer: {
                            Text("Combines current price moves, classified headlines, economic data and results from the biggest companies. SPY and QQQ adjust from completed forecasts as results arrive. This experimental index is not a probability; saved forecasts show how it actually performed.")
                        }
                    }
                } else {
                    Section {
                        Text(store.failed ? "Couldn't load the market outlook." : "Loading…").foregroundStyle(.secondary)
                        if store.failed {
                            Button("Retry", systemImage: "arrow.clockwise") { Task { await store.refresh(force: true) } }
                        }
                    }
                }
            }
            .onChange(of: store.current?.asOf) {
                if CommandLine.arguments.contains("-pulseComingUp") { proxy.scrollTo("comingUp", anchor: .top) }
            }
            }
            .navigationTitle("Market outlook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingResearch = true } label: { Label("Research", systemImage: "doc.text.magnifyingglass") }
                        .accessibilityHint("View frozen forecasts and measured performance")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showingResearch) { MarketResearchView() }
            .refreshable { await store.refresh(force: true) }
            .task(id: "\(store.symbol)-\(phase == .active)") {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    await macro.refresh()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
            .navigationDestination(item: $reading) { StoryDetail(story: $0) }
        }
        .presentationDetents([.large])
    }

    private var macroContext: some View {
        Section("Economic context") {
            if let meeting = macro.nextMeeting {
                let date = MacroText.meetingDate(meeting.label)
                LabeledContent("Next Fed decision", value: date.map { MacroText.countdown(to: $0) } ?? meeting.label)
                if let range = MacroText.targetRange(macro.fed?.note) {
                    Text("Rates are \(range) today.").font(.caption).foregroundStyle(.secondary)
                }
                let odds = MacroText.fedOdds(meeting.detail)
                if !odds.isEmpty { Text(odds).font(.caption).foregroundStyle(.secondary) }
            }
            if macro.cpi != nil || macro.unemployment != nil || macro.payrolls != nil {
                HStack(spacing: 0) {
                    if let cpi = macro.cpi { macroStat("Inflation", cpi.value, date: cpi.date) }
                    if let rate = macro.unemployment { macroStat("Unemployment", rate.value, date: rate.date) }
                    if let jobs = macro.payrolls { macroStat("Jobs added", jobs.value.replacingOccurrences(of: " K", with: "K"), date: jobs.date) }
                }
                .padding(.vertical, 4)
            }
            if let surprise = macro.latestSurprise {
                LabeledContent("Latest release") { Text(MacroText.surprise(surprise)).multilineTextAlignment(.trailing) }
            }
            if macro.nextMeeting == nil && macro.cpi == nil && macro.unemployment == nil && macro.payrolls == nil && macro.latestSurprise == nil {
                Text("Loading economic data…").foregroundStyle(.secondary)
            }
        }
    }

    private func macroStat(_ title: String, _ value: String, date: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            Text(MacroText.month(date)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hero(_ pulse: MarketPulse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: pulse.arrow).font(.title.weight(.bold))
                Text(pulse.call?.headline ?? "Outlook unavailable").font(.title2.weight(.bold))
            }
            .foregroundStyle(pulse.tint)
            if let summary = pulse.summary { Text(summary).font(.body).fixedSize(horizontal: false, vertical: true) }
            PulseGauge(score: pulse.score, tint: pulse.tint)
            Text("\(PulseFormat.when(pulse).prefix(1).uppercased() + PulseFormat.when(pulse).dropFirst()) · updated \(pulse.asOf.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "news": "newspaper"
        case "data": "chart.bar.doc.horizontal"
        default: "chart.xyaxis.line"
        }
    }

    private func color(_ effect: String) -> Color { effect == "lower" ? .red : .green }

    private func featured(_ item: MarketPulse.Driver) -> some View {
        Button { open(item) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Label(item.effect == "lower" ? "Pushing prices lower" : "Pushing prices higher", systemImage: item.effect == "lower" ? "arrow.down" : "arrow.up")
                    .font(.caption.weight(.semibold)).foregroundStyle(color(item.effect))
                Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let stat = item.stat {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(stat.value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(stat.change).font(.headline).monospacedDigit().foregroundStyle(stat.change.hasPrefix("Expected") ? .secondary : color(item.effect))
                    }
                    Text(stat.label).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let name = item.source { sourceLine(name, item) }
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func sourceLine(_ name: String, _ item: MarketPulse.Driver) -> some View {
        HStack(spacing: 6) {
            Text([name, item.at.map { $0.formatted(.relative(presentation: .named)) }, (item.more ?? 0) > 0 ? "+\(item.more!) related" : nil].compactMap { $0 }.joined(separator: " · "))
            if item.url != nil { Image(systemName: "arrow.up.right.square") }
        }
        .font(.caption).foregroundStyle(Color.wireAccent)
    }

    private func driver(_ item: MarketPulse.Driver) -> some View {
        Button { open(item) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon(item.kind)).foregroundStyle(color(item.effect)).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let name = item.source { sourceLine(name, item) }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func row(_ input: MarketPulse.Input) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(input.label).font(.subheadline)
                Text(input.status == "live" ? PulseFormat.price(input) : input.status == "stale" ? "Closed · last \(PulseFormat.price(input))" : "No data")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Text(PulseFormat.change(input.changeDay, unit: input.unit))
                .font(.subheadline).monospacedDigit()
                .foregroundStyle(input.status == "live" ? QuoteFormat.color(input.changeDay ?? 0) : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func open(_ item: MarketPulse.Driver) {
        guard item.kind == "news", let url = item.url else { return }
        Task {
            reading = await FeedStore.shared.resolveStory(storyID: item.storyId, url: url, title: item.title, source: item.source ?? url.host() ?? "News", publishedAt: item.at ?? .now)
        }
    }
}
