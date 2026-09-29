import BackgroundTasks
import Foundation
import Observation
import Security
import UIKit

enum ReaderKeychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.brycecole.newswire",
         kSecAttrAccount as String: "reader"]
    }

    static func read() -> String {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ token: String) throws {
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError() }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw KeychainError() }
        } else if status != errSecSuccess { throw KeychainError() }
    }

    struct KeychainError: LocalizedError {
        var errorDescription: String? { "Could not save the reader token securely. Please try again." }
    }
}

@Observable final class FeedStore {
    static let shared = FeedStore()
    static let refreshTaskID = "com.brycecole.newswire.refresh"

    var stories: [Story] = []
    var pending: StoryPage?
    var cursor: String?
    var loading = false
    var error: String?
    var lastUpdated: Date?
    var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "https://bryce-newswire.bryce-e19.workers.dev"
    var token = ReaderKeychain.read()
    var mode = FeedMode(rawValue: UserDefaults.standard.string(forKey: "feedMode") ?? "") ?? .wire {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "feedMode") }
    }
    var category = ""
    var query = ""
    var filters: [WireFilter] = []
    var path: [Story] = []
    var hasLoaded = false
    private var generation = UUID()
    private var displayedKey = ""

    private struct PageSnapshot: Codable {
        var stories: [Story]
        var cursor: String?
        var fetchedAt: Date?
    }

    private static var snapshots: [String: PageSnapshot] = [:]

    private var cacheKey: String { Self.key(mode: mode, serverURL: serverURL, category: category, query: query, filters: filters) }

    private static func key(mode: FeedMode, serverURL: String, category: String = "", query: String = "", filters: [WireFilter] = []) -> String {
        (mode == .wire ? "" : "brain|") + "\(serverURL)|\(category)|\(query)" + filters.map { "|" + $0.id }.joined()
    }

    init() {
        Self.loadSnapshots()
        #if DEBUG && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        if let url = environment["NEWSWIRE_TEST_URL"],
           NewswireAPI.validatedURL(url) != nil {
            serverURL = url
            UserDefaults.standard.set(url, forKey: "serverURL")
        }
        if let reader = environment["NEWSWIRE_TEST_READER_TOKEN"] {
            do {
                try ReaderKeychain.save(reader)
                token = reader
            } catch {
                self.error = "Could not save the test reader token in Keychain."
            }
        }
        #endif
        displayedKey = cacheKey
        restoreCache()
    }

    nonisolated private static func cacheFileURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "newswire-pages.json")
    }

    private static func loadSnapshots() {
        guard snapshots.isEmpty, let data = try? Data(contentsOf: cacheFileURL()),
              let decoded = try? JSONDecoder().decode([String: PageSnapshot].self, from: data) else { return }
        snapshots = decoded
    }

    func restoreCache() {
        Self.loadSnapshots()
        guard stories.isEmpty, let snapshot = Self.snapshots[cacheKey] else { return }
        stories = snapshot.stories
        cursor = snapshot.cursor
        if let fetched = snapshot.fetchedAt {
            lastUpdated = fetched
            hasLoaded = true
        }
    }

    private func remember() {
        Self.snapshots[cacheKey] = PageSnapshot(stories: stories, cursor: cursor, fetchedAt: lastUpdated)
        Self.persist()
    }

    @discardableResult private static func persist() -> Task<Void, Never> {
        let all = Self.snapshots
        return Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(all) else { return }
            try? data.write(to: Self.cacheFileURL(), options: .atomic)
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func backgroundRefresh() async {
        Self.scheduleRefresh()
        guard configured, let baseURL = NewswireAPI.validatedURL(serverURL) else { return }
        let api = NewswireAPI(baseURL: baseURL, token: token)
        for feed in FeedMode.allCases {
            let key = Self.key(mode: feed, serverURL: serverURL)
            guard key != cacheKey, let page = try? await api.page(mode: feed, category: "", query: "") else { continue }
            Self.snapshots[key] = PageSnapshot(stories: page.stories, cursor: page.nextCursor, fetchedAt: .now)
        }
        pending = nil
        await load()
        await Self.persist().value
    }

    func open(storyID: String?, feed: FeedMode, fallback: URL?) async {
        func find(_ list: [Story]) -> Story? {
            list.first { story in (storyID != nil && story.id == storyID) || (fallback != nil && story.url == fallback) }
        }
        let known = stories + (pending?.stories ?? []) + Self.snapshots.values.flatMap(\.stories)
        if let story = find(known) {
            path = [story]
            return
        }
        if configured, let baseURL = NewswireAPI.validatedURL(serverURL),
           let page = try? await NewswireAPI(baseURL: baseURL, token: token).page(mode: feed, category: "", query: ""),
           let story = find(page.stories) {
            Self.snapshots[Self.key(mode: feed, serverURL: serverURL)] = PageSnapshot(stories: page.stories, cursor: page.nextCursor, fetchedAt: .now)
            Self.persist()
            path = [story]
        } else if let fallback {
            await UIApplication.shared.open(fallback)
        }
    }

    var configured: Bool { NewswireAPI.validatedURL(serverURL) != nil && !token.isEmpty }

    func apply(_ filter: WireFilter) {
        if case .category(let value) = filter {
            category = value
        } else {
            filters = filters.filter { $0.name != filter.name } + [filter]
        }
        path = []
    }
    var newCount: Int {
        let ids = Set(stories.map(\.id))
        return pending?.stories.filter { !ids.contains($0.id) }.count ?? 0
    }

    func reset() {
        if displayedKey != cacheKey {
            stories = []
            hasLoaded = false
            lastUpdated = nil
            displayedKey = cacheKey
        }
        generation = UUID()
        pending = nil
        cursor = nil
        error = nil
        loading = false
        restoreCache()
    }

    func load(older: Bool = false, poll: Bool = false) async {
        guard configured, !loading, let baseURL = NewswireAPI.validatedURL(serverURL) else { return }
        if older && cursor == nil { return }
        let current = generation
        loading = true
        defer { if generation == current { loading = false } }
        do {
            let page = try await NewswireAPI(baseURL: baseURL, token: token).page(mode: mode, cursor: older ? cursor : nil, category: category, query: query, filters: filters)
            try Task.checkCancellation()
            guard generation == current else { return }
            error = nil
            lastUpdated = .now
            if older {
                let ids = Set(stories.map(\.id))
                stories += page.stories.filter { !ids.contains($0.id) }
                cursor = page.nextCursor
                remember()
            } else if poll && !stories.isEmpty {
                pending = page
            } else {
                stories = ranked(page.stories)
                cursor = page.nextCursor
                pending = nil
                hasLoaded = true
                remember()
            }
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            if let network = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(network.code) {
                self.error = "Offline or unreachable. Loaded stories remain available; pull to retry."
            } else { self.error = error.localizedDescription }
        }
    }

    func showLatest() {
        guard let pending else { return }
        stories = ranked(pending.stories)
        cursor = pending.nextCursor
        self.pending = nil
        remember()
    }

    private func ranked(_ page: [Story]) -> [Story] {
        guard query.isEmpty else { return page }
        let symbols = Set(Watchlist.shared.symbols + PortfolioStore.shared.snapshot.positions.map(\.symbol))
        return StoryRanking.rank(page, seen: [], symbols: symbols)
    }

    func switchMode() {
        mode = mode == .wire ? .brain : .wire
        filters = filters.filter { $0.name != "ticker" && $0.name != "agent" }
        path = []
    }

    func brain(_ story: Story, action: String, body: [String: String] = [:]) async -> Story? {
        guard configured, let baseURL = NewswireAPI.validatedURL(serverURL) else { return nil }
        guard let updated = try? await NewswireAPI(baseURL: baseURL, token: token).brain(story, action: action, body: body) else { return nil }
        if let index = stories.firstIndex(where: { $0.id == updated.id }) {
            stories[index] = updated
            remember()
        }
        return updated
    }
}
