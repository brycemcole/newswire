import SwiftUI

nonisolated struct MarketOutlook: Codable, Equatable, Sendable {
    var headline: String
    var deck: String
    var body: String
    var tone: String
    var symbols: [String]
    var sources: [StockSource]
    var provider: String
    var model: String?
    var generatedAt: Date
    /// The next session boundary after generation: the close while the market is open, otherwise the next open.
    var validUntil: Date
    /// When the market pulse it was given was computed; nil when the pulse could not be fetched.
    var pulseAsOf: Date?

    var byline: String { model.map { "\(provider) · \($0)" } ?? provider }

    func current(at now: Date) -> Bool { now < validUntil }
}

/// Writes the home screen's market outlook as a full story, whenever the home screen is visible and the last one is out of date.
@MainActor @Observable final class MarketOutlookStore {
    static let shared = MarketOutlookStore()
    private static let key = "marketOutlook.v1"
    /// While the market is open, prices move enough that a morning outlook is stale by lunch.
    private static let openSessionAge: TimeInterval = 2 * 3600
    private static let retryDelay: TimeInterval = 10 * 60

    private(set) var outlook: MarketOutlook?
    private(set) var generating = false
    private(set) var activity: String?
    private(set) var error: String?
    @ObservationIgnored private var lastFailure: Date?
    @ObservationIgnored private var chat: StockChat?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            outlook = try? JSONDecoder().decode(MarketOutlook.self, from: data)
        }
    }

    func needsRefresh(at now: Date = .now) -> Bool {
        guard let outlook else { return true }
        if !outlook.current(at: now) { return true }
        if MarketClock.session(on: now)?.contains(now) == true, now.timeIntervalSince(outlook.generatedAt) > Self.openSessionAge { return true }
        return false
    }

    func ensure(now: Date = .now) async {
        guard !generating, needsRefresh(at: now), AIRouter.isAvailable(.stockChat) || ChatGPTAccount.shared.ready else { return }
        if let lastFailure, now.timeIntervalSince(lastFailure) < Self.retryDelay { return }
        await generate()
    }

    func generate() async {
        guard !generating else { return }
        #if DEBUG
        if CommandLine.arguments.contains("-outlookSample") { loadSample(); return }
        #endif
        generating = true
        error = nil
        activity = "Reading the market…"
        defer { generating = false; activity = nil; chat = nil }
        let started = Date.now
        let pulse = await Self.pulse()
        let chat = StockChat()
        if ChatGPTAccount.shared.ready { chat.backendOverride = .chatGPT }
        chat.customFormat = Self.format
        self.chat = chat
        let model = chat.backend == .chatGPT ? try? await ChatGPTAccount.shared.model() : nil
        chat.send(Self.prompt(pulse: pulse, now: started), symbol: "", name: "Markets", price: nil)
        do {
            while chat.busy {
                if let status = chat.activity { activity = status }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            chat.cancel()
            return
        }
        if let message = chat.error {
            fail(message)
            return
        }
        guard let answer = chat.messages.last, !answer.user, let parsed = Self.parse(answer.text) else {
            fail("The outlook came back in an unexpected shape.")
            return
        }
        let session = MarketClock.session(on: started)
        let validUntil = session.flatMap { $0.contains(started) ? $0.end : nil } ?? MarketClock.nextOpen(after: started)
        let outlook = MarketOutlook(headline: parsed.headline, deck: parsed.deck, body: parsed.body, tone: parsed.tone,
                                    symbols: parsed.symbols, sources: answer.sources, provider: answer.provider, model: model,
                                    generatedAt: started, validUntil: validUntil, pulseAsOf: pulse?.asOf)
        self.outlook = outlook
        lastFailure = nil
        if let data = try? JSONEncoder().encode(outlook) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    private func fail(_ message: String) {
        error = message
        lastFailure = .now
    }

    private static func pulse() async -> MarketPulse? {
        guard let url = NewswireAPI.validatedURL(FeedStore.shared.serverURL) else { return nil }
        return try? await NewswireAPI(baseURL: url).marketPulse(symbol: "SPY")
    }

    private static let format = """
    You are writing Newswire's market outlook: a short, original analyst story about where US stocks are likely headed over the next few trading days, for the owner's phone home screen. Output exactly two parts and nothing else.
    Part 1 is a fenced block with language outlook holding one JSON object: {"headline":"a news headline under 14 words stating your call","deck":"one or two sentences, under 45 words, with the key numbers behind the call","tone":"bullish" | "bearish" | "mixed","symbols":["SPY","NVDA"]}. symbols lists up to 6 tickers the story discusses, most important first.
    Part 2 is the story in plain markdown, 300 to 550 words. Open with the call and why, in one paragraph. Then use short ## headings such as What's driving it, What to watch, Your positions, and The risk to this view. Include a compact table when comparing several numbers. Name the specific stocks, sectors, rates or commodities you expect to lead or lag and why. End with the levels or events that would change your mind.
    Research before writing: call Newswire data tools for current index, futures, rates, oil and volatility quotes; the economic and earnings calendar for the next few trading days; and recent Newswire stories. Check news on the owner's largest holdings and watchlist names. Use web search for anything recent the tools don't cover.
    Cite every number and claim with the bracketed source number from tool results, or an inline Markdown link for web pages. State each quote's time when it is not live. If a source is stale, partial or missing, say so and lower your confidence rather than guessing. Give probabilities as ranges, never certainties. This is analysis for the owner to weigh, not an instruction to trade; do not add a disclaimer paragraph, the app shows one.
    """

    private static func prompt(pulse: MarketPulse?, now: Date) -> String {
        var lines = ["Write the market outlook for the next few trading days. It is \(now.formatted(.dateTime.weekday(.wide).month().day().hour().minute())) Eastern-time market phase: \(HomePhase.at(now).label)."]
        if let pulse {
            lines.append("NEWSWIRE MARKET PULSE for SPY, computed \(pulse.asOf.formatted(.dateTime.month().day().hour().minute())), horizon \(pulse.horizon ?? "unknown"). This is an uncalibrated research index, one input among many; confirm its prices with tools.")
            if let call = pulse.call { lines.append("Call: \(call.headline) (tone \(call.tone), strength \(call.strength))") }
            if let summary = pulse.summary { lines.append("Summary: \(summary)") }
            for driver in (pulse.drivers ?? []).prefix(8) { lines.append("- Driver (\(driver.effect)): \(driver.title). \(driver.detail)") }
            for item in (pulse.comingUp ?? []).prefix(6) { lines.append("- Coming up \(item.when): \(item.title). \(item.detail)") }
        } else {
            lines.append("DATA GAP: the Newswire market pulse could not be fetched; rely on tools.")
        }
        let held = HomeSymbols.held.filter { !$0.contains(" ") }.prefix(15)
        let watched = HomeSymbols.watched.prefix(15)
        if !held.isEmpty { lines.append("\n" + GoalReviewer.context()) }
        if !watched.isEmpty { lines.append("Watchlist: \(watched.joined(separator: ", "))") }
        if held.isEmpty && watched.isEmpty { lines.append("The owner has no positions or watchlist yet; write for a broad US stock investor.") }
        let headlines = FeedStore.shared.stories.prefix(15).map { "- \($0.title) (\($0.source), \($0.publishedAt.formatted(.dateTime.month().day().hour().minute())))" }
        if !headlines.isEmpty { lines.append("\nLatest Newswire headlines:\n" + headlines.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    struct Parsed: Equatable {
        var headline: String
        var deck: String
        var tone: String
        var symbols: [String]
        var body: String
    }

    private struct Header: Decodable { var headline: String; var deck: String?; var tone: String?; var symbols: [String]? }

    static func parse(_ text: String) -> Parsed? {
        guard let match = text.firstMatch(of: /```outlook\s*([\s\S]*?)```/),
              let header = try? JSONDecoder().decode(Header.self, from: Data(String(match.1).utf8)) else { return nil }
        let body = text.replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !header.headline.isEmpty else { return nil }
        let symbols = (header.symbols ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "$ ")).uppercased() }.filter { !$0.isEmpty }
        return Parsed(headline: header.headline, deck: header.deck ?? "", tone: header.tone ?? "mixed", symbols: Array(symbols.prefix(6)), body: body)
    }

    #if DEBUG
    private func loadSample() {
        let now = Date.now
        outlook = MarketOutlook(
            headline: "[TEST] Stocks set to grind higher into a light holiday week",
            deck: "[TEST] Futures are up 0.3% and the VIX sits near 14, but Tuesday's PCE print can swing the call.",
            body: "[TEST] **Expect a modest upward drift through Wednesday.** [1]\n\n## What's driving it\n\nFutures are firmer overnight [1].\n\n| Input | Level | Change |\n|---|---|---|\n| S&P futures | 6,950 | +0.3% |\n| VIX | 14.1 | −0.4 |\n\n## What to watch\n\n- **PCE** on Tuesday [1].\n\n## The risk to this view\n\nA hot inflation print.",
            tone: "bullish", symbols: ["SPY", "QQQ", "NVDA"],
            sources: [StockSource(title: "Newswire data", url: URL(string: "https://example.com/test")!)],
            provider: "ChatGPT", model: "test-model", generatedAt: now.addingTimeInterval(-25 * 60),
            validUntil: now.addingTimeInterval(3600), pulseAsOf: now.addingTimeInterval(-30 * 60))
    }
    #endif
}

struct MarketOutlookRoute: Hashable {}

/// The outlook as a feed row, shaped like a news story.
struct MarketOutlookRow: View {
    @State private var store = MarketOutlookStore.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if let outlook = store.outlook {
                TimelineView(.everyMinute) { context in
                    content(outlook, now: context.date)
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .task(id: phase == .active) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await store.ensure()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private func content(_ outlook: MarketOutlook, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            byline(outlook, now: now)
            Text(outlook.headline)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !outlook.deck.isEmpty {
                Text(outlook.deck).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            status(outlook, now: now)
            if !outlook.symbols.isEmpty { OutlookQuotePills(symbols: outlook.symbols) }
        }
    }

    private func byline(_ outlook: MarketOutlook, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.caption).foregroundStyle(Color.wireAccent).accessibilityHidden(true)
            Text("Outlook").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text(outlook.provider).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Text("·").foregroundStyle(.tertiary)
            Text(outlook.generatedAt.wireAge).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder private func status(_ outlook: MarketOutlook, now: Date) -> some View {
        if store.generating {
            Label(store.activity ?? "Updating…", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if let error = store.error {
            Label("Update failed · \(error)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1)
        } else if !outlook.current(at: now) {
            Label("Written before \(outlook.validUntil.formatted(date: .omitted, time: .shortened)); no longer current", systemImage: "clock")
                .font(.caption).foregroundStyle(.orange).lineLimit(1)
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis").font(.caption).foregroundStyle(Color.wireAccent)
                Text("Outlook").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            }
            if store.generating {
                Text("Writing the market outlook…").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                Text(store.activity ?? "Reading the market…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let error = store.error {
                Text("Outlook unavailable").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if !AIRouter.isAvailable(.stockChat) && !ChatGPTAccount.shared.ready {
                Text("Sign in to ChatGPT in Settings to get a daily market outlook.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Writing the market outlook…").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OutlookQuotePills: View {
    let symbols: [String]
    @State private var quotes: [String: Quote] = [:]

    var body: some View {
        StoryQuoteStats(symbols: symbols, quotes: quotes)
            .onReceive(QuoteStore.shared.updates) { keys in
                guard !keys.isDisjoint(with: symbols) else { return }
                let next = QuoteStore.shared.peekQuotes(symbols)
                if next != quotes { quotes = next }
            }
            .task(id: symbols) {
                quotes = QuoteStore.shared.peekQuotes(symbols)
                QuoteStore.shared.want(symbols)
            }
    }
}

/// The full outlook, laid out like a story.
struct MarketOutlookDetail: View {
    @State private var store = MarketOutlookStore.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.feedStore) private var feedStore

    var body: some View {
        ScrollView {
            if let outlook = store.outlook {
                article(outlook)
            } else {
                ContentUnavailableView(store.generating ? "Writing the outlook" : "No outlook yet",
                                       systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text(store.error ?? store.activity ?? ""))
                    .padding(.top, 80)
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle("Outlook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.generate() }
                } label: {
                    if store.generating { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(store.generating)
                .accessibilityLabel("Rewrite outlook")
            }
        }
        .asksAbout(AskContext(screen: store.outlook.map { "The Newswire market outlook \"\($0.headline)\", written \($0.generatedAt.formatted(.dateTime.month().day().hour().minute())). \($0.body.prefix(1500))" } ?? "The Newswire market outlook, not yet written."))
    }

    private func article(_ outlook: MarketOutlook) -> some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Text("Outlook").font(.footnote.weight(.bold))
                    Text("·").foregroundStyle(.tertiary)
                    Text(outlook.byline).font(.footnote)
                }
                .foregroundStyle(.secondary)
                Text(outlook.headline).font(.title.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                if !outlook.deck.isEmpty { Text(outlook.deck).font(.title3).foregroundStyle(.secondary) }
                provenance(outlook, now: context.date)
                if !outlook.symbols.isEmpty { OutlookQuotePills(symbols: outlook.symbols) }
                Divider()
                MarkdownText(outlook.body, sources: outlook.sources, keepsOrder: true)
                    .environment(\.openURL, OpenURLAction { open($0, sources: outlook.sources) })
                if !outlook.sources.isEmpty { sources(outlook.sources) }
                Text("Written by AI from Newswire data, stories and web sources. It can be wrong; it is not investment advice.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func provenance(_ outlook: MarketOutlook, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Written \(outlook.generatedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · covers until \(outlook.validUntil.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                .foregroundStyle(.secondary)
            if outlook.pulseAsOf == nil {
                Text("Market pulse was unavailable when this was written.").foregroundStyle(.orange)
            }
            if store.generating {
                Label(store.activity ?? "Updating…", systemImage: "arrow.clockwise").foregroundStyle(.secondary)
            } else if let error = store.error {
                Label("Latest update failed: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if !outlook.current(at: now) {
                Label("No longer current; a new outlook is on the way.", systemImage: "clock").foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    private func sources(_ sources: [StockSource]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources").font(.subheadline.weight(.semibold))
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                Button {
                    _ = open(source.url, sources: sources)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.tint)
                        Text(source.title).font(.subheadline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    private func open(_ url: URL, sources: [StockSource]) -> OpenURLAction.Result {
        if let source = sources.first(where: { $0.url == url }), let id = source.story,
           let story = feedStore?.story(id: id) ?? FeedStore.shared.story(id: id) {
            FeedStore.shared.path.append(story)
            return .handled
        }
        openURL(url)
        return .handled
    }
}
