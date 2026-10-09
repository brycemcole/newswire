import SwiftUI

@Observable final class MacroStore {
    static let shared = MacroStore()
    private(set) var calendar: DataPayload?
    private(set) var fed: DataPayload?
    private(set) var releases: DataPayload?
    private(set) var inflation: DataPayload?
    private(set) var jobs: DataPayload?
    private var loadedAt: Date?

    func refresh(force: Bool = false) async {
        #if DEBUG
        if CommandLine.arguments.contains("-macroSample") { loadSample(); return }
        #endif
        if !force, let loadedAt, loadedAt.timeIntervalSinceNow > -600 { return }
        if loadedAt == nil, fed == nil { await restore() }
        guard let url = NewswireAPI.validatedURL(FeedStore.shared.serverURL) else { return }
        let api = NewswireAPI(baseURL: url)
        let routes = Self.routes
        async let calendar = try? api.data(routes.calendar)
        async let fed = try? api.data(routes.fed)
        async let releases = try? api.data(routes.releases)
        async let inflation = try? api.data(routes.inflation)
        async let jobs = try? api.data(routes.jobs)
        let (c, f, r, i, j) = await (calendar, fed, releases, inflation, jobs)
        guard !Task.isCancelled else { return }
        if let c { self.calendar = c }
        if let f { self.fed = f }
        if let r { self.releases = r }
        if let i { self.inflation = i }
        if let j { self.jobs = j }
        if c != nil || f != nil { loadedAt = .now }
    }

    static let routes = (calendar: DataRoute("calendar", ["impact": "high", "days": "7", "upcoming": "true"]), fed: DataRoute("fed/odds"),
                         releases: DataRoute("releases", ["impact": "high", "days": "3"]), inflation: DataRoute("macro", ["group": "inflation"]),
                         jobs: DataRoute("macro", ["group": "jobs"]))

    /// Shows the last values at once; FRED figures change monthly and the calendar weekly, so they are right until the refresh lands.
    private func restore() async {
        let routes = Self.routes
        async let c = DataCache.load(routes.calendar)
        async let f = DataCache.load(routes.fed)
        async let r = DataCache.load(routes.releases)
        async let i = DataCache.load(routes.inflation)
        async let j = DataCache.load(routes.jobs)
        let (calendar, fed, releases, inflation, jobs) = await (c, f, r, i, j)
        self.calendar = self.calendar ?? calendar?.payload
        self.fed = self.fed ?? fed?.payload
        self.releases = self.releases ?? releases?.payload
        self.inflation = self.inflation ?? inflation?.payload
        self.jobs = self.jobs ?? jobs?.payload
    }

    #if DEBUG
    private func loadSample() {
        func payload(_ sections: String, note: String = "") -> DataPayload? {
            let json = #"{"title":"","source":"","url":"","as_of":"","note":"\#(note)","sections":\#(sections),"text":""}"#
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(DataPayload.self, from: Data(json.utf8))
        }
        let today = Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().locale(Locale(identifier: "en_US_POSIX")))
        let later = Date.now.addingTimeInterval(2 * 86400).formatted(.dateTime.weekday(.wide).month(.abbreviated).day().locale(Locale(identifier: "en_US_POSIX")))
        fed = payload(#"[{"title":"","rows":[{"label":"Oct 28, 2026","value":"3.930%","detail":"20% of a 25 bp hike"}]}]"#, note: "Target range 3.50–3.75%; effective rate 3.58%.")
        calendar = payload(#"[{"title":"\#(today)","rows":[{"label":"USD FOMC Meeting Minutes","value":"2:00 PM","detail":"High impact"}]},{"title":"\#(later)","rows":[{"label":"GBP BOE Gov Bailey Speaks","value":"8:15 AM","detail":"High impact"},{"label":"CAD Employment Change","value":"8:30 AM","detail":"High impact · Forecast 6.3K · Previous -2.1K","forecast":"6.3K","previous":"-2.1K"}]}]"#)
        releases = payload(#"[{"title":"","rows":[{"label":"USD ISM Services PMI","value":"51.2","actual":"51.2","forecast":"52.0","surprise":-0.8}]}]"#)
        inflation = payload(#"[{"title":"Inflation","rows":[{"label":"CPI, y/y","value":"2.9%","date":"2026-08-01","series":"CPIAUCSL"}]}]"#)
        jobs = payload(#"[{"title":"Jobs","rows":[{"label":"Nonfarm payrolls","value":"+22 K","date":"2026-09-01","series":"PAYEMS"},{"label":"Unemployment rate","value":"4.3%","date":"2026-09-01","series":"UNRATE"}]}]"#)
    }
    #endif

    var upcoming: [MacroText.Event] {
        (calendar?.sections ?? []).flatMap { section in
            section.rows.filter { $0.actual == nil && !$0.label.localizedCaseInsensitiveContains("holiday") }
                .map { MacroText.Event(day: MacroText.day(section.title), row: $0) }
        }
        .filter { ($0.day ?? .distantFuture) >= Calendar.current.startOfDay(for: .now) }
        .prefix(4).map { $0 }
    }
    var latestSurprise: DataPayload.Row? { releases?.sections.first?.rows.first { $0.actual != nil && $0.forecast != nil } }
    var nextMeeting: DataPayload.Row? { fed?.sections.first?.rows.first }
    var cpi: DataPayload.Row? { inflation?.sections.first?.rows.first { $0.series == "CPIAUCSL" && $0.value != "unavailable" } }
    var unemployment: DataPayload.Row? { jobs?.sections.first?.rows.first { $0.series == "UNRATE" && $0.value != "unavailable" } }
    var payrolls: DataPayload.Row? { jobs?.sections.first?.rows.first { $0.series == "PAYEMS" && $0.value != "unavailable" } }
}

/// Turns terse data rows into sentences a reader understands at a glance.
nonisolated enum MacroText {
    struct Event: Hashable {
        let day: Date?
        let row: DataPayload.Row
    }

    private static let flags = ["USD": "🇺🇸", "EUR": "🇪🇺", "GBP": "🇬🇧", "JPY": "🇯🇵", "CNY": "🇨🇳", "CAD": "🇨🇦", "AUD": "🇦🇺", "NZD": "🇳🇿", "CHF": "🇨🇭"]

    /// Section titles look like "Tuesday, Oct 6"; the year is whichever puts the day nearest to now.
    static func day(_ title: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let parts = title.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let monthDay = parts.last else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d yyyy"
        let year = calendar.component(.year, from: now)
        return [year, year + 1, year - 1].compactMap { formatter.date(from: "\(monthDay) \($0)") }
            .min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    static func meetingDate(_ label: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.date(from: label)
    }

    static func relativeDay(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        return days > 0 && days < 7 ? date.formatted(.dateTime.weekday(.wide)) : date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func countdown(to date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        return days <= 0 ? "Today" : days == 1 ? "Tomorrow" : "In \(days) days"
    }

    static func time(_ value: String) -> String {
        value.replacingOccurrences(of: " ET", with: "")
    }

    static func title(_ label: String) -> (flag: String, text: String) {
        let parts = label.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let flag = flags[parts[0]] else { return ("", label) }
        var text = parts[1]
        for (from, to) in [("FOMC Meeting Minutes", "Fed meeting minutes"), ("FOMC rate decision", "Fed rate decision"), ("FOMC Statement", "Fed rate decision"),
                           ("Federal Funds Rate", "Fed rate decision"), ("BOE Gov ", "Bank of England's "), ("ECB President ", "ECB's "), ("Fed Chair ", "Fed Chair "),
                           ("Non-Farm Employment Change", "Jobs report"), ("Employment Change", "jobs report"), ("Unemployment Claims", "Weekly jobless claims"),
                           (" Speaks", " speaks")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        if parts[0] != "USD", text.hasPrefix("jobs report") { text = "Jobs report" }
        return (flag, text.prefix(1).uppercased() + text.dropFirst())
    }

    static func expectation(_ row: DataPayload.Row) -> String {
        switch (row.forecast, row.previous) {
        case let (forecast?, previous?): "Expected \(forecast), last \(previous)"
        case let (forecast?, nil): "Expected \(forecast)"
        case let (nil, previous?): "Last time \(previous)"
        default: row.detail?.replacingOccurrences(of: "High impact", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " ·")) ?? ""
        }
    }

    /// "20% of a 25 bp hike" becomes "Traders see a 20% chance of a quarter-point hike."
    static func fedOdds(_ detail: String?) -> String {
        guard let detail else { return "" }
        if detail.localizedCaseInsensitiveContains("no change") { return "Traders expect rates to stay where they are." }
        guard let match = detail.firstMatch(of: /(\d+)% of a 25 bp (cut|hike)/), let odds = Int(match.1) else { return detail }
        let move = match.2 == "cut" ? "cut" : "hike"
        if detail.contains("more than one") { return "Traders expect a \(move), possibly bigger than a quarter point." }
        if odds >= 90 { return "Traders expect a quarter-point \(move)." }
        return "Traders see a \(odds)% chance of a quarter-point \(move) and \(100 - odds)% that rates hold."
    }

    static func targetRange(_ note: String?) -> String? {
        guard let note, let match = note.firstMatch(of: /Target range ([^;]+);/), !match.1.contains("unavailable") else { return nil }
        return String(match.1)
    }

    static func month(_ date: String?) -> String {
        guard let date, let day = DataFormat.date(String(date.prefix(10))) else { return "" }
        return day.formatted(.dateTime.month(.wide))
    }

    static func surprise(_ row: DataPayload.Row) -> String {
        let name = title(row.label).text
        guard let actual = row.actual else { return name }
        guard let forecast = row.forecast else { return "\(name) came in at \(actual)" }
        let comparison = row.surprise.map { $0 == 0 ? "in line with" : $0 > 0 ? "above" : "below" } ?? "versus"
        return "\(name) came in at \(actual), \(comparison) the \(forecast) expected"
    }
}

struct MarketsHome: View {
    static let symbols: [(String, String)] = [("^KS11", "KOSPI"), ("^N225", "NIKKEI"), ("^HSI", "HANG SENG"), ("^GDAXI", "DAX"), ("^FTSE", "FTSE"),
                                              ("^TNX", "US 10Y"), ("DX-Y.NYB", "DOLLAR"), ("JPY=X", "USD/JPY"), ("CL=F", "WTI"), ("GC=F", "GOLD")]
    let open: (String) -> Void
    @State private var board = MarketBoard.shared
    @State private var macro = MacroStore.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(Self.symbols, id: \.0) { symbol, label in
                            Button { open(symbol) } label: {
                                IndexCard(symbol: symbol, quote: board.quotes[symbol], spark: board.sparks[symbol], label: label)
                            }
                            .buttonStyle(PressSpringStyle())
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            outlook
        }
        .task(id: phase == .active) {
            guard phase == .active else { return }
            await macro.refresh()
            while !Task.isCancelled {
                let symbols = Self.symbols.map(\.0)
                await board.refresh(quotes: symbols, sparks: symbols)
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await macro.refresh()
            }
        }
    }

    private var outlook: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let meeting = macro.nextMeeting { fed(meeting); Divider().padding(.leading, 16) }
            if macro.cpi != nil || macro.unemployment != nil { economy; Divider().padding(.leading, 16) }
            if let surprise = macro.latestSurprise { latest(surprise); Divider().padding(.leading, 16) }
            if !macro.upcoming.isEmpty { comingUp }
            if macro.calendar == nil && macro.fed == nil {
                Text("Loading the week ahead…").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 4)
        .homeCard()
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func fed(_ meeting: DataPayload.Row) -> some View {
        let date = MacroText.meetingDate(meeting.label)
        let range = MacroText.targetRange(macro.fed?.note)
        return Button { open(DataRoute("fed/odds").token) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    label("Next Fed rate decision")
                    Spacer()
                    if let date { Text(MacroText.countdown(to: date)).font(.caption.weight(.semibold)).foregroundStyle(Color.wireAccent) }
                }
                Text(date?.formatted(.dateTime.weekday(.wide).month(.wide).day()) ?? meeting.label).font(.headline)
                Text([range.map { "Rates are \($0) today." }, MacroText.fedOdds(meeting.detail)].compactMap { $0 }.joined(separator: " "))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var economy: some View {
        HStack(alignment: .top, spacing: 12) {
            if let cpi = macro.cpi {
                stat("Inflation", value: cpi.value, caption: "Prices, past year", month: cpi.date, group: "inflation")
            }
            if let rate = macro.unemployment {
                stat("Unemployment", value: rate.value, caption: "Of workers", month: rate.date, group: "jobs")
            }
            if let jobs = macro.payrolls {
                stat("Jobs added", value: jobs.value.replacingOccurrences(of: " K", with: "K"), caption: "In the month", month: jobs.date, group: "jobs")
            }
        }
        .padding(16)
    }

    private func stat(_ title: String, value: String, caption: String, month: String?, group: String) -> some View {
        Button { open(DataRoute("macro", ["group": group]).token) } label: {
            VStack(alignment: .leading, spacing: 3) {
                label(title)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(MacroText.month(month).isEmpty ? caption : MacroText.month(month)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func latest(_ row: DataPayload.Row) -> some View {
        Button { open(DataRoute("releases", ["impact": "medium"]).token) } label: {
            VStack(alignment: .leading, spacing: 6) {
                label("Just released")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(MacroText.title(row.label).flag)
                    Text(MacroText.surprise(row)).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var comingUp: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Coming up").padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            ForEach(Array(macro.upcoming.enumerated()), id: \.offset) { index, event in
                let title = MacroText.title(event.row.label)
                Button { open(DataRoute("calendar").token) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MacroText.relativeDay(event.day)).font(.subheadline.weight(.semibold))
                            Text(MacroText.time(event.row.value)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(title.flag) \(title.text)").font(.subheadline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            let expected = MacroText.expectation(event.row)
                            if !expected.isEmpty { Text(expected).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if index < macro.upcoming.count - 1 { Divider().padding(.leading, 124) }
            }
        }
        .padding(.bottom, 6)
    }
}

nonisolated enum AlertTopic: String, CaseIterable, Identifiable, Sendable {
    case jobs, inflation, growth, fed, globalMarkets = "global-markets", usMarkets = "us-markets", crypto, companies, government, world, headlines

    var id: String { rawValue }
    var title: String {
        switch self {
        case .jobs: "Jobs reports"
        case .inflation: "Inflation (CPI, PCE, PPI)"
        case .growth: "GDP and retail sales"
        case .fed: "Fed, rates and credit"
        case .globalMarkets: "Asia, Europe and currencies"
        case .usMarkets: "US stocks and commodities"
        case .crypto: "Crypto"
        case .companies: "Earnings, insiders, Congress trades"
        case .government: "Fiscal, policy and contracts"
        case .world: "Shipping, quakes and outages"
        case .headlines: "Watched headlines"
        }
    }
    var symbol: String {
        switch self {
        case .jobs: "person.2"
        case .inflation: "cart"
        case .growth: "chart.bar"
        case .fed: "building.columns"
        case .globalMarkets: "globe.asia.australia"
        case .usMarkets: "chart.line.uptrend.xyaxis"
        case .crypto: "bitcoinsign"
        case .companies: "doc.text"
        case .government: "flag"
        case .world: "ferry"
        case .headlines: "newspaper"
        }
    }

    static var muted: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mutedAlertTopics") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "mutedAlertTopics") }
    }
}

struct AlertTopicsView: View {
    @State private var muted = AlertTopic.muted

    var body: some View {
        Form {
            Section {
                ForEach(AlertTopic.allCases) { topic in
                    Toggle(isOn: Binding(get: { !muted.contains(topic.rawValue) }, set: { on in
                        if on { muted.remove(topic.rawValue) } else { muted.insert(topic.rawValue) }
                    })) { Label(topic.title, systemImage: topic.symbol) }
                }
            } footer: {
                Text("Urgent and breaking stories notify you. Muted topics still appear on the wire. Stock alerts for your holdings are separate.")
            }
        }
        .navigationTitle("Notifications")
        .onChange(of: muted) { _, value in
            AlertTopic.muted = value
            Task { await PushDelegate.syncStockAlerts() }
        }
    }
}
