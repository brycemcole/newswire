import BackgroundTasks
import Foundation
import Observation
import Security
import SwiftUI
import UIKit

@Observable final class FeedStore {
    static let shared = FeedStore()
    static let refreshTaskID = "com.brycecole.newswire.refresh"
    static let processingTaskID = "com.brycecole.newswire.process"

    var stories: [Story] = []
    var cursor: String?
    /// A first-page fetch is in flight.
    var loading = false
    /// An older page is in flight. Kept separate so a poll can never swallow an infinite-scroll request.
    var loadingOlder = false
    var error: String?
    var lastUpdated: Date?
    var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "https://bryce-newswire.bryce-e19.workers.dev"
    var category = ""
    var query = ""
    var filters: [WireFilter] = []
    var path = NavigationPath()
    var hasLoaded = false
    /// False until the on-disk cache has been read. The feed shows nothing, rather than a placeholder, until then.
    var restored = false
    /// Reported by the feed. New stories are only inserted while the list rests at the top, so rows the reader
    /// is looking at never move; anything that arrives while they are scrolled down waits in `pending`.
    @ObservationIgnored var atTop = true {
        didSet { if atTop && !oldValue { applyPending() } }
    }
    @ObservationIgnored private var pending: [Story] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var displayedKey = ""
    @ObservationIgnored private var restoring: Task<Void, Never>?
    /// How much of `stories` is persisted, and the cursor that continues after it. It only ever ends on a page
    /// boundary so a restored feed can keep loading older stories from exactly where the cache stops.
    @ObservationIgnored private var saved: (count: Int, cursor: String?) = (0, nil)

    private nonisolated struct PageSnapshot: Codable, Sendable {
        var stories: [Story]
        var cursor: String?
        var fetchedAt: Date?
    }

    private static var snapshots: [String: PageSnapshot] = [:]
    /// Caps that keep the cache file small enough to read in a few milliseconds.
    private static let maxSavedStories = 200
    private static let maxSnapshots = 12

    private var cacheKey: String { Self.key(serverURL: serverURL, category: category, query: query, filters: filters) }

    private static func key(serverURL: String, category: String = "", query: String = "", filters: [WireFilter] = []) -> String {
        "feed|\(serverURL)|\(category)|\(query)" + filters.map { "|" + $0.id }.joined()
    }

    init() {
        AttestKeychain.removeLegacyReaderToken()
        #if DEBUG && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        if let url = environment["NEWSWIRE_TEST_URL"],
           NewswireAPI.validatedURL(url) != nil {
            serverURL = url
            UserDefaults.standard.set(url, forKey: "serverURL")
        }
        #endif
        displayedKey = cacheKey
        restoring = Task { await restore() }
    }

    /// Resolves once the cached feed (and the summary cache its rows read) has been loaded off the main thread.
    func ready() async {
        await restoring?.value
    }

    private func restore() async {
        let summaries = Task { await Summarizer.shared.load() }
        let loaded = await Self.readSnapshots()
        await summaries.value
        for (key, value) in loaded where Self.snapshots[key] == nil { Self.snapshots[key] = value }
        restoreCache()
        restored = true
    }

    nonisolated private static func cacheFileURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "newswire-pages.json")
    }

    @concurrent nonisolated private static func readSnapshots() async -> [String: PageSnapshot] {
        guard let data = try? Data(contentsOf: cacheFileURL()),
              let decoded = try? JSONDecoder().decode([String: PageSnapshot].self, from: data) else { return [:] }
        return decoded
    }

    private func restoreCache() {
        guard stories.isEmpty, let snapshot = Self.snapshots[cacheKey] else { return }
        stories = snapshot.stories
        cursor = snapshot.cursor
        saved = (snapshot.stories.count, snapshot.cursor)
        if let fetched = snapshot.fetchedAt {
            lastUpdated = fetched
            hasLoaded = true
        }
    }

    private func remember() {
        // Search results are transient; persisting them would grow the cache with every query typed.
        guard query.isEmpty else { return }
        if saved.count > Self.maxSavedStories { saved = (Self.maxSavedStories, nil) }
        Self.snapshots[cacheKey] = PageSnapshot(stories: Array(stories.prefix(saved.count)), cursor: saved.cursor, fetchedAt: lastUpdated)
        Self.persist()
        publishWidget()
    }

    /// The widget always mirrors the unfiltered feed, whatever category or filter is on screen.
    private func publishWidget() {
        guard let feed = Self.snapshots[Self.key(serverURL: serverURL)]?.stories else { return }
        NewsWidgetFeed.publish(feed)
    }

    func story(id: String) -> Story? {
        stories.first { $0.id == id } ?? Self.snapshots.values.lazy.compactMap { $0.stories.first { $0.id == id } }.first
    }

    @discardableResult private static func persist() -> Task<Void, Never> {
        let kept = snapshots.sorted { ($0.value.fetchedAt ?? .distantPast) > ($1.value.fetchedAt ?? .distantPast) }.prefix(maxSnapshots)
        snapshots = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        let all = snapshots
        return Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(all) else { return }
            try? data.write(to: Self.cacheFileURL(), options: .atomic)
        }
    }

    // MARK: Background work

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Longer work (article text and on-device summaries for the top stories) runs while the phone is charging,
    /// so none of it competes with scrolling.
    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = .now.addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Must run before the app finishes launching. The handler is delivered on the main queue.
    static func registerProcessing() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskID, using: .main) { task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in await FeedStore.shared.process(task) }
        }
    }

    private func process(_ task: BGTask) async {
        Self.scheduleProcessing()
        let work = Task {
            await backgroundRefresh()
            let top = Array(stories.prefix(40))
            await Summarizer.shared.prepare(top, summarize: true)
            await ThumbnailLoader.shared.prefetch(thumbnailRequests(for: top))
        }
        task.expirationHandler = Self.canceller(work)
        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
    }

    /// Built outside the main actor so the system can call it from any thread.
    nonisolated private static func canceller(_ work: Task<Void, Never>) -> @Sendable () -> Void {
        { work.cancel() }
    }

    /// Called by background app refresh and by pushes. While the app is in the background the visible feed is
    /// re-ranked and replaced, so the reader opens to a fresh, settled list; while it is on screen, new stories
    /// are merged in without moving anything. Also warms the next page, images and article text.
    func backgroundRefresh() async {
        Self.scheduleRefresh()
        await ready()
        guard configured else { return }
        let active = UIApplication.shared.applicationState == .active
        await sync(active ? .merge : .replace, quiet: true)
        if !active && stories.count <= 100 { await loadOlder() }
        await Self.persist().value
        guard !Task.isCancelled else { return }
        let top = Array(stories.prefix(30))
        await ThumbnailLoader.shared.prefetch(thumbnailRequests(for: top))
        guard !Task.isCancelled else { return }
        // Article pages give images to stories without one; fetch a few, then warm those images too.
        let lead = Array(stories.prefix(12))
        await Summarizer.shared.prepare(lead, summarize: false)
        await ThumbnailLoader.shared.prefetch(thumbnailRequests(for: lead))
        publishWidget()
    }

    /// Image sizes each story will be drawn at: a thumbnail always, plus the full-width size when its row shows a large image.
    private func thumbnailRequests(for stories: [Story]) -> [(URL, CGFloat)] {
        stories.flatMap { story -> [(URL, CGFloat)] in
            guard let url = Summarizer.shared.poster(for: story) else { return [] }
            let large = UserDefaults.standard.object(forKey: "largeStoryImage.\(story.id)") as? Bool ?? (story.priority == "breaking" || story.priority == "urgent")
            return large ? [(url, ThumbnailLoader.small), (url, ThumbnailLoader.large)] : [(url, ThumbnailLoader.small)]
        }
    }

    func open(storyID: String?, feed: FeedMode, fallback: URL?) async {
        await ready()
        func find(_ list: [Story]) -> Story? {
            list.first { story in (storyID != nil && story.id == storyID) || (fallback != nil && story.url == fallback) }
        }
        let known = stories + pending + Self.snapshots.values.flatMap(\.stories)
        if let story = find(known) {
            path = NavigationPath([story])
            return
        }
        if configured, let baseURL = NewswireAPI.validatedURL(serverURL),
           let page = try? await NewswireAPI(baseURL: baseURL).page(mode: feed, category: "", query: ""),
           let story = find(page.stories) {
            path = NavigationPath([story])
        } else if let fallback {
            await UIApplication.shared.open(fallback)
        }
    }

    var configured: Bool { NewswireAPI.validatedURL(serverURL) != nil }

    func apply(_ filter: WireFilter) {
        if case .category(let value) = filter {
            category = value
        } else {
            filters = filters.filter { $0.name != filter.name } + [filter]
        }
        path = NavigationPath()
    }

    /// Switches the displayed feed to the current mode, category, search and filters, showing its cached copy at once.
    func reset() {
        guard displayedKey != cacheKey else { return }
        displayedKey = cacheKey
        generation = UUID()
        stories = []
        pending = []
        cursor = nil
        saved = (0, nil)
        hasLoaded = false
        lastUpdated = nil
        error = nil
        loading = false
        loadingOlder = false
        restoreCache()
    }

    // MARK: Loading

    enum Sync { case replace, merge }

    /// Fetches the newest page.
    /// - `.replace` re-ranks and swaps the whole list: for pull to refresh, Retry, an empty feed, and background refresh.
    /// - `.merge` never moves a row that is already shown; it inserts only unseen stories at the top (see `atTop`).
    /// `quiet` keeps automatic refreshes from flashing an error banner while cached stories are on screen.
    @discardableResult func sync(_ kind: Sync, quiet: Bool = false) async -> Bool {
        await ready()
        if kind == .replace && loading {
            // A pull should not be swallowed by a poll that happens to be in flight: wait for it. If that load just
            // succeeded, it already refreshed the feed; replacing again would reorder the list twice in a row.
            while loading {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            }
            if let lastUpdated, lastUpdated.timeIntervalSinceNow > -5 { return true }
        }
        guard configured, !loading, let baseURL = NewswireAPI.validatedURL(serverURL) else { return false }
        let current = generation
        let replacing = kind == .replace || stories.isEmpty
        loading = true
        defer { if generation == current { loading = false } }
        do {
            let page = try await first(NewswireAPI(baseURL: baseURL), limit: replacing ? 100 : 50)
            try Task.checkCancellation()
            guard generation == current else { return false }
            if replacing {
                let ranked = await rank(page.stories, query: query)
                guard generation == current else { return false }
                stories = ranked
                cursor = page.nextCursor
                pending = []
                saved = (ranked.count, page.nextCursor)
                error = nil
                lastUpdated = .now
                hasLoaded = true
                remember()
                return true
            }
            let known = Set(stories.map(\.id)).union(pending.map(\.id))
            let fresh = page.stories.filter { !known.contains($0.id) }
            error = nil
            lastUpdated = .now
            hasLoaded = true
            guard !fresh.isEmpty else { return true }
            let ranked = await rank(fresh, query: query)
            guard generation == current else { return false }
            pending = ranked + pending
            applyPending()
            return true
        } catch {
            guard generation == current, !Task.isCancelled else { return false }
            if !quiet || stories.isEmpty { self.error = Self.message(for: error) }
            return false
        }
    }

    /// First page, retried once after a second for the errors a freshly resumed app typically hits.
    private func first(_ api: NewswireAPI, limit: Int) async throws -> StoryPage {
        do {
            return try await api.feedPage(limit: limit, category: category, query: query, filters: filters)
        } catch let error as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
            try await Task.sleep(for: .seconds(1))
            return try await api.feedPage(limit: limit, category: category, query: query, filters: filters)
        }
    }

    private func applyPending() {
        guard atTop, !pending.isEmpty else { return }
        let known = Set(stories.map(\.id))
        let fresh = pending.filter { !known.contains($0.id) }
        pending = []
        guard !fresh.isEmpty else { return }
        let animation: Animation = UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.15) : .smooth(duration: 0.3)
        withAnimation(animation) { stories = fresh + stories }
        saved.count += fresh.count
        remember()
    }

    /// Appends the next page. Rows are added without animation so the list never re-lays out mid-fling.
    func loadOlder() async {
        await ready()
        guard configured, !loadingOlder, let cursor, let baseURL = NewswireAPI.validatedURL(serverURL) else { return }
        let current = generation
        loadingOlder = true
        defer { if generation == current { loadingOlder = false } }
        guard let page = try? await NewswireAPI(baseURL: baseURL).feedPage(cursor: cursor, category: category, query: query, filters: filters),
              generation == current, self.cursor == cursor else { return }
        let before = stories.count
        let ids = Set(stories.map(\.id))
        stories += page.stories.filter { !ids.contains($0.id) }
        self.cursor = page.nextCursor
        if saved.count == before && stories.count <= Self.maxSavedStories { saved = (stories.count, page.nextCursor) }
        remember()
    }

    /// The row whose appearance starts loading the next page, about fifteen rows before the end.
    var olderTriggerID: String? {
        guard cursor != nil else { return nil }
        return stories.dropLast(15).last?.id ?? stories.first?.id
    }

    private func rank(_ page: [Story], query: String) async -> [Story] {
        guard query.isEmpty else { return page }
        let symbols = Set(Watchlist.shared.symbols + PortfolioStore.shared.snapshot.positions.map(\.symbol))
        return await StoryRanking.ranked(page, symbols: symbols)
    }

    private static func message(for error: Error) -> String {
        if let network = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost].contains(network.code) {
            return "Offline or unreachable. Loaded stories remain available; pull to retry."
        }
        return error.localizedDescription
    }

    func brain(_ story: Story, action: String, body: [String: String] = [:]) async -> Story? {
        guard configured, let baseURL = NewswireAPI.validatedURL(serverURL) else { return nil }
        guard let updated = try? await NewswireAPI(baseURL: baseURL).brain(story, action: action, body: body) else { return nil }
        if let index = stories.firstIndex(where: { $0.id == updated.id }) {
            stories[index] = updated
            remember()
        }
        return updated
    }
}
