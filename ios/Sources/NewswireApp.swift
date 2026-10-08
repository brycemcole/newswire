import SafariServices
import SwiftUI

@main struct NewswireApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if CommandLine.arguments.contains("-notificationSetupPreview") {
                NavigationStack { PushSettingsView(preview: PushStatusPreview.fromArguments) }
            } else if CommandLine.arguments.contains("-savedStoriesPreview") {
                SavedStoriesPreview()
            } else if CommandLine.arguments.contains("-institutionalPreview") {
                InstitutionalPreview()
            } else if let index = CommandLine.arguments.firstIndex(of: "-articlePreview"),
               let raw = CommandLine.arguments.dropFirst(index + 1).first, let url = URL(string: raw) {
                ArticleReaderPreview(url: url)
            } else if let index = CommandLine.arguments.firstIndex(of: "-dataPreview"), let route = CommandLine.arguments.dropFirst(index + 1).first {
                DataReadingPreview(path: route)
            } else if CommandLine.arguments.contains("-ptrReportPreview"),
                      let source = URL(string: "https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2026/20035408.pdf") {
                HousePTRDetailView(member: "April McClain Delaney", filed: "2026-09-09", filingID: "20035408", year: 2026, source: source)
            } else if CommandLine.arguments.contains("-statsPreview") {
                MarketStatsPreview()
            } else if CommandLine.arguments.contains("-storyDesignPreview") {
                StoryDesignPreview()
            } else if CommandLine.arguments.contains("-portfolioPreview") {
                PortfolioPreview()
            } else if CommandLine.arguments.contains("-portfolioAudit") {
                PortfolioView()
            } else if let index = CommandLine.arguments.firstIndex(of: "-widgetGallery") {
                WidgetGallery(page: CommandLine.arguments.dropFirst(index + 1).first ?? "home")
            } else {
                FeedView()
            }
            #else
            FeedView()
            #endif
        }
        .backgroundTask(.appRefresh(FeedStore.refreshTaskID)) {
            await FeedStore.shared.backgroundRefresh()
        }
    }
}

extension Color {
    static var wireAccent: Color { Theme.shared.accent.color }
}

struct PressSpringStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .spring(duration: 0.32, bounce: 0.3), value: configuration.isPressed)
    }
}

extension EnvironmentValues {
    @Entry var feedStore: FeedStore?
}

nonisolated enum Accent: String, CaseIterable, Identifiable {
    case amber, yellow, lime, green, mint, cyan, blue, indigo, violet, purple, pink, rose, brown, graphite, white

    var id: String { rawValue }

    var onColor: Color { self == .white ? Color(uiColor: .systemBackground) : .white }

    var color: Color {
        Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            switch self {
            case .amber: return dark ? UIColor(red: 1.0, green: 0.69, blue: 0.30, alpha: 1) : UIColor(red: 0.52, green: 0.27, blue: 0.02, alpha: 1)
            case .yellow: return dark ? UIColor(red: 1.0, green: 0.84, blue: 0.35, alpha: 1) : UIColor(red: 0.58, green: 0.42, blue: 0.0, alpha: 1)
            case .lime: return dark ? UIColor(red: 0.72, green: 0.92, blue: 0.40, alpha: 1) : UIColor(red: 0.33, green: 0.50, blue: 0.0, alpha: 1)
            case .green: return dark ? UIColor(red: 0.55, green: 0.90, blue: 0.45, alpha: 1) : UIColor(red: 0.16, green: 0.50, blue: 0.10, alpha: 1)
            case .mint: return dark ? UIColor(red: 0.45, green: 0.92, blue: 0.85, alpha: 1) : UIColor(red: 0.0, green: 0.48, blue: 0.44, alpha: 1)
            case .cyan: return dark ? UIColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 1) : UIColor(red: 0.0, green: 0.40, blue: 0.58, alpha: 1)
            case .blue: return dark ? UIColor(red: 0.50, green: 0.75, blue: 1.0, alpha: 1) : UIColor(red: 0.05, green: 0.36, blue: 0.75, alpha: 1)
            case .indigo: return dark ? UIColor(red: 0.66, green: 0.62, blue: 1.0, alpha: 1) : UIColor(red: 0.25, green: 0.20, blue: 0.72, alpha: 1)
            case .violet: return dark ? UIColor(red: 0.78, green: 0.65, blue: 1.0, alpha: 1) : UIColor(red: 0.42, green: 0.22, blue: 0.78, alpha: 1)
            case .purple: return dark ? UIColor(red: 0.88, green: 0.58, blue: 1.0, alpha: 1) : UIColor(red: 0.52, green: 0.10, blue: 0.66, alpha: 1)
            case .pink: return dark ? UIColor(red: 1.0, green: 0.62, blue: 0.82, alpha: 1) : UIColor(red: 0.75, green: 0.15, blue: 0.48, alpha: 1)
            case .rose: return dark ? UIColor(red: 1.0, green: 0.50, blue: 0.55, alpha: 1) : UIColor(red: 0.72, green: 0.10, blue: 0.20, alpha: 1)
            case .brown: return dark ? UIColor(red: 0.85, green: 0.68, blue: 0.50, alpha: 1) : UIColor(red: 0.45, green: 0.28, blue: 0.14, alpha: 1)
            case .graphite: return dark ? UIColor(red: 0.74, green: 0.77, blue: 0.80, alpha: 1) : UIColor(red: 0.34, green: 0.36, blue: 0.40, alpha: 1)
            case .white: return dark ? UIColor(white: 0.96, alpha: 1) : UIColor(white: 0.1, alpha: 1)
            }
        })
    }
}

@Observable final class ReadState {
    static let shared = ReadState()
    /// Looked up by every row on every render, so it is a set; `order` keeps the oldest-first list that is trimmed and saved.
    private(set) var seen: Set<String>
    @ObservationIgnored private var order: [String]

    init() {
        order = UserDefaults.standard.stringArray(forKey: "seenStories") ?? []
        seen = Set(order)
    }

    func contains(_ story: Story) -> Bool { seen.contains(story.id) }

    func mark(_ story: Story) {
        guard !seen.contains(story.id) else { return }
        order.append(story.id)
        if order.count > 2000 { order.removeFirst(order.count - 2000) }
        seen = Set(order)
        UserDefaults.standard.set(order, forKey: "seenStories")
    }
}

@Observable final class SavedStories {
    static let shared = SavedStories()
    private(set) var items: [SavedStory]
    @ObservationIgnored private let defaults: UserDefaults
    private let key: String
    private let limit = 100
    private let articleLimit = 40_000

    init(defaults: UserDefaults = .standard, key: String = "savedStorySnapshots") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([SavedStory].self, from: data) {
            items = Array(saved.prefix(limit))
        } else {
            items = []
        }
    }

    func contains(_ story: Story) -> Bool { items.contains { $0.story.id == story.id } }

    func search(_ query: String) -> [SavedStory] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.matches(query) }
    }

    func toggle(_ story: Story, articleText: String?) {
        if let index = items.firstIndex(where: { $0.story.id == story.id }) {
            items.remove(at: index)
        } else {
            let snapshot = Story(id: story.id, externalId: story.externalId,
                                 title: String(story.title.prefix(500)), summary: String(story.summary.prefix(10_000)),
                                 body: String(story.body.prefix(20_000)), source: String(story.source.prefix(300)),
                                 url: story.url, publishedAt: story.publishedAt, receivedAt: story.receivedAt,
                                 category: story.category, priority: story.priority, tickers: story.tickers,
                                 tags: story.tags, agent: story.agent, imageUrl: nil, interaction: story.interaction)
            items.insert(SavedStory(story: snapshot, articleText: articleText.map { String($0.prefix(articleLimit)) }), at: 0)
            if items.count > limit { items.removeLast(items.count - limit) }
        }
        persist()
    }

    func remove(_ story: Story) {
        guard items.contains(where: { $0.story.id == story.id }) else { return }
        items.removeAll { $0.story.id == story.id }
        persist()
    }

    func updateOfflineText(_ text: String, for story: Story) {
        guard let index = items.firstIndex(where: { $0.story.id == story.id }) else { return }
        items[index] = SavedStory(story: items[index].story, articleText: String(text.prefix(articleLimit)))
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
    }
}

struct SavedStory: Codable, Identifiable {
    var id: String { story.id }
    let story: Story
    let articleText: String?

    func matches(_ query: String) -> Bool {
        story.title.localizedCaseInsensitiveContains(query)
            || story.source.localizedCaseInsensitiveContains(query)
            || story.summary.localizedCaseInsensitiveContains(query)
            || story.body.localizedCaseInsensitiveContains(query)
            || (articleText?.localizedCaseInsensitiveContains(query) ?? false)
            || story.tickers.contains { $0.localizedCaseInsensitiveContains(query) }
            || story.tags.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

@Observable final class Theme {
    static let shared = Theme()
    var accent = Accent(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .amber {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "accent") }
    }
}

private enum FeedDestination: Hashable { case explore }

struct FeedView: View {
    @Environment(\.scenePhase) private var phase
    @State private var store = FeedStore.shared
    @State private var settings = false
    @State private var showingSaved = false
    @State private var portfolio = false
    @State private var dock = DockDetent.peek
    @State private var dockFrame = CGRect.zero
    @State private var quoteRoute: MarketSymbol?
    @State private var dataRoute: DataRoute?
    @State private var marketDepth: Int?
    @State private var asking: AskContext?
    @State private var watchlist = Watchlist.shared
    @State private var board = MarketBoard.shared
    @State private var watchlistExpanded = UserDefaults.standard.bool(forKey: "watchlistExpanded")
    @State private var portfolioExpanded = UserDefaults.standard.bool(forKey: "portfolioExpanded")
    @State private var search = ""
    @AppStorage("headlinesOnly") private var headlinesOnly = false
    @AppStorage("compactHome") private var compactHome = false
    @AppStorage("homeOrder") private var homeOrder = "marketsFirst"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pillNamespace
    private let categories = ["", "general", "markets", "technology", "economy", "politics", "world", "science"]

    private var hidesMarketDock: Bool {
        TerminalExploreVisibility.shared.isVisible || DataScreen.designedPaths.contains(dataRoute?.path ?? "")
    }

    private var selectionAnimation: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.38, bounce: 0.18) }

    private var navigation: some View {
        NavigationStack(path: $store.path) {
            Group {
                List {
                    if search.isEmpty && store.filters.isEmpty && homeOrder == "marketsFirst" {
                        dashboard
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        MarketsHome(open: open(quote:))
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    if search.isEmpty && store.filters.isEmpty && homeOrder == "newsFirst" {
                        dashboard
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    filterBar
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    if !store.configured && store.stories.isEmpty {
                        state("CONNECT YOUR WIRE", message: "Add your HTTPS server URL to start reading.", icon: "antenna.radiowaves.left.and.right.slash")
                        Button("Open settings") { settings = true }
                    } else if !store.restored {
                        // The cache is read off the main thread in a few milliseconds; show nothing rather than flash a placeholder.
                        EmptyView()
                    } else if store.stories.isEmpty && (store.loading || !store.hasLoaded) {
                        state("YOUR WIRE", message: "Connecting to your latest headlines.", icon: "newspaper")
                    } else if store.stories.isEmpty && !store.loading && store.error == nil && store.hasLoaded {
                        state("NO STORIES", message: "No stories match these filters. Pull to refresh or choose another category.", icon: "text.magnifyingglass")
                    }
                    if let error = store.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                            Button("Retry") { Task { await store.sync(.replace) } }
                        }.font(.system(.caption, design: .monospaced)).padding(.vertical, 8)
                    }
                    let olderTrigger = store.olderTriggerID
                    ForEach(store.stories) { story in
                        NavigationLink(value: story) { StoryRow(story: story, showSummary: !headlinesOnly) }
                            .id(story.id)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.visible)
                            .onAppear {
                                // Start the next page well before the end so scrolling never waits on the network.
                                if story.id == olderTrigger { Task { await store.loadOlder() } }
                                if let index = store.stories.firstIndex(where: { $0.id == story.id }) {
                                    for next in store.stories.dropFirst(index + 1).prefix(6).reversed() { Summarizer.shared.request(next, ahead: true) }
                                }
                            }
                    }
                    if store.cursor != nil {
                        Button { Task { await store.loadOlder() } } label: {
                            HStack { Spacer(); Text(store.loadingOlder ? "FETCHING OLDER STORIES" : "LOAD OLDER"); Spacer() }.frame(minHeight: 44)
                        }.disabled(store.loadingOlder)
                            .task(id: store.cursor) { await store.loadOlder() }
                    }
                    if search.isEmpty && store.filters.isEmpty && homeOrder == "newsFirst" {
                        MarketsHome(open: open(quote:))
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .dockClearance()
                .listSectionSpacing(0)
                .listSectionSeparator(.hidden)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: headlinesOnly)
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .refreshable { await store.sync(.replace) }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top < 24
                } action: { _, top in
                    store.atTop = top
                }
                .onScrollPhaseChange { _, phase in
                    Summarizer.shared.scrolling = phase.isScrolling
                }
                .task(id: store.stories.prefix(40).map(\.id)) {
                    Summarizer.shared.preload(store.stories)
                }
                .searchable(text: $search, tokens: $store.filters, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search the wire") { filter in
                    Label(filter.title, systemImage: filter.symbol)
                }
                .navigationDestination(for: Story.self) { StoryDetail(story: $0) }
                .navigationDestination(for: MarketSymbol.self) { QuoteDetail(symbol: $0.id).id($0.id).dockClearance() }
                .navigationDestination(for: DataRoute.self) { route in
                    if DataScreen.designedPaths.contains(route.path) {
                        DataScreen(route: route).id(route.id)
                    } else {
                        DataScreen(route: route).id(route.id).dockClearance()
                    }
                }
                .navigationDestination(for: FeedDestination.self) { _ in
                    TerminalExploreView { token in
                        marketDepth = nil
                        open(quote: token)
                    }
                }
                .navigationTitle("NEWSWIRE")
                .navigationSubtitle(subtitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { asking = .markets } label: { Image(systemName: "sparkles") }
                            .accessibilityLabel("Ask AI")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingSaved = true } label: { Image(systemName: "bookmark") }
                            .accessibilityLabel("Saved stories")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { portfolio = true } label: { Image(systemName: "briefcase") }
                            .accessibilityLabel("Portfolio")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { settings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
            }
            .sheet(isPresented: $settings) { SettingsView(store: store) }
            .sheet(isPresented: $showingSaved) { SavedStoriesView() }
            .sheet(isPresented: $portfolio) { PortfolioView() }
            .sheet(item: $asking) { AskSheet(context: $0) }
            .task(id: store.category + "|" + search + "|" + store.filters.map(\.id).joined(separator: "|") + "|" + store.serverURL) {
                store.query = search.trimmingCharacters(in: .whitespacesAndNewlines)
                store.reset()
                // Debounce typing only; category and filter taps load immediately.
                if !store.query.isEmpty {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                await store.ready()
                // A cache under an hour old keeps its order and only gains new stories on top; an older one is
                // re-ranked in place before the reader has had time to start reading it.
                let stale = store.lastUpdated.map { $0.timeIntervalSinceNow < -3600 } ?? true
                await store.sync(stale ? .replace : .merge, quiet: true)
            }
            .task(id: phase) {
                if phase == .background {
                    FeedStore.scheduleRefresh()
                    FeedStore.scheduleProcessing()
                }
                guard phase == .active else { return }
                await store.ready()
                PortfolioStore.shared.reloadFromKeychain()
                await PushDelegate.syncStockAlerts()
                if (PortfolioStore.shared.snapshot.updated ?? .distantPast).timeIntervalSinceNow < -300 {
                    await PortfolioStore.shared.sync()
                }
                // Skipped when background refresh just brought the feed up to date; at launch the feed-key task
                // above usually wins and this returns at once because a load is already in flight. After an hour
                // away the list is re-ranked as it opens rather than gaining a block of new stories over stale ones.
                let age = store.lastUpdated.map { -$0.timeIntervalSinceNow } ?? .infinity
                if store.hasLoaded && age > 60 {
                    await store.sync(age > 3600 ? .replace : .merge, quiet: true)
                }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await store.sync(.merge, quiet: true)
                    await PushDelegate.syncStockAlerts()
                }
            }
            .task(id: phase == .active ? watchlist.symbols : []) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await board.refresh(quotes: watchlist.symbols, sparks: watchlist.symbols)
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
        }
    }

    var body: some View {
        navigation
        .gesture(DockBackgroundInteraction(excludedFrame: dockFrame) {
            if dock != .peek {
                withAnimation(selectionAnimation) { dock = .peek }
            }
        })
        .onChange(of: settings) { _, _ in dock = .peek }
        .onChange(of: portfolio) { _, _ in dock = .peek }
        .overlay {
            if !hidesMarketDock {
                MarketDock(detent: $dock, onSelect: { symbol in
                    if symbol == TerminalExploreView.token {
                        withAnimation(selectionAnimation) { dock = .peek }
                        marketDepth = nil
                        store.path.append(FeedDestination.explore)
                        return
                    }
                    withAnimation(selectionAnimation) { dock = .medium }
                    open(quote: symbol)
                }, onFrameChange: { dockFrame = $0 })
            }
        }
        .environment(\.feedStore, store)
        .onOpenURL { url in
            guard url.scheme == "newswire" else { return }
            settings = false
            dock = .peek
            switch url.host() {
            case "portfolio": portfolio = true
            case "quote":
                guard let symbol = url.pathComponents.dropFirst().first else { return }
                portfolio = false
                open(quote: symbol)
            case "story":
                portfolio = false
                guard let id = url.pathComponents.dropFirst().first else { return }
                if let story = store.story(id: id) {
                    store.path = NavigationPath([story])
                } else if let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                          let web = URL(string: link), web.scheme == "https" {
                    UIApplication.shared.open(web)
                }
            default: break
            }
        }
        #if DEBUG
        .task {
            if CommandLine.arguments.contains("-exploreDataTools") {
                try? await Task.sleep(for: .milliseconds(500))
                store.path.append(FeedDestination.explore)
            }
            if CommandLine.arguments.contains("-savedSheet") { showingSaved = true }
            if CommandLine.arguments.contains("-marketSearch") { dock = .large }
            if CommandLine.arguments.contains("-marketSearchMedium") { dock = .medium }
            if CommandLine.arguments.contains("-askMarkets") { asking = .markets }
            if CommandLine.arguments.contains("-dashboardDemo") {
                for _ in 0..<2 {
                    try? await Task.sleep(for: .seconds(2))
                    morphDashboard { watchlistExpanded = true }
                    try? await Task.sleep(for: .seconds(2))
                    morphDashboard { watchlistExpanded = false }
                }
            }
            if let index = CommandLine.arguments.firstIndex(of: "-command"), let text = CommandLine.arguments.dropFirst(index + 1).first, let command = TerminalCommand.parse(text) {
                try? await Task.sleep(for: .seconds(1))
                open(quote: command.token)
            }
            if let index = CommandLine.arguments.firstIndex(of: "-quote"), let symbol = CommandLine.arguments.dropFirst(index + 1).first {
                try? await Task.sleep(for: .seconds(1))
                open(quote: symbol)
            }
            if let index = CommandLine.arguments.firstIndex(of: "-storyURL"), let link = CommandLine.arguments.dropFirst(index + 1).first.flatMap(URL.init(string:)) {
                try? await Task.sleep(for: .seconds(1))
                let title = CommandLine.arguments.dropFirst(index + 2).first ?? link.lastPathComponent
                store.path = NavigationPath([Story(id: "debug", externalId: "debug", title: title, summary: "", body: "", source: link.host() ?? "", url: link,
                                    publishedAt: .now, receivedAt: .now, category: "markets", priority: "normal",
                                    tickers: [], tags: ["headlines"], agent: "debug", imageUrl: nil)])
            }
        }
        #endif
        .onChange(of: store.path.count) { _, count in
            if let depth = marketDepth, count < depth {
                marketDepth = nil
                quoteRoute = nil
                dataRoute = nil
            }
        }
        .onChange(of: watchlistExpanded) { _, value in UserDefaults.standard.set(value, forKey: "watchlistExpanded") }
        .onChange(of: portfolioExpanded) { _, value in UserDefaults.standard.set(value, forKey: "portfolioExpanded") }
    }

    private func open(quote symbol: String) {
        if let depth = marketDepth, store.path.count >= depth {
            store.path.removeLast(store.path.count - depth + 1)
        }
        if let route = DataRoute(token: symbol) {
            quoteRoute = nil
            dataRoute = route
            store.path.append(route)
        } else {
            dataRoute = nil
            let route = MarketSymbol(id: symbol)
            quoteRoute = route
            store.path.append(route)
        }
        marketDepth = store.path.count
    }

    private var watchlistHeader: some View {
        HomeSectionHeader("Watchlist", action: watchlist.symbols.count > 3 ? (watchlistExpanded ? "Show Less" : "Show All") : nil) {
            morphDashboard { watchlistExpanded.toggle() }
        }
    }

    /// Biggest gain today first, biggest loss last; symbols still waiting on a quote keep their saved order at the end.
    private var moversFirst: [String] {
        let order = Dictionary(watchlist.symbols.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return watchlist.symbols.sorted { a, b in
            switch (board.quotes[a]?.changePercent, board.quotes[b]?.changePercent) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: order[a, default: 0] < order[b, default: 0]
            }
        }
    }

    private var watchlistRows: some View {
        VStack(spacing: 0) {
            if watchlist.symbols.isEmpty {
                Button { dock = .large } label: {
                    Text("Tap the star on any quote to add it here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            let shown = watchlistExpanded ? moversFirst : Array(moversFirst.prefix(3))
            ForEach(shown, id: \.self) { symbol in
                let quote = board.quotes[symbol]
                watchlistMenu(for: symbol) {
                    MarketRow(symbol: OptionSymbol.display(symbol), title: quote?.name ?? " ",
                              tag: quote.flatMap { watchlist.entries[symbol]?.caption(at: $0.price) },
                              quote: quote, spark: board.sparks[symbol], inset: 16)
                }
                if symbol != shown.last { Divider().padding(.leading, 16) }
            }
        }
    }

    private var dashboard: some View {
        if compactHome {
            return AnyView(compactDashboard)
        }
        let stacked = watchlistExpanded || portfolioExpanded
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return AnyView(layout {
            VStack(alignment: .leading, spacing: 8) {
                if stacked { watchlistHeader.transition(.cardSwap) }
                ZStack(alignment: .topLeading) {
                    if stacked { watchlistRows.transition(.cardSwap) } else { compactWatchlist.transition(.cardSwap) }
                }
                .frame(maxWidth: .infinity, maxHeight: stacked ? nil : .infinity, alignment: .topLeading)
                .clipShape(.rect(cornerRadius: 24, style: .continuous))
                .homeCard()
            }
            PortfolioCard(compact: !stacked, expanded: portfolioExpanded,
                          setExpanded: { value in morphDashboard { portfolioExpanded = value } }) { portfolio = true }
        }
        .fixedSize(horizontal: false, vertical: true))
    }

    private var compactDashboard: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill").foregroundStyle(Color.wireAccent)
                Text("Watchlist").font(.subheadline.weight(.semibold))
                Text(watchlist.symbols.isEmpty ? "Add symbols" : watchlist.symbols.prefix(3).map(OptionSymbol.display).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { dock = .large }
            Button { portfolio = true } label: {
                Label("Portfolio", systemImage: "briefcase").font(.caption.weight(.semibold))
            }.buttonStyle(.plain)
        }
        .padding(14)
        .homeCard()
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Tap opens the quote; press and hold shows the remove action.
    /// A `Menu` is used instead of `.contextMenu` because the dashboard is a single `List` row,
    /// and a context menu inside a row lifts the whole row (both cards) as its preview.
    private func watchlistMenu<Label: View>(for symbol: String, @ViewBuilder label: () -> Label) -> some View {
        Menu {
            Button("Remove from Watchlist", systemImage: "star.slash", role: .destructive) {
                withAnimation(.easeOut(duration: 0.2)) { watchlist.remove(symbol) }
            }
        } label: {
            label().contentShape(.rect)
        } primaryAction: {
            open(quote: symbol)
        }
        .buttonStyle(.plain)
    }

    /// The dashboard is a single `List` row, and the list repositions that row while SwiftUI animates inside it,
    /// so a sliding resize lurches. The layout switches at once and the new contents fade in instead.
    private func morphDashboard(_ change: @escaping () -> Void) {
        withTransaction(Transaction(animation: nil)) { change() }
    }

    private var compactWatchlist: some View {
        VStack(alignment: .leading, spacing: 0) {
            if watchlist.symbols.isEmpty {
                Button { dock = .large } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Watchlist").font(.subheadline.weight(.semibold))
                        Text("Star any quote to add it here.").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(14)
            }
            let shown = Array(moversFirst.prefix(3))
            ForEach(shown, id: \.self) { symbol in
                let quote = board.quotes[symbol]
                watchlistMenu(for: symbol) {
                    CompactWatchlistQuote(symbol: symbol, quote: quote)
                }
                if symbol != shown.last || watchlist.symbols.count > 3 { Divider().padding(.leading, 14) }
            }
            if watchlist.symbols.count > 3 {
                Button { morphDashboard { watchlistExpanded = true } } label: {
                    HStack(spacing: 4) {
                        Text("\(watchlist.symbols.count - 3) more")
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show all \(watchlist.symbols.count) watchlist items")
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if !store.configured { return "Not connected" }
        if store.error != nil { return "Offline" }
        guard let updated = store.lastUpdated else { return store.stories.isEmpty ? "Connecting" : "Cached" }
        return "Updated " + updated.formatted(date: .omitted, time: .shortened)
    }

    private var filterBar: some View {
        ScrollViewReader { pills in
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(categories, id: \.self) { category in
                            categoryPill(category).id(category)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .onChange(of: store.category) { _, category in
                withAnimation(selectionAnimation) { pills.scrollTo(category, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: store.category)
    }

    private func categoryPill(_ category: String) -> some View {
        let selected = store.category == category
        return Button {
            withAnimation(selectionAnimation) { store.category = category }
        } label: {
            categoryLabel(category)
                .foregroundStyle(selected ? Theme.shared.accent.onColor : Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.wireAccent)
                            .matchedGeometryEffect(id: reduceMotion ? category : "selectedCategory", in: pillNamespace)
                    }
                }
                .contentShape(.capsule)
                .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(PressSpringStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func categoryLabel(_ category: String) -> some View {
        Text(category.isEmpty ? "All" : category.capitalized)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
    }

    private func state(_ title: String, message: String, icon: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon).font(.system(.headline, design: .monospaced))
        } description: { Text(message) }
        .listRowBackground(Color.clear)
    }
}
struct StoryRow: View {
    let story: Story
    var showSummary = true
    @AppStorage private var largeImage: Bool
    @Environment(\.feedStore) private var feedStore
    @State private var savedStories = SavedStories.shared
    /// Read from the summarizer's unobserved storage, then refreshed only for this row when its own results land
    /// (after scrolling settles), so the rest of the feed never re-renders.
    @State private var imageURL: URL?
    @State private var generated: String?
    @State private var hasVideo: Bool

    init(story: Story, showSummary: Bool = true) {
        self.story = story
        self.showSummary = showSummary
        _largeImage = AppStorage(wrappedValue: story.priority == "breaking" || story.priority == "urgent", "largeStoryImage.\(story.id)")
        let key = story.url.absoluteString
        _imageURL = State(initialValue: Summarizer.shared.poster(for: story))
        _generated = State(initialValue: Summarizer.shared.summaries[key])
        _hasVideo = State(initialValue: Summarizer.shared.videos[key] != nil)
    }

    var body: some View {
        Group {
            if let imageURL {
                if showSummary && largeImage && !isSeen {
                    VStack(alignment: .leading, spacing: 12) {
                        details
                        Color.clear
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .frame(maxHeight: 320)
                            .overlay { ThumbnailImage(url: imageURL, size: ThumbnailLoader.large) }
                            .overlay(alignment: .bottomLeading) { videoBadge }
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                    }
                } else {
                    HStack(alignment: .center, spacing: 14) {
                        details.frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 96, height: 96)
                            .overlay { ThumbnailImage(url: imageURL, size: ThumbnailLoader.small) }
                            .overlay(alignment: .bottomLeading) { videoBadge }
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                    }
                }
            } else {
                details
            }
        }
        .opacity(isSeen ? 0.5 : 1)
        .animation(.easeOut(duration: 0.25), value: isSeen)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button {
                savedStories.toggle(story, articleText: Summarizer.shared.texts[story.url.absoluteString])
            } label: {
                Label(savedStories.contains(story) ? "Remove Saved Story" : "Save Story",
                      systemImage: savedStories.contains(story) ? "bookmark.slash" : "bookmark")
            }
            if imageURL != nil && showSummary {
                Button {
                    largeImage.toggle()
                } label: {
                    Label(largeImage ? "Use thumbnail" : "Use large image", systemImage: largeImage ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
            }
            Button { feedStore?.apply(.source(story.source)) } label: { Label("More from \(story.source)", systemImage: "newspaper") }
            if story.isBrain {
                Button { feedStore?.apply(.agent("brain")) } label: { Label("Only Brain picks", systemImage: "brain") }
            }
            Link(destination: story.url) { Label("Read Source", systemImage: "safari") }
            ShareLink(item: story.url)
        }
        .task(id: story.id) { Summarizer.shared.request(story) }
        .onDisappear { Summarizer.shared.withdraw(story) }
        .onReceive(Summarizer.shared.updates) { key in
            guard key == story.url.absoluteString else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                imageURL = Summarizer.shared.poster(for: story)
                generated = Summarizer.shared.summaries[key]
                hasVideo = Summarizer.shared.videos[key] != nil
            }
        }
    }

    @ViewBuilder private var videoBadge: some View {
        if hasVideo {
            Image(systemName: "play.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.45), in: .circle)
                .padding(6)
                .accessibilityLabel("Video")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if unreadPriority == "urgent" {
                    Image(systemName: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Urgent")
                }
                if story.isBrain {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(Color.wireAccent)
                        .accessibilityLabel("Brain pick")
                }
                Text(story.source).font(.footnote.weight(.bold)).foregroundStyle(.secondary).lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
                Text(story.publishedAt.wireAge).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            headline
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if showSummary, let generated {
                Text("\(Text(Image(systemName: "text.line.3.summary")).foregroundStyle(.tertiary)) \(generated)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            } else if showSummary, story.hasDistinctSummary {
                Text(StoryHTML.plainText(story.summary)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            if !tickers.isEmpty {
                StoryQuoteStats(symbols: tickers, quotes: QuoteStore.shared.quotes)
            }
        }
        .task(id: story.id) { QuoteStore.shared.want(QuoteStore.shared.candidates(for: story)) }
    }

    private var tickers: [String] { QuoteStore.shared.symbols(for: story) }

    private var isSeen: Bool { ReadState.shared.contains(story) }
    private var unreadPriority: String { isSeen ? "normal" : story.priority }

    private var headline: Text {
        switch unreadPriority {
        case "breaking": Text("\(Text(Image(systemName: "bell.badge.fill")).foregroundStyle(.red)) \(story.title)")
        default: Text(story.title)
        }
    }
}

extension Date {
    var wireAge: String {
        let seconds = Date.now.timeIntervalSince(self)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        if Calendar.current.isDate(self, equalTo: .now, toGranularity: .year) { return formatted(.dateTime.month(.abbreviated).day()) }
        return formatted(.dateTime.month(.abbreviated).day().year())
    }
}

struct StoryDetail: View {
    let story: Story
    @Environment(\.feedStore) private var feedStore
    @State private var reading = false
    @State private var loading = false
    @State private var attempt = 0
    @State private var rerender = false
    @State private var moreDetail = false
    @State private var interaction: String?
    @State private var savedStories = SavedStories.shared
    @State private var selectedQuote: Quote?
    private var key: String { story.url.absoluteString }
    private var quotes: [Quote] { QuoteStore.shared.quotes(for: story) }
    private var lead: String? {
        if story.isBrain && story.opensInReader && story.hasDistinctSummary { return StoryHTML.plainText(story.summary) }
        return glance == nil && !preparingGlance ? Summarizer.shared.summaries[key] : nil
    }
    private var glance: [String]? { Summarizer.shared.glances[key] }
    private var preparingGlance: Bool {
        !story.isBrain && Summarizer.shared.available && (Summarizer.shared.texts[key]?.count ?? 0) >= 400
            && !Summarizer.shared.unsummarizable.contains(key)
    }
    private var inline: [Int: [Quote]] { QuoteInline.plan([lead ?? ""] + excerpt, quotes: quotes) }
    private func annotated(_ text: String, at index: Int) -> AttributedString {
        QuoteInline.annotate(text, quotes: inline[index] ?? [])
    }
    private var excerpt: [String] {
        Array((Summarizer.shared.texts[key] ?? "").split(separator: "\n").map(String.init))
    }
    var body: some View {
        // The summarizer's dictionaries are unobserved; this makes the detail (and only the detail) update live.
        let _ = Summarizer.shared.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let video = Summarizer.shared.videos[key] {
                    StoryVideoView(url: video, poster: Summarizer.shared.poster(for: story), page: story.url, title: story.title, source: story.source)
                } else if let hero = Summarizer.shared.poster(for: story) {
                    // Starts from the feed's already-decoded thumbnail, so the header is never blank during the push.
                    Color.clear.frame(height: 210).frame(maxWidth: .infinity)
                        .overlay { ThumbnailImage(url: hero, size: ThumbnailLoader.large) }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityHidden(true)
                }
                HStack(spacing: 6) {
                    filterButton(.category(story.category)) { Text(story.category.uppercased()) }
                    if story.priority != "normal" {
                        Text("/").foregroundStyle(.tertiary)
                        filterButton(.priority(story.priority)) {
                            Text(story.priority.uppercased())
                                .foregroundStyle(story.priority == "breaking" ? Color.red : Color.secondary)
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                Text(story.title).font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    filterButton(.source(story.source)) {
                        Text(story.source).fontWeight(.bold).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(story.publishedAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.footnote)
                if !quotes.isEmpty {
                    QuoteStrip(quotes: quotes, selected: $selectedQuote)
                        .transition(.opacity)
                } else if !story.tickers.isEmpty {
                    filterLinks(story.tickers.map(WireFilter.ticker), separator: "  ·  ")
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold)).foregroundStyle(.secondary)
                }
                Divider()
                if glance != nil || preparingGlance {
                    glanceCard.transition(.opacity)
                    Divider()
                }
                if story.isBrain && story.opensInReader && story.hasDistinctSummary, let lead {
                    Text(annotated(lead, at: 0))
                        .font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                } else if let lead {
                    Text("\(Text(Image(systemName: "text.line.3.summary")).foregroundStyle(.tertiary)) \(Text(annotated(lead, at: 0)))")
                        .font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
                if story.opensInReader {
                    if !excerpt.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(excerpt.enumerated()), id: \.element) { index, paragraph in
                                Text(annotated(paragraph, at: index + 1)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.body).foregroundStyle(.primary.opacity(0.85)).lineSpacing(3)
                        .transition(.opacity)
                    } else if loading {
                        Label("Loading article", systemImage: "doc.text").font(.subheadline).foregroundStyle(.secondary)
                            .symbolEffect(.pulse, options: .repeating)
                    } else if story.hasDistinctSummary && !story.isBrain {
                        Text(StoryHTML.plainText(story.summary)).fixedSize(horizontal: false, vertical: true)
                    } else if story.url.host() != "news.google.com" {
                        Button { attempt += 1 } label: { Label("Load article", systemImage: "arrow.clockwise") }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).buttonStyle(.plain)
                    }
                } else {
                    StoryBodyView(html: story.body.isEmpty ? story.summary : story.body, quotes: quotes)
                }
                if !story.tags.isEmpty, !story.opensInReader {
                    filterLinks(story.tags.map(WireFilter.tag), separator: "  ")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                sourceActions
                topicsNote
                relatedSection
            }.padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        #if DEBUG
        .defaultScrollAnchor(CommandLine.arguments.contains("-articlePreviewEnd") ? .bottom : .top)
        #endif
        .animation(.easeOut(duration: 0.2), value: excerpt)
        .animation(.easeOut(duration: 0.2), value: loading)
        .animation(.easeOut(duration: 0.2), value: quotes)
        .task(id: story.id) {
            await QuoteStore.shared.load(story)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await QuoteStore.shared.refresh(story)
            }
        }
        .navigationDestination(item: $selectedQuote) { QuoteDetail(symbol: $0.symbol).dockClearance() }
        .task(id: attempt) {
            if !rerender, let pending = Summarizer.shared.pendingPreload(story) {
                loading = true
                await pending.value
                loading = false
            }
            guard story.opensInReader, story.url.host() != "news.google.com", Summarizer.shared.needsArticle(story) || rerender else { return }
            loading = true
            defer { loading = false; rerender = false }
            // Let the navigation push finish first: extraction can create a web view, which would drop frames mid-transition.
            if attempt == 0 {
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            }
            if let page = await Summarizer.page(story.url, force: rerender) { Summarizer.shared.remember(page, for: story, reload: rerender) }
        }
        .task(id: excerpt.count) {
            if savedStories.contains(story), let article = Summarizer.shared.texts[key] {
                savedStories.updateOfflineText(article, for: story)
            }
            await QuoteStore.shared.scan(story, article: Summarizer.shared.texts[key] ?? "")
        }
        .task(id: excerpt.count) {
            guard !story.isBrain else { return }
            await Summarizer.shared.digest(story)
            await Summarizer.shared.brief(story)
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let filter = WireFilter(url: url) else { return .systemAction }
            feedStore?.apply(filter)
            return .handled
        })
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .task {
            // Give the reader a moment before dimming/collapsing the row in the feed.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            ReadState.shared.mark(story)
        }
        .onAppear {
            if interaction == nil { interaction = story.interaction }
        }
        .task {
            if let saved = savedStories.items.first(where: { $0.story.id == story.id })?.articleText,
               Summarizer.shared.texts[key] == nil {
                Summarizer.shared.restoreOffline(saved, for: story)
            }
            guard story.isBrain else { return }
            _ = await feedStore?.brain(story, action: "view")
        }
        .dockClearance()
        .navigationTitle("STORY").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $reading) { SafariView(url: story.url).ignoresSafeArea() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        savedStories.toggle(story, articleText: Summarizer.shared.texts[key])
                    }
                } label: {
                    Image(systemName: savedStories.contains(story) ? "bookmark.fill" : "bookmark")
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(savedStories.contains(story) ? "Remove saved story" : "Save story")
                .sensoryFeedback(.success, trigger: savedStories.contains(story))
            }
            if story.isBrain {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        reactionButton("like", title: "Like", symbol: "hand.thumbsup")
                        reactionButton("save", title: "Save", symbol: "bookmark")
                        reactionButton("dislike", title: "Less like this", symbol: "hand.thumbsdown")
                    } label: {
                        Image(systemName: reactionSymbol).contentTransition(.symbolEffect(.replace))
                    }
                    .sensoryFeedback(.success, trigger: interaction) { _, new in new != nil }
                    .accessibilityLabel("Rate for Brain")
                }
            }
            if ["http", "https"].contains(story.url.scheme?.lowercased() ?? "") {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: story.url)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canReload {
                            Button {
                                rerender = true
                                attempt += 1
                            } label: { Label("Reload Article", systemImage: "arrow.clockwise") }
                            .disabled(loading)
                        }
                        Button { reading = true } label: { Label("Read Source", systemImage: "safari") }
                    } label: {
                        Image(systemName: loading && rerender ? "arrow.clockwise" : "ellipsis")
                            .symbolEffect(.rotate, options: .repeating, isActive: loading && rerender)
                    }
                    .accessibilityLabel("More")
                }
            }
        }
    }

    private var glanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let glance {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(glance.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(.tertiary).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                            Text(point).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.body)
                let brief = Summarizer.shared.briefs[key]
                if moreDetail {
                    Group {
                        if let brief {
                            Text(brief).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Writing a longer summary…").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.callout).padding(.top, 2).transition(.opacity)
                }
                if brief != nil || (Summarizer.shared.texts[key]?.count ?? 0) >= 800 {
                    Button(moreDetail ? "Show Less" : "Show More") {
                        withAnimation(.easeOut(duration: 0.2)) { moreDetail.toggle() }
                    }
                    .font(.subheadline).foregroundStyle(Color.wireAccent).buttonStyle(.plain)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A short line standing in for the first point of the summary")
                    Text("Another line standing in for a point")
                    Text("A third, shorter placeholder line")
                }
                .font(.body).redacted(reason: .placeholder)
                .phaseAnimator([0.35, 0.7]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.9) }
                .accessibilityLabel("Summarizing")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: glance)
    }

    private var related: (title: String, stories: [Story])? {
        guard let all = feedStore?.stories else { return nil }
        let tickers = Set(story.tickers), topics = Set(story.matchedTopics), tags = Set(story.tags).subtracting(["headlines"])
        let others = all.filter { $0.id != story.id && $0.url != story.url && $0.title != story.title }
        let scored = others.map { other -> (Story, Int) in
            let score = 3 * tickers.intersection(other.tickers).count + 2 * topics.intersection(other.matchedTopics).count
                + tags.intersection(other.tags).count
            return (other, score)
        }
        .filter { $0.1 >= 2 }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.publishedAt > $1.0.publishedAt }
        if !scored.isEmpty { return ("Related", scored.prefix(3).map(\.0)) }
        let sameCategory = others.filter { $0.category == story.category }.sorted { $0.publishedAt > $1.publishedAt }
        return sameCategory.isEmpty ? nil : ("More in \(story.category.capitalized)", Array(sameCategory.prefix(3)))
    }

    @ViewBuilder private var relatedSection: some View {
        if let related {
            VStack(alignment: .leading, spacing: 0) {
                Text(related.title).font(.title3.weight(.semibold)).padding(.bottom, 6)
                ForEach(Array(related.stories.enumerated()), id: \.element.id) { index, other in
                    if index > 0 { Divider() }
                    NavigationLink(value: other) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(other.source) · \(other.publishedAt.wireAge)")
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            Text(other.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                .multilineTextAlignment(.leading).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var topicsNote: some View {
        let topics = story.matchedTopics
        if !topics.isEmpty {
            Text("Flagged by your headline monitor for \(topics.formatted(.list(type: .and))).")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var sourceActions: some View {
        if ["http", "https"].contains(story.url.scheme?.lowercased() ?? "") {
            Button { reading = true } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Read full story").font(.subheadline.weight(.semibold)).foregroundStyle(Color.wireAccent)
                        Text(story.source).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.fill.quaternary, in: .rect(cornerRadius: 14))
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .accessibilityHint("Opens the original article")
        }
    }

    private var canReload: Bool { story.opensInReader && story.url.host() != "news.google.com" }

    private var reactionSymbol: String {
        switch interaction {
        case "like": "hand.thumbsup.fill"
        case "save": "bookmark.fill"
        case "dislike": "hand.thumbsdown.fill"
        default: "hand.thumbsup"
        }
    }

    private func reactionButton(_ type: String, title: String, symbol: String) -> some View {
        let active = interaction == type
        return Button {
            let previous = interaction
            interaction = active ? nil : type
            Task {
                if await feedStore?.brain(story, action: "interaction", body: ["type": active ? "none" : type]) == nil { interaction = previous }
            }
        } label: {
            Label(active ? "Undo \(title.lowercased())" : title, systemImage: active ? symbol + ".fill" : symbol)
        }
    }

    private func filterButton(_ filter: WireFilter, @ViewBuilder label: () -> some View) -> some View {
        Button { feedStore?.apply(filter) } label: { label() }
            .buttonStyle(.plain)
            .padding(.vertical, 12)
            .contentShape(.rect)
            .padding(.vertical, -12)
            .accessibilityHint("Shows matching stories")
    }

    private func filterLinks(_ filters: [WireFilter], separator: String) -> Text {
        var text = AttributedString()
        for (index, filter) in filters.enumerated() {
            if index > 0 { text += AttributedString(separator) }
            var part = AttributedString(filter.title)
            part.link = filter.url
            text += part
        }
        return Text(text)
    }
}

private struct SavedStoriesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var saved = SavedStories.shared
    @State private var search = ""

    private var results: [SavedStory] { saved.search(search) }

    var body: some View {
        NavigationStack {
            List {
                if !results.isEmpty {
                    ForEach(results) { item in
                        NavigationLink(value: item.story) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.story.title).font(.headline).lineLimit(3)
                                Text("\(item.story.source) · \(item.story.publishedAt, format: .dateTime.month(.abbreviated).day().year())")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let summary = item.story.summary.nilIfEmpty {
                                    Text(StoryHTML.plainText(summary)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    .onDelete { offsets in
                        for item in offsets.map({ results[$0] }) { saved.remove(item.story) }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("No Saved Stories", systemImage: "bookmark",
                                               description: Text("Tap the bookmark on any story to keep it here for offline reading."))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search saved stories")
            .navigationDestination(for: Story.self) { StoryDetail(story: $0) }
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        }
    }
}

private struct SavedStoriesPreview: View {
    @State private var saved = SavedStories.shared
    private let fixtures = SavedStoriesPreview.fixtures

    var body: some View {
        NavigationStack {
            List {
                Section("Fixtures") {
                    ForEach(fixtures) { story in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(story.isBrain ? "BRAIN" : "WIRE").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(story.title).font(.headline)
                            }
                            Spacer()
                            Button {
                                saved.toggle(story, articleText: "Offline fixture article for \(story.title). " + String(repeating: "Verified saved text. ", count: 80))
                            } label: {
                                Image(systemName: saved.contains(story) ? "bookmark.fill" : "bookmark")
                            }
                            .accessibilityLabel(saved.contains(story) ? "Remove saved story" : "Save story")
                        }
                    }
                }
                Section("Saved (\(saved.items.count))") {
                    ForEach(saved.items) { item in
                        NavigationLink(value: item.story) {
                            VStack(alignment: .leading) {
                                Text(item.story.title)
                                Text(item.story.isBrain ? "Brain" : item.story.source).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for item in offsets.map({ saved.items[$0] }) { saved.remove(item.story) }
                    }
                }
            }
            .navigationDestination(for: Story.self) { StoryDetail(story: $0) }
            .navigationTitle("Saved Stories Preview")
        }
    }

    private static let fixtures: [Story] = [
        Story(id: "preview:ordinary", externalId: "preview:ordinary", title: "Fixture: Federal Reserve holds rates",
              summary: "A deterministic ordinary wire story for bookmark testing.", body: "Offline fixture content.", source: "Newswire Preview",
              url: URL(string: "https://example.com/newswire-preview-rates")!, publishedAt: .now, receivedAt: .now,
              category: "economy", priority: "normal", tickers: ["SPY"], tags: ["preview"], agent: "wire", imageUrl: nil),
        Story(id: "brain:preview:saved", externalId: "brain:preview:saved", title: "Fixture: Brain market signal",
              summary: "A deterministic Brain story for bookmark testing.", body: "Offline Brain fixture content.", source: "Newswire Brain Preview",
              url: URL(string: "https://example.com/newswire-preview-brain")!, publishedAt: .now, receivedAt: .now,
              category: "markets", priority: "normal", tickers: ["AAPL"], tags: ["preview"], agent: "brain", imageUrl: nil)
    ]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = .tintColor
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension Story {
    var opensInReader: Bool { (tags.contains("headlines") || (isBrain && body.isEmpty)) && ["http", "https"].contains(url.scheme?.lowercased() ?? "") }
    var matchedTopics: [String] {
        guard let match = body.firstMatch(of: /Matched watchlist: ([^.]+)\./)?.1 else { return [] }
        return match.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var hasDistinctSummary: Bool {
        let plain = StoryHTML.plainText(summary).lowercased().filter { $0.isLetter || $0.isNumber }
        let heading = title.lowercased().filter { $0.isLetter || $0.isNumber }
        return plain.count >= 25 && !heading.contains(plain) && !(plain.hasPrefix(heading) && plain.count < heading.count + 40)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("headlinesOnly") private var headlinesOnly = false
    @AppStorage("compactHome") private var compactHome = false
    @AppStorage("homeOrder") private var homeOrder = "marketsFirst"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var accentNamespace
    let store: FeedStore
    @State private var url = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Feed") {
                    Toggle("Show summaries", isOn: Binding(get: { !headlinesOnly }, set: { headlinesOnly = !$0 }))
                    Toggle("Compact dashboard", isOn: $compactHome)
                    Picker("Home order", selection: $homeOrder) {
                        Text("Markets first").tag("marketsFirst")
                        Text("News first").tag("newsFirst")
                    }
                }
                Section("Accent") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(Accent.allCases) { accent in
                                Button {
                                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.38, bounce: 0.2)) { Theme.shared.accent = accent }
                                } label: {
                                    Circle().fill(accent.color).frame(width: 34, height: 34)
                                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1) }
                                        .overlay {
                                            if Theme.shared.accent == accent {
                                                Circle().strokeBorder(accent.color, lineWidth: 2.5).padding(-5)
                                                    .matchedGeometryEffect(id: reduceMotion ? accent.rawValue : "selectedAccent", in: accentNamespace)
                                            }
                                        }
                                        .padding(5)
                                }
                                .buttonStyle(PressSpringStyle())
                                .accessibilityLabel(accent.rawValue.capitalized)
                                .accessibilityAddTraits(Theme.shared.accent == accent ? .isSelected : [])
                            }
                        }
                    }
                    .sensoryFeedback(.selection, trigger: Theme.shared.accent)
                }
                Section("Brokerage Sync") {
                    NavigationLink { BrokerageSyncView() } label: { Label("Set up Plaid", systemImage: "building.columns") }
                }
                Section("Notifications") {
                    NavigationLink { PushSettingsView() } label: { Label("Alerts and topics", systemImage: "bell.badge") }
                }
                Section("Stock Questions") {
                    NavigationLink { StockAISettings() } label: { Label("AI", systemImage: "sparkles") }
                }
                Section("Connection") {
                    NavigationLink {
                        ConnectionSettingsView(store: store)
                    } label: {
                        LabeledContent("Server URL", value: store.serverURL.isEmpty ? "Not set" : store.serverURL)
                    }
                }
                Section {
                    Text("This device proves itself to the server with a key held in its Secure Enclave, so there is no password or token to enter. The wire checks for updates every 30 seconds while foregrounded.")
                }.font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct PushSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("pushEnabled") private var pushEnabled = false
    @AppStorage("pushRegistrationStatus") private var registrationStatus = "Not enabled"
    @AppStorage("pushServerStatus") private var serverStatus = "Not synced"
    @State private var authorization = "Checking…"
    let preview: PushStatusPreview?

    init(preview: PushStatusPreview? = nil) {
        self.preview = preview
    }

    private var shownAuthorization: String { preview?.authorization ?? authorization }
    private var shownRegistration: String { preview?.registration ?? registrationStatus }
    private var shownServer: String { preview?.server ?? serverStatus }

    var body: some View {
        Form {
            Section {
                LabeledContent("iOS permission", value: shownAuthorization)
                LabeledContent("Apple registration", value: shownRegistration)
                LabeledContent("Newswire server", value: shownServer)
                Button(preview == nil && pushEnabled ? "Retry registration and sync" : "Enable alerts") {
                    Task {
                        if shownAuthorization == "Denied" {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            await UIApplication.shared.open(url)
                        } else {
                            await PushDelegate.enable()
                            await PushDelegate.syncStockAlerts()
                        }
                        await refreshAuthorization()
                    }
                }
                .disabled(preview != nil)
                if shownAuthorization == "Denied" {
                    Text("Allow notifications for Newswire in iOS Settings, then return here and retry.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Alert delivery")
            } footer: {
                Text("Alerts start only after you enable them. Stock alerts follow your held stocks; alert topics below control news alerts.")
            }
            Section("News topics") {
                NavigationLink { AlertTopicsView() } label: { Label("Choose alert topics", systemImage: "slider.horizontal.3") }
            }
        }
        .navigationTitle("Notifications")
        .task { if preview == nil { await refreshAuthorization() } }
        .onChange(of: scenePhase) { _, phase in
            guard preview == nil else { return }
            guard phase == .active else { return }
            Task {
                await refreshAuthorization()
                if authorization == "Allowed" || authorization == "Provisional" || authorization == "Temporary" {
                    pushEnabled = true
                    await PushDelegate.enable()
                    await PushDelegate.syncStockAlerts()
                }
            }
        }
        .onChange(of: pushEnabled) { _, enabled in
            guard preview == nil else { return }
            if !enabled { registrationStatus = "Not enabled" }
        }
    }

    private func refreshAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        authorization = switch status {
        case .notDetermined: "Not requested"
        case .denied: "Denied"
        case .authorized: "Allowed"
        case .provisional: "Provisional"
        case .ephemeral: "Temporary"
        @unknown default: "Unknown"
        }
    }
}

private enum PushStatusPreview {
    case denied, registrationFailed, syncFailed

    static var fromArguments: Self? {
        guard let index = CommandLine.arguments.firstIndex(of: "-notificationSetupPreview"),
              let raw = CommandLine.arguments.dropFirst(index + 1).first else { return nil }
        return switch raw {
        case "denied": .denied
        case "registration-failed": .registrationFailed
        case "sync-failed": .syncFailed
        default: nil
        }
    }

    var authorization: String {
        switch self {
        case .denied: "Denied"
        case .registrationFailed, .syncFailed: "Allowed"
        }
    }

    var registration: String {
        switch self {
        case .denied: "Not enabled"
        case .registrationFailed: "Apple registration failed: Unable to reach Apple Push Notification service."
        case .syncFailed: "Registered with Apple"
        }
    }

    var server: String {
        switch self {
        case .denied, .registrationFailed: "Not synced"
        case .syncFailed: "Sync failed: The Newswire server could not be reached."
        }
    }
}

#Preview("Notification setup") {
    NavigationStack { PushSettingsView(preview: .syncFailed) }
}

private struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let store: FeedStore
    @State private var url = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Server URL") {
                TextField("https://your-server", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                Text("This device proves itself to the server with a key held in its Secure Enclave, so there is no password or token to enter. The wire checks for updates every 30 seconds while foregrounded.")
            }.font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard cleanURL.isEmpty || NewswireAPI.validatedURL(cleanURL) != nil else {
                        error = "Use an HTTPS URL without credentials, query, or fragment."
                        return
                    }
                    store.serverURL = cleanURL
                    UserDefaults.standard.set(cleanURL, forKey: "serverURL")
                    if UserDefaults.standard.bool(forKey: "pushEnabled") {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                    dismiss()
                }
            }
        }
        .onAppear { url = store.serverURL }
    }
}
