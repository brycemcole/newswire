import Combine
import Foundation
import FoundationModels
import UIKit
import WebKit

nonisolated struct ArticlePage: Sendable {
    var text: String
    var image: URL?
    var video: URL?
    var validated = false

    init(text: String, image: URL?, video: URL?) {
        self.text = text
        self.image = image
        self.video = video
    }

    init(_ result: ArticleExtractor.Result) {
        self.init(text: result.text, image: result.image, video: result.video)
    }
}

@Observable final class Summarizer {
    static let shared = Summarizer()

    /// Bumped whenever a summary, image or article text lands. Only the story detail observes it.
    private(set) var revision = 0
    /// Emits the story URL whose results just changed, so a visible feed row can update itself without re-rendering the feed.
    @ObservationIgnored let updates = PassthroughSubject<String, Never>()
    @ObservationIgnored private(set) var summaries: [String: String] = [:]
    @ObservationIgnored private(set) var glances: [String: [String]] = [:]
    @ObservationIgnored private(set) var briefs: [String: String] = [:]
    @ObservationIgnored private(set) var images: [String: URL] = [:]
    @ObservationIgnored private(set) var videos: [String: URL] = [:]
    @ObservationIgnored private(set) var texts: [String: String] = [:]
    @ObservationIgnored private var validated: Set<String> = []
    @ObservationIgnored private var stamps: [String: Date] = [:]
    /// Set by the feed while the list is moving; results wait for it to settle before they change a row.
    @ObservationIgnored var scrolling = false
    /// Stories on screen, most recently shown first, then the stories just below them.
    @ObservationIgnored private var onScreen: [Story] = []
    @ObservationIgnored private var ahead: [Story] = []
    @ObservationIgnored private var done: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var writing: Set<String> = []
    /// Digests and briefs written from a teaser that has since been replaced by the full article. They stay on
    /// screen until the rewrite lands, so nothing blanks out while the reader is looking at it.
    @ObservationIgnored private var staleDigests: Set<String> = []
    @ObservationIgnored private var staleBriefs: Set<String> = []
    /// Stories the model declined or failed to summarize this session, so the detail stops waiting for them.
    @ObservationIgnored private(set) var unsummarizable: Set<String> = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var saving: Task<Void, Never>?
    /// Home-page preloading: full rendered articles fetched in hidden web views, highest priority first.
    @ObservationIgnored private var preloadQueue: [Story] = []
    @ObservationIgnored private var preloadAttempted: Set<String> = []
    @ObservationIgnored private var preloadPending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var preloadDomains: [String: Int] = [:]
    @ObservationIgnored private var preloadRunner: Task<Void, Never>?
    private static let preloadLimit = 3
    private static let preloadPerDomain = 1

    private nonisolated struct Cache: Codable, Sendable {
        var summaries: [String: String]
        var images: [String: URL]
        var articleText: [String: String]?
        var stamps: [String: Date]?
        var glances: [String: [String]]?
        var briefs: [String: String]?
        var videos: [String: URL]?
        var validated: Set<String>?
    }

    /// Entries older than this are dropped when the cache is read, so the file stays small and fast to load.
    private nonisolated static let retention: TimeInterval = 3 * 24 * 3600

    private init() {}

    nonisolated private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "newswire-pages-v6.json")
    }

    func load() async {
        if let loading { return await loading.value }
        let task = Task {
            guard let saved = await Self.read() else { return }
            for (key, value) in saved.summaries where summaries[key] == nil { summaries[key] = value }
            for (key, value) in saved.images where images[key] == nil { images[key] = value }
            for (key, value) in saved.articleText ?? [:] where texts[key] == nil { texts[key] = value }
            for (key, value) in saved.glances ?? [:] where glances[key] == nil { glances[key] = value }
            for (key, value) in saved.briefs ?? [:] where briefs[key] == nil { briefs[key] = value }
            for (key, value) in saved.videos ?? [:] where videos[key] == nil { videos[key] = value }
            for (key, value) in saved.stamps ?? [:] where stamps[key] == nil { stamps[key] = value }
            validated.formUnion(saved.validated ?? [])
            revision += 1
        }
        loading = task
        await task.value
    }

    @concurrent nonisolated private static func read() async -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL), var cache = try? JSONDecoder().decode(Cache.self, from: data) else { return nil }
        let now = Date.now
        var stamps = cache.stamps ?? [:]
        for key in Set(cache.summaries.keys).union(cache.images.keys).union((cache.articleText ?? [:]).keys) where stamps[key] == nil { stamps[key] = now }
        let expired = Set(stamps.filter { now.timeIntervalSince($0.value) > retention }.keys)
        for key in expired {
            cache.summaries[key] = nil
            cache.images[key] = nil
            cache.articleText?[key] = nil
            cache.glances?[key] = nil
            cache.briefs?[key] = nil
            cache.videos?[key] = nil
            stamps[key] = nil
            cache.validated?.remove(key)
        }
        cache.stamps = stamps
        return cache
    }

    @concurrent nonisolated private static func write(_ cache: Cache) async {
        try? JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
    }

    var available: Bool { AIRouter.isAvailable(.articleSummaries) }

    /// The image to show for a story: the page's own share image (or video poster), which is far larger than the feed's thumbnail.
    func poster(for story: Story) -> URL? {
        let key = story.url.absoluteString
        if let video = videos[key] {
            return images[key] ?? ArticleExtractor.youtubeID(video).flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg") } ?? story.thumbnail
        }
        return images[key] ?? story.thumbnail
    }

    private func needsWork(_ story: Story) -> Bool {
        let key = story.url.absoluteString
        guard !story.isBrain, story.opensInReader, story.url.host() != "news.google.com", !done.contains(key), !inFlight.contains(key) else { return false }
        return texts[key] == nil || (available && glances[key] == nil) || (story.thumbnail == nil && images[key] == nil)
    }

    /// Called as rows appear. On-screen stories jump the queue; `ahead` stories (just below the screen) are prepared next.
    func request(_ story: Story, ahead upcoming: Bool = false) {
        guard needsWork(story) else { return }
        if upcoming {
            guard !onScreen.contains(where: { $0.url == story.url }) else { return }
            ahead.removeAll { $0.url == story.url }
            ahead.insert(story, at: 0)
            if ahead.count > 12 { ahead.removeLast(ahead.count - 12) }
        } else {
            ahead.removeAll { $0.url == story.url }
            onScreen.removeAll { $0.url == story.url }
            onScreen.insert(story, at: 0)
        }
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    /// A row scrolled away before its turn: drop it so the queue follows the reader.
    func withdraw(_ story: Story) {
        onScreen.removeAll { $0.url == story.url }
    }

    private func nextBatch() -> [Story] {
        var batch: [Story] = []
        while batch.count < 3, !onScreen.isEmpty { batch.append(onScreen.removeFirst()) }
        while batch.count < 3, !ahead.isEmpty { batch.append(ahead.removeFirst()) }
        return batch.filter(needsWork)
    }

    /// Fetches pages three at a time (even while the list scrolls), applies them once scrolling settles, then writes digests.
    /// Hidden web views are left to the story detail and background processing.
    private func drain() async {
        await load()
        while !onScreen.isEmpty || !ahead.isEmpty {
            let batch = nextBatch()
            guard !batch.isEmpty else { continue }
            let keys = batch.map(\.url.absoluteString)
            inFlight.formUnion(keys)
            let urls = batch.map(\.url)
            let pages = await withTaskGroup(of: (Int, ArticlePage?).self) { group in
                for (index, url) in urls.enumerated() { group.addTask { (index, await Self.page(url, render: false)) } }
                var found = [ArticlePage?](repeating: nil, count: urls.count)
                for await (index, page) in group { found[index] = page }
                return found
            }
            await idle()
            for (story, page) in zip(batch, pages) {
                if let page { apply(page, for: story) }
            }
            for story in batch {
                await idle()
                await digest(story)
                done.insert(story.url.absoluteString)
            }
            inFlight.subtract(keys)
        }
        running = false
    }

    private func idle() async {
        while scrolling {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }

    /// Queues the home feed's stories for full rendered loading in hidden web views. Breaking and urgent stories go
    /// first, then feed order. At most three pages load at once and only one per site, with staggered starts, so no
    /// publisher sees a burst. Stories already holding validated text are skipped.
    func preload(_ stories: [Story]) {
        func rank(_ story: Story) -> Int { story.priority == "breaking" ? 0 : story.priority == "urgent" ? 1 : 2 }
        preloadQueue = stories.prefix(40).enumerated()
            .filter { wantsPreload($0.element) }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        guard preloadRunner == nil, !preloadQueue.isEmpty else { return }
        preloadRunner = Task {
            await load()
            await runPreload()
            preloadRunner = nil
        }
    }

    /// A preload already running for this story, so the reader can wait for it instead of opening a second web view.
    func pendingPreload(_ story: Story) -> Task<Void, Never>? { preloadPending[story.url.absoluteString] }

    private func wantsPreload(_ story: Story) -> Bool {
        let key = story.url.absoluteString
        return !story.isBrain && story.opensInReader && story.url.host() != "news.google.com"
            && !preloadAttempted.contains(key) && preloadPending[key] == nil && needsArticle(story)
    }

    private nonisolated static func domain(_ url: URL) -> String {
        let parts = (url.host()?.lowercased() ?? "").split(separator: ".")
        return parts.suffix(parts.count > 2 && ["co", "com", "org", "net", "ac"].contains(parts[parts.count - 2]) ? 3 : 2).joined(separator: ".")
    }

    private func runPreload() async {
        while !Task.isCancelled {
            preloadQueue.removeAll { !wantsPreload($0) }
            if preloadQueue.isEmpty && preloadPending.isEmpty { return }
            let active = UIApplication.shared.applicationState == .active
            if active, !scrolling, preloadPending.count < Self.preloadLimit,
               let index = preloadQueue.firstIndex(where: { preloadDomains[Self.domain($0.url), default: 0] < Self.preloadPerDomain }) {
                startPreload(preloadQueue.remove(at: index))
                // A short, uneven gap between starts so requests never arrive as a burst.
                try? await Task.sleep(for: .milliseconds(Int.random(in: 700...1500)))
            } else {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func startPreload(_ story: Story) {
        let key = story.url.absoluteString
        let domain = Self.domain(story.url)
        preloadAttempted.insert(key)
        preloadDomains[domain, default: 0] += 1
        preloadPending[key] = Task {
            if let page = await Self.page(story.url) { apply(page, for: story) }
            preloadDomains[domain, default: 1] -= 1
            preloadPending[key] = nil
        }
    }

    /// Fetches article text, images and digests for the top stories ahead of time. Background refresh and
    /// overnight processing call this so the feed opens with everything ready. Stops early when cancelled.
    func prepare(_ stories: [Story], summarize wantsSummaries: Bool) async {
        await load()
        for (index, story) in stories.enumerated() {
            guard !Task.isCancelled else { break }
            guard !story.isBrain, story.opensInReader, story.url.host() != "news.google.com" else { continue }
            let key = story.url.absoluteString
            let needsDigest = wantsSummaries && available && glances[key] == nil
            if texts[key] == nil || (story.thumbnail == nil && images[key] == nil) {
                if let page = await Self.page(story.url, render: false) { apply(page, for: story) }
            }
            if needsDigest, !Task.isCancelled { await digest(story) }
            if wantsSummaries, index < 3, !Task.isCancelled { await brief(story) }
        }
        await flush()
    }

    /// `reload` is the reader asking for a fresh copy: it replaces the text outright and rewrites the digest.
    private func apply(_ page: ArticlePage, for story: Story, reload: Bool = false) {
        let key = story.url.absoluteString
        var modified = false
        if ArticleQuality.assess(page.text) != .invalid, !validated.contains(key) || page.validated || reload {
            let current = texts[key]
            let readable = current.map { ArticleQuality.assess($0) == .usable } ?? false
            let replace: Bool
            if let current {
                if current == page.text {
                    replace = false
                } else if reload {
                    replace = true
                } else if readable {
                    // Text the reader may already be reading is only swapped for clearly more of the article.
                    replace = page.text.count >= current.count + max(600, current.count / 4)
                } else {
                    replace = (page.validated && !validated.contains(key)) || page.text.count >= current.count
                }
            } else {
                replace = true
            }
            if replace {
                if current != nil && (!readable || reload) {
                    if glances[key] != nil || summaries[key] != nil { staleDigests.insert(key) }
                    if briefs[key] != nil { staleBriefs.insert(key) }
                }
                unsummarizable.remove(key)
                texts[key] = page.text
                modified = true
            }
            if page.validated, validated.insert(key).inserted { modified = true }
        }
        if let video = page.video, videos[key] != video { videos[key] = video; modified = true }
        if images[key] == nil, let image = page.image { images[key] = image; modified = true }
        if modified { changed(key) }
    }

    func remember(_ page: ArticlePage, for story: Story, reload: Bool = false) {
        apply(page, for: story, reload: reload)
        Task { await digest(story) }
    }

    func restoreOffline(_ text: String, for story: Story) {
        let key = story.url.absoluteString
        guard texts[key] == nil, !text.isEmpty else { return }
        texts[key] = text
        changed(key)
    }

    /// One model call gives both the feed's one-line summary and the detail's "At a glance" points.
    func digest(_ story: Story) async {
        let key = story.url.absoluteString
        guard available, glances[key] == nil || staleDigests.contains(key), !unsummarizable.contains(key), let article = texts[key], article.count >= 400,
              writing.insert("digest " + key).inserted else { return }
        defer { writing.remove("digest " + key) }
        let response = try? await AIRouter.generate(.articleSummaries, instructions: """
        You write quick briefings for a news wire reader. Use only facts stated in the article. Be specific: names, numbers, dates. No opinions, no preamble, no markdown.
        Reply in exactly this format and nothing else:
        SUMMARY: one plain factual sentence of at most 25 words saying what happened, without repeating the headline
        - who is involved and exactly what happened
        - the key numbers, dates or details
        - why it matters or what happens next
        Each point is under 20 words.
        """, prompt: "Headline: \(story.title)\n\nArticle:\n\(article.prefix(6000))", temperature: 0.2, maxTokens: 220)
        guard texts[key] == article else { return }
        let lines = (response ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let summary = lines.first { $0.uppercased().hasPrefix("SUMMARY:") }.map { String($0.dropFirst(8)).trimmingCharacters(in: .whitespaces) } ?? ""
        let points = lines.filter { $0.hasPrefix("-") || $0.hasPrefix("•") || $0.hasPrefix("*") }
            .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "") }
            .filter { $0.count > 3 }
        guard !summary.isEmpty || !points.isEmpty else {
            // A failed rewrite keeps the earlier digest rather than taking it away.
            if staleDigests.remove(key) == nil { unsummarizable.insert(key) }
            changed(key)
            return
        }
        staleDigests.remove(key)
        if !summary.isEmpty { summaries[key] = summary }
        if !points.isEmpty { glances[key] = Array(points.prefix(4)) }
        changed(key)
    }

    /// The longer explanation behind "More detail". Written when a story opens, and ahead of time for the top few stories.
    func brief(_ story: Story) async {
        let key = story.url.absoluteString
        guard available, briefs[key] == nil || staleBriefs.contains(key), let article = texts[key], article.count >= 800,
              writing.insert("brief " + key).inserted else { return }
        defer { writing.remove("brief " + key) }
        guard let response = try? await AIRouter.generate(.articleSummaries, instructions: "You explain news stories for a news wire reader in two short paragraphs, 90 to 140 words in total. First paragraph: what happened, with the key names and numbers. Second paragraph: the background and what it means or what happens next. Use only facts from the article. Plain prose, no markdown, no preamble.", prompt: "Headline: \(story.title)\n\nArticle:\n\(article.prefix(6000))", temperature: 0.3, maxTokens: 280) else { return }
        guard texts[key] == article else { return }
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        staleBriefs.remove(key)
        briefs[key] = text
        changed(key)
    }

    private func changed(_ key: String) {
        stamps[key] = .now
        revision += 1
        updates.send(key)
        guard saving == nil else { return }
        saving = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saving = nil
            await Self.write(snapshot)
        }
    }

    /// Writes immediately; used before the app is suspended at the end of background work.
    func flush() async {
        saving?.cancel()
        saving = nil
        await Self.write(snapshot)
    }

    private var snapshot: Cache {
        Cache(summaries: summaries, images: images, articleText: texts, stamps: stamps, glances: glances, briefs: briefs, videos: videos, validated: validated)
    }

    /// Sites whose raw HTML carries related stories and app data that the static extractor mistakes for the article.
    /// Their text only comes from the rendered page.
    nonisolated static func rendersFirst(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return ["seekingalpha.com", "bloomberg.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func needsArticle(_ story: Story) -> Bool {
        let key = story.url.absoluteString
        guard let text = texts[key], ArticleQuality.assess(text) != .invalid else { return true }
        return !validated.contains(key)
    }

    nonisolated static func page(_ url: URL, render: Bool = true, force: Bool = false) async -> ArticlePage? {
        let url = URL(string: url.absoluteString.replacingOccurrences(of: "&amp;", with: "&")) ?? url
        return await ArticleLoader.load(render: render, rendersFirst: rendersFirst(url), fetch: { retry in
            await fetched(url, refresh: force || retry)
        }, rendered: {
            await RenderedPage.load(url, refresh: force)
        })
    }

    @concurrent nonisolated private static func fetched(_ url: URL, refresh: Bool) async -> ArticleExtractor.Result? {
        var request = URLRequest(url: url, cachePolicy: refresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let html = String(data: data.prefix(1_500_000), encoding: .utf8) ?? String(data: data.prefix(1_500_000), encoding: .isoLatin1) else { return nil }
        return ArticleExtractor.extract(html: html, baseURL: url)
    }
}

@MainActor enum RenderedPage {
    private static let extract = """
    (() => {
      if (document.querySelector('#px-captcha, [id^="px-captcha"], iframe[src*="captcha"]') || /are you a robot|verify you are human|access to this page has been denied/i.test(document.title + ' ' + (document.body?.innerText || '').slice(0, 600))) {
        return JSON.stringify({ image: '', paragraphs: [] });
      }
      const image = document.querySelector('meta[property="og:image"], meta[name="twitter:image"]')?.content || '';
      const junk = /(^|[\\s_-])(modal|overlay|popup|cookie|consent|newsletter|subscribe|signup|login|comments?|related|recirc|promo|banner|toast|social|footer|masthead|navigation|sidebar|outbrain|taboola)([\\s_-]|$)/i;
      const skip = 'script,style,noscript,svg,nav,footer,aside,form,dialog,button,figure,iframe,[role=dialog],[role=alertdialog],[aria-modal=true],[role=navigation],[role=contentinfo],[role=complementary],[hidden],[aria-hidden=true]';
      const blocked = (node) => {
        if (node.closest(skip)) return true;
        for (let el = node; el && el !== document.body; el = el.parentElement) {
          if (junk.test(`${el.id || ''} ${typeof el.className === 'string' ? el.className : ''}`)) return true;
          const position = getComputedStyle(el).position;
          if (position === 'fixed' || position === 'sticky') return true;
        }
        return false;
      };
      const clean = (node) => (node.innerText || node.textContent || '').replace(/,? opens new tab/g, '').replace(/[\\u200B-\\u200D\\u2060\\uFEFF]/g, '').replace(/\\s+/g, ' ').trim();
      const textLength = (el) => [...el.querySelectorAll('p')].reduce((sum, p) => sum + clean(p).length, 0);
      const longest = (elements) => elements.map((el) => ({ el, length: textLength(el) })).sort((a, b) => b.length - a.length)[0];
      let nodes = [...document.querySelectorAll('[data-testid^="paragraph-"], [data-testid^="unordered-"] li')];
      const container = longest(['[data-test-id="content-container"]', '[data-test-id="article-content"]', '[data-component="body-content"]', '.body-content', '[class*="body-content"]', '[itemprop="articleBody"]', '[data-testid="article-body"]', '[class*="article-body"]']
        .flatMap((selector) => [...document.querySelectorAll(selector)]).filter((el) => !blocked(el)));
      if (!nodes.length && container && container.length >= 150) {
        nodes = [...container.el.querySelectorAll('p, li')].filter((n) => !blocked(n) && !n.querySelector('div, img, picture, h1, h2, h3, h4, time'));
      }
      if (!nodes.length) {
        const article = longest([...document.querySelectorAll('article')]);
        const scope = article && article.length >= 150 ? article.el : document;
        const candidates = [...scope.querySelectorAll('p')].filter((p) => clean(p).length >= 40 && !blocked(p));
        const score = new Map();
        for (const p of candidates) {
          const length = clean(p).length;
          let el = p.parentElement;
          for (let depth = 0; el && el !== document.body && depth < 4; depth++, el = el.parentElement) {
            score.set(el, (score.get(el) || 0) + length / (depth + 1));
          }
        }
        let root = null, top = 0;
        for (const [el, value] of score) if (value > top) { top = value; root = el; }
        nodes = root ? [...root.querySelectorAll('p, li')].filter((n) => !blocked(n) && !n.querySelector('div, img, picture, h1, h2, h3, h4, time')) : candidates;
      }
      const seen = new Set();
      const paragraphs = [];
      for (const node of nodes) {
        const text = (node.tagName === 'LI' ? '• ' : '') + clean(node);
        if (text.length > 20 && !seen.has(text)) { seen.add(text); paragraphs.push(text); }
      }
      const meta = (selector) => document.querySelector(selector)?.content || '';
      let video = meta('meta[property="og:video:secure_url"]') || meta('meta[property="og:video:url"]') || meta('meta[property="og:video"]') || meta('meta[name="twitter:player:stream"]');
      if (!video) video = document.querySelector('iframe[src*="youtube.com/embed/"], iframe[src*="youtube-nocookie.com/embed/"]')?.src || '';
      if (!video) {
        for (const v of document.querySelectorAll('article video, main video')) {
          const src = v.currentSrc || v.src || v.querySelector('source')?.src || '';
          if (src && !src.startsWith('blob:')) { video = src; break; }
        }
      }
      return JSON.stringify({ image, video, paragraphs: paragraphs.slice(0, 1000) });
    })()
    """

    private struct Extracted: Decodable { let image: String; let video: String?; let paragraphs: [String] }

    static func load(_ url: URL, refresh: Bool = false) async -> ArticlePage? {
        let configuration = WKWebViewConfiguration()
        if refresh { configuration.websiteDataStore = .nonPersistent() }
        configuration.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: CGRect(x: -2000, y: 0, width: 390, height: 844), configuration: configuration)
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(view)
        defer { view.stopLoading(); view.removeFromSuperview() }
        view.load(URLRequest(url: url, cachePolicy: refresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy, timeoutInterval: 20))
        var best: Extracted?
        var bestLength = 0
        var previous = ""
        var stable = 0
        for _ in 0..<30 {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return nil }
            guard let json = try? await view.evaluateJavaScript(extract) as? String,
                  let found = try? JSONDecoder().decode(Extracted.self, from: Data(json.utf8)) else { continue }
            let text = ArticleExtractor.clean(found.paragraphs, minimum: 30).joined(separator: "\n")
            if ArticleQuality.assess(text) != .invalid,
               text.count > bestLength { best = found; bestLength = text.count }
            stable = text == previous ? stable + 1 : 0
            previous = text
            if !view.isLoading, ArticleQuality.assess(text) == .usable, stable >= 4 { break }
        }
        guard let best, !best.paragraphs.isEmpty || !best.image.isEmpty else { return nil }
        let image = URL(string: best.image, relativeTo: url)?.absoluteURL
        let paragraphs = ArticleExtractor.clean(best.paragraphs, minimum: 30)
        return ArticlePage(text: paragraphs.joined(separator: "\n"), image: image?.scheme == "https" ? image : nil,
                           video: ArticleExtractor.playable(best.video ?? "", relativeTo: url))
    }
}

#if DEBUG
extension Summarizer {
    func seedPreview(key: String, text: String, glance: [String], brief: String?) {
        texts[key] = text
        glances[key] = glance
        briefs[key] = brief
        revision += 1
    }
}
#endif
