import SafariServices
import SwiftUI

@main struct NewswireApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push

    var body: some Scene {
        WindowGroup {
            FeedView()
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
    private(set) var seen: [String] = UserDefaults.standard.stringArray(forKey: "seenStories") ?? []

    func contains(_ story: Story) -> Bool { seen.contains(story.id) }

    func mark(_ story: Story) {
        guard !seen.contains(story.id) else { return }
        seen = Array((seen + [story.id]).suffix(2000))
        UserDefaults.standard.set(seen, forKey: "seenStories")
    }
}

@Observable final class Theme {
    static let shared = Theme()
    var accent = Accent(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .amber {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "accent") }
    }
}

struct FeedView: View {
    @Environment(\.scenePhase) private var phase
    @State private var store = FeedStore.shared
    @State private var settings = false
    @State private var markets = false
    @State private var portfolio = false
    @State private var marketPick: String?
    @State private var quoteRoute: MarketSymbol?
    @State private var watchlist = Watchlist.shared
    @State private var board = MarketBoard.shared
    @State private var watchlistExpanded = UserDefaults.standard.bool(forKey: "watchlistExpanded")
    @State private var portfolioExpanded = UserDefaults.standard.bool(forKey: "portfolioExpanded")
    @State private var dashboardFaded = false
    @State private var search = ""
    @AppStorage("headlinesOnly") private var headlinesOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pillNamespace
    private let categories = ["", "general", "markets", "technology", "economy", "politics", "world", "science"]

    private var selectionAnimation: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.38, bounce: 0.18) }

    var body: some View {
        NavigationStack(path: $store.path) {
            Group {
                List {
                    if search.isEmpty && store.filters.isEmpty {
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
                        state("CONNECT YOUR WIRE", message: "Add your HTTPS server URL and reader token to start reading.", icon: "antenna.radiowaves.left.and.right.slash")
                        Button("Open settings") { settings = true }
                    } else if store.stories.isEmpty && (store.loading || !store.hasLoaded) {
                        state("YOUR WIRE", message: "Connecting to your latest headlines.", icon: "newspaper")
                    } else if store.stories.isEmpty && !store.loading && store.error == nil && store.hasLoaded {
                        state("NO STORIES", message: "No stories match these filters. Pull to refresh or choose another category.", icon: "text.magnifyingglass")
                    }
                    if let error = store.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                            Button("Retry") { Task { await store.load(poll: !store.stories.isEmpty) } }
                        }.font(.system(.caption, design: .monospaced)).padding(.vertical, 8)
                    }
                    ForEach(store.stories) { story in
                        NavigationLink(value: story) { StoryRow(story: story, showSummary: !headlinesOnly) }
                            .id(story.id)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.visible)

                    }
                    if store.cursor != nil {
                        Button { Task { await store.load(older: true) } } label: {
                            HStack { Spacer(); Text(store.loading ? "FETCHING OLDER STORIES" : "LOAD OLDER"); Spacer() }.frame(minHeight: 44)
                        }.disabled(store.loading)
                            .task(id: store.cursor) {
                                guard store.error == nil else { return }
                                await store.load(older: true)
                            }
                    }
                }
                .listStyle(.plain)
                .listSectionSpacing(0)
                .listSectionSeparator(.hidden)
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.32), value: store.stories)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: headlinesOnly)
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .refreshable { await store.load(poll: !store.stories.isEmpty) }
                .searchable(text: $search, tokens: $store.filters, placement: .navigationBarDrawer(displayMode: .automatic), prompt: store.mode == .brain ? "Search Brain" : "Search the wire") { filter in
                    Label(filter.title, systemImage: filter.symbol)
                }
                .navigationDestination(for: Story.self) { StoryDetail(story: $0) }
                .navigationDestination(item: $quoteRoute) { QuoteDetail(symbol: $0.id) }
                .navigationTitle(store.mode.title)
                .navigationSubtitle(subtitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation(selectionAnimation) { store.switchMode() }
                        } label: {
                            Image(systemName: store.mode.symbol)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .sensoryFeedback(.selection, trigger: store.mode)
                        .accessibilityLabel(store.mode == .brain ? "Brain feed" : "Wire feed")
                        .accessibilityHint(store.mode == .brain ? "Switches to the wire" : "Switches to Brain")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { markets = true } label: { Image(systemName: "chart.line.uptrend.xyaxis") }
                            .accessibilityLabel("Markets")
                            .accessibilityHint("Look up a ticker, future, or crypto price")
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
            .sheet(isPresented: $portfolio) { PortfolioView() }
            .sheet(isPresented: $markets, onDismiss: {
                if let marketPick { quoteRoute = MarketSymbol(id: marketPick) }
                marketPick = nil
            }) {
                MarketSearchSheet { symbol in
                    marketPick = symbol
                    markets = false
                }
            }
            .task(id: store.mode.rawValue + "|" + store.category + "|" + search + "|" + store.filters.map(\.id).joined(separator: "|") + "|" + store.serverURL + "|" + store.token) {
                store.query = search.trimmingCharacters(in: .whitespacesAndNewlines)
                store.reset()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await store.load()
            }
            .task(id: phase) {
                if phase == .background { FeedStore.scheduleRefresh() }
                guard phase == .active else { return }
                if store.hasLoaded {
                    store.showLatest()
                    await store.load()
                }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await store.load(poll: true)
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
        .environment(\.feedStore, store)
        .onChange(of: watchlistExpanded) { _, value in UserDefaults.standard.set(value, forKey: "watchlistExpanded") }
        .onChange(of: portfolioExpanded) { _, value in UserDefaults.standard.set(value, forKey: "portfolioExpanded") }
    }

    private var watchlistHeader: some View {
        HomeSectionHeader("Watchlist", action: watchlist.symbols.count > 3 ? (watchlistExpanded ? "Show Less" : "Show All") : nil) {
            morphDashboard { watchlistExpanded.toggle() }
        }
    }

    private var watchlistRows: some View {
        VStack(spacing: 0) {
            if watchlist.symbols.isEmpty {
                Button { markets = true } label: {
                    Text("Tap the star on any quote to add it here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            let shown = watchlistExpanded ? watchlist.symbols : Array(watchlist.symbols.prefix(3))
            ForEach(shown, id: \.self) { symbol in
                let quote = board.quotes[symbol]
                watchlistMenu(for: symbol) {
                    MarketRow(symbol: symbol, title: quote?.name ?? " ", tag: nil, quote: quote, spark: board.sparks[symbol], inset: 16)
                }
                if symbol != shown.last { Divider().padding(.leading, 16) }
            }
        }
    }

    private var dashboard: some View {
        let stacked = watchlistExpanded || portfolioExpanded
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 8) {
                if stacked { watchlistHeader.opacity(dashboardFaded ? 0 : 1).transition(.cardSwap) }
                ZStack(alignment: .topLeading) {
                    if stacked { watchlistRows.transition(.cardSwap) } else { compactWatchlist.transition(.cardSwap) }
                }
                .opacity(dashboardFaded ? 0 : 1)
                .frame(maxWidth: .infinity, maxHeight: stacked ? nil : .infinity, alignment: .topLeading)
                .homeCard()
            }
            PortfolioCard(compact: !stacked, expanded: portfolioExpanded, contentHidden: dashboardFaded,
                          setExpanded: { value in morphDashboard { portfolioExpanded = value } }) { portfolio = true }
        }
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
            quoteRoute = MarketSymbol(id: symbol)
        }
        .buttonStyle(.plain)
    }

    /// Fades the card contents out, resizes the (empty) cards with a smooth, non-bouncy curve so the
    /// list row height doesn't overshoot, then fades the new contents in once the resize has settled.
    private func morphDashboard(_ change: @escaping () -> Void) {
        guard !reduceMotion else {
            withAnimation(.easeOut(duration: 0.15)) { change() }
            return
        }
        withAnimation(.easeOut(duration: 0.12)) { dashboardFaded = true } completion: {
            withAnimation(.dashboard(false)) { change() } completion: {
                withAnimation(.easeOut(duration: 0.2)) { dashboardFaded = false }
            }
        }
    }

    private var compactWatchlist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Watchlist").font(.headline)
            if watchlist.symbols.isEmpty {
                Button { markets = true } label: {
                    Text("Star any quote to add it here.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            ForEach(watchlist.symbols.prefix(3), id: \.self) { symbol in
                let quote = board.quotes[symbol]
                watchlistMenu(for: symbol) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(symbol).font(.subheadline.weight(.semibold).monospaced())
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(quote.map { QuoteFormat.price($0.price) } ?? "—")
                                .font(.caption.weight(.semibold))
                            Text(quote.map { QuoteFormat.percent($0.changePercent) } ?? " ")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(QuoteFormat.color(quote?.changePercent ?? 0))
                        }
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    }
                    .contentShape(.rect)
                }
            }
            if watchlist.symbols.count > 3 {
                Button("See All \(watchlist.symbols.count)") {
                    morphDashboard { watchlistExpanded = true }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.wireAccent)
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
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
    private var summarizer = Summarizer.shared

    init(story: Story, showSummary: Bool = true) {
        self.story = story
        self.showSummary = showSummary
        _largeImage = AppStorage(wrappedValue: story.priority == "breaking" || story.priority == "urgent", "largeStoryImage.\(story.id)")
    }

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if phase.error != nil {
                        details
                    } else if showSummary && largeImage {
                        VStack(alignment: .leading, spacing: 12) {
                            details
                            Color.clear
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .frame(maxHeight: 320)
                                .overlay { photo(phase.image) }
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .accessibilityHidden(true)
                        }
                    } else {
                        HStack(alignment: .center, spacing: 14) {
                            details.frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(width: 96, height: 96)
                                .overlay { photo(phase.image) }
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .accessibilityHidden(true)
                        }
                    }
                }
            } else {
                details
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if imageURL != nil && showSummary {
                Button {
                    largeImage.toggle()
                } label: {
                    Label(largeImage ? "Use thumbnail" : "Use large image", systemImage: largeImage ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
            }
            Button { feedStore?.apply(.source(story.source)) } label: { Label("More from \(story.source)", systemImage: "newspaper") }
            Link(destination: story.url) { Label("Read Source", systemImage: "safari") }
            ShareLink(item: story.url)
        }
        .task(id: story.id) { summarizer.request(story) }
    }

    private var imageURL: URL? { story.thumbnail ?? summarizer.images[story.url.absoluteString] }

    @ViewBuilder
    private func photo(_ image: Image?) -> some View {
        if let image {
            image.resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary)
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
                Text(story.source).font(.footnote.weight(.bold)).foregroundStyle(.secondary).lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
                Text(story.publishedAt.wireAge).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            headline
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if showSummary, let generated = summarizer.summaries[story.url.absoluteString] {
                Text("\(Text(Image(systemName: "text.line.3.summary")).foregroundStyle(.tertiary)) \(generated)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            } else if showSummary, story.hasDistinctSummary {
                Text(StoryHTML.plainText(story.summary)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            if !story.tickers.isEmpty {
                tickerLine
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .task(id: story.id) { QuoteStore.shared.want(story.tickers) }
            }
        }
    }

    private var tickerLine: Text {
        var line = AttributedString()
        for (index, symbol) in story.tickers.enumerated() {
            if index > 0 { line += AttributedString("  ·  ") }
            line += AttributedString(symbol)
            if let quote = QuoteStore.shared.quotes[symbol] {
                var change = AttributedString(" \(QuoteFormat.arrow(quote.changePercent))\(QuoteFormat.percent(abs(quote.changePercent)).trimmingCharacters(in: CharacterSet(charactersIn: "+")))")
                change.foregroundColor = QuoteFormat.color(quote.changePercent)
                line += change
                if let extended = quote.extended {
                    var after = AttributedString(" \(extended.session == "pre" ? "PM" : "AH") \(QuoteFormat.percent(extended.changePercent))")
                    after.foregroundColor = .secondary
                    line += after
                }
            }
        }
        return Text(line)
    }

    private var unreadPriority: String { ReadState.shared.contains(story) ? "normal" : story.priority }

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
    @State private var interaction: String?
    @State private var selectedQuote: Quote?
    private var key: String { story.url.absoluteString }
    private var quotes: [Quote] { QuoteStore.shared.quotes(for: story) }
    private var lead: String? {
        if story.isBrain && story.opensInReader && story.hasDistinctSummary { return StoryHTML.plainText(story.summary) }
        return Summarizer.shared.summaries[story.url.absoluteString]
    }
    private var inline: [Int: [Quote]] { QuoteInline.plan([lead ?? ""] + excerpt, quotes: quotes) }
    private func annotated(_ text: String, at index: Int) -> AttributedString {
        QuoteInline.annotate(text, quotes: inline[index] ?? [])
    }
    private var excerpt: [String] {
        Array((Summarizer.shared.texts[key] ?? "").split(separator: "\n").map(String.init).prefix(8))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let hero = story.thumbnail ?? Summarizer.shared.images[key] {
                    Color.clear.frame(height: 210).frame(maxWidth: .infinity)
                        .overlay {
                            AsyncImage(url: hero, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                                if let loaded = phase.image { loaded.resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
                            }
                        }
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
                            .font(.subheadline.weight(.semibold)).buttonStyle(.bordered)
                    }
                    if let topics = story.watchlistTopics {
                        Label(topics, systemImage: "scope").font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    StoryBodyView(html: story.body.isEmpty ? story.summary : story.body, quotes: quotes)
                }
                if !story.tags.isEmpty, !story.opensInReader {
                    filterLinks(story.tags.map(WireFilter.tag), separator: "  ")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
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
        .navigationDestination(item: $selectedQuote) { QuoteDetail(symbol: $0.symbol) }
        .task(id: attempt) {
            guard story.opensInReader, story.url.host() != "news.google.com", excerpt.isEmpty else { return }
            loading = true
            defer { loading = false }
            if let page = await Summarizer.page(story.url) { Summarizer.shared.remember(page, for: story) }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let filter = WireFilter(url: url) else { return .systemAction }
            feedStore?.apply(filter)
            return .handled
        })
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .onAppear {
            ReadState.shared.mark(story)
            if interaction == nil { interaction = story.interaction }
        }
        .task {
            guard story.isBrain else { return }
            _ = await feedStore?.brain(story, action: "view")
        }
        .navigationTitle("STORY").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $reading) { SafariView(url: story.url).ignoresSafeArea() }
        .toolbar {
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
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button { reading = true } label: {
                        Text("Read Source").fontWeight(.semibold).padding(.horizontal, 8)
                            .foregroundStyle(Theme.shared.accent.onColor)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color.wireAccent)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
        }
    }

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
    var watchlistTopics: String? {
        (body.firstMatch(of: /Matched watchlist: ([^.]+)\./)?.1).map { "Watchlist: " + String($0) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var accentNamespace
    let store: FeedStore
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Feed") {
                    Toggle("Show summaries", isOn: Binding(get: { !headlinesOnly }, set: { headlinesOnly = !$0 }))
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
                Section("Connection") {
                    TextField("https://your-server", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Reader token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                }
                Section {
                    Text("Use a reader token. It is stored in the Keychain on this device. The wire checks for updates every 30 seconds while foregrounded.")
                    Text("The Newswire server is preconfigured. Add your reader token to connect.")
                }.font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard cleanURL.isEmpty || NewswireAPI.validatedURL(cleanURL) != nil else {
                            error = "Use an HTTPS URL without credentials, query, or fragment."
                            return
                        }
                        do {
                            try ReaderKeychain.save(cleanToken)
                            store.serverURL = cleanURL
                            store.token = cleanToken
                            UserDefaults.standard.set(cleanURL, forKey: "serverURL")
                            UIApplication.shared.registerForRemoteNotifications()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }.onAppear { url = store.serverURL; token = store.token }
        }
    }
}
