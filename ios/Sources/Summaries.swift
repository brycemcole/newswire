import Foundation
import FoundationModels
import UIKit
import WebKit

@Observable final class Summarizer {
    static let shared = Summarizer()

    /// Bumped whenever a summary, image or article text lands. Only the story detail observes it; feed rows read
    /// the dictionaries once when they are created, so a result arriving mid-scroll never re-lays out a visible row.
    private(set) var revision = 0
    @ObservationIgnored private(set) var summaries: [String: String] = [:]
    @ObservationIgnored private(set) var images: [String: URL] = [:]
    @ObservationIgnored private(set) var texts: [String: String] = [:]
    @ObservationIgnored private var stamps: [String: Date] = [:]
    /// Set by the feed while the list is moving; queued work waits for it to settle.
    @ObservationIgnored var scrolling = false
    @ObservationIgnored private var queue: [Story] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var done: Set<String> = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var saving: Task<Void, Never>?

    private nonisolated struct Cache: Codable, Sendable {
        var summaries: [String: String]
        var images: [String: URL]
        var articleText: [String: String]?
        var stamps: [String: Date]?
    }

    /// Entries older than this are dropped when the cache is read, so the file stays small and fast to load.
    private nonisolated static let retention: TimeInterval = 3 * 24 * 3600

    private init() {}

    nonisolated private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "newswire-pages-v3.json")
    }

    /// Reads the cache from disk on the concurrent pool. The feed awaits this before showing cached stories,
    /// so the first rows are created with their summaries and images already known.
    func load() async {
        if let loading { return await loading.value }
        let task = Task {
            guard let saved = await Self.read() else { return }
            for (key, value) in saved.summaries where summaries[key] == nil { summaries[key] = value }
            for (key, value) in saved.images where images[key] == nil { images[key] = value }
            for (key, value) in saved.articleText ?? [:] where texts[key] == nil { texts[key] = value }
            for (key, value) in saved.stamps ?? [:] where stamps[key] == nil { stamps[key] = value }
            revision += 1
        }
        loading = task
        await task.value
    }

    @concurrent nonisolated private static func read() async -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL), var cache = try? JSONDecoder().decode(Cache.self, from: data) else { return nil }
        let now = Date.now
        // Older caches have no stamps; start their clock now so they age out on the normal schedule.
        var stamps = cache.stamps ?? [:]
        for key in Set(cache.summaries.keys).union(cache.images.keys).union((cache.articleText ?? [:]).keys) where stamps[key] == nil { stamps[key] = now }
        let expired = Set(stamps.filter { now.timeIntervalSince($0.value) > retention }.keys)
        for key in expired {
            cache.summaries[key] = nil
            cache.images[key] = nil
            cache.articleText?[key] = nil
            stamps[key] = nil
        }
        cache.stamps = stamps
        return cache
    }

    @concurrent nonisolated private static func write(_ cache: Cache) async {
        try? JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
    }

    var available: Bool { SystemLanguageModel.default.availability == .available }

    func request(_ story: Story) {
        guard !story.isBrain else { return }
        let needsSummary = available && summaries[story.url.absoluteString] == nil
        let needsImage = story.thumbnail == nil && images[story.url.absoluteString] == nil
        guard story.opensInReader, story.url.host() != "news.google.com", needsSummary || needsImage, !done.contains(story.url.absoluteString), !queued.contains(story.url.absoluteString) else { return }
        queued.insert(story.url.absoluteString)
        queue.append(story)
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    /// Foreground work runs one story at a time, waits while the list is scrolling, and never spins up a hidden
    /// web view: that is left to the story detail (after its push animation) and to background processing.
    private func drain() async {
        await load()
        while !queue.isEmpty {
            await idle()
            let story = queue.removeFirst()
            let key = story.url.absoluteString
            if let page = await Self.page(story.url, render: false) {
                if !page.text.isEmpty { texts[key] = page.text }
                if story.thumbnail == nil, let image = page.image { images[key] = image }
                if available, summaries[key] == nil {
                    await idle()
                    if let summary = await summarize(story, article: page.text) { summaries[key] = summary }
                }
                changed(key)
            }
            done.insert(key)
            queued.remove(key)
        }
        running = false
    }

    private func idle() async {
        while scrolling {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }

    /// Fetches article text, images and summaries for the top stories ahead of time. Background refresh and
    /// overnight processing call this so the feed opens with everything ready. Stops early when cancelled.
    func prepare(_ stories: [Story], summarize wantsSummaries: Bool) async {
        await load()
        for story in stories {
            guard !Task.isCancelled else { break }
            guard !story.isBrain, story.opensInReader, story.url.host() != "news.google.com" else { continue }
            let key = story.url.absoluteString
            let needsSummary = wantsSummaries && available && summaries[key] == nil
            guard texts[key] == nil || needsSummary || (story.thumbnail == nil && images[key] == nil) else { continue }
            guard let page = await Self.page(story.url, render: false) else { continue }
            if !page.text.isEmpty { texts[key] = page.text }
            if story.thumbnail == nil, images[key] == nil, let image = page.image { images[key] = image }
            if needsSummary, !Task.isCancelled, let summary = await summarize(story, article: page.text) { summaries[key] = summary }
            changed(key)
        }
        await flush()
    }

    func remember(_ page: (text: String, image: URL?), for story: Story) {
        let key = story.url.absoluteString
        if !page.text.isEmpty { texts[key] = page.text }
        if story.thumbnail == nil, images[key] == nil, let image = page.image { images[key] = image }
        changed(key)
    }

    private func changed(_ key: String) {
        stamps[key] = .now
        revision += 1
        guard saving == nil else { return }
        // Coalesce writes: one encode of the whole cache every couple of seconds at most, off the main thread.
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

    private var snapshot: Cache { Cache(summaries: summaries, images: images, articleText: texts, stamps: stamps) }

    private func summarize(_ story: Story, article: String) async -> String? {
        guard article.count >= 400 else { return nil }
        let session = LanguageModelSession(instructions: "You summarize news articles for a news wire. Reply with exactly one plain factual sentence of at most 25 words saying what happened. Do not repeat the headline. No preamble, no opinions, no markdown.")
        do {
            let response = try await session.respond(to: "Headline: \(story.title)\n\nArticle:\n\(article)", options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 60))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    nonisolated static func page(_ url: URL, render: Bool = true) async -> (text: String, image: URL?)? {
        let url = URL(string: url.absoluteString.replacingOccurrences(of: "&amp;", with: "&")) ?? url
        let fetched = await fetched(url)
        if let fetched, fetched.complete || !render { return (fetched.text, fetched.image) }
        guard render else { return nil }
        let rendered = await RenderedPage.load(url)
        guard let fetched, !fetched.paragraphs.isEmpty else { return rendered ?? fetched.map { ($0.text, $0.image) } }
        guard let rendered, rendered.text.count > fetched.text.count else { return (fetched.text, fetched.image ?? rendered?.image) }
        return (rendered.text, rendered.image ?? fetched.image)
    }

    @concurrent nonisolated private static func fetched(_ url: URL) async -> ArticleExtractor.Result? {
        var request = URLRequest(url: url, timeoutInterval: 15)
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
      const image = document.querySelector('meta[property="og:image"], meta[name="twitter:image"]')?.content || '';
      const junk = /(^|[\\s_-])(modal|overlay|popup|paywall|regwall|cookie|consent|newsletter|subscribe|signup|login|comments?|related|recirc|promo|banner|toast|social|footer|masthead|navigation|sidebar|outbrain|taboola)([\\s_-]|$)/i;
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
      let nodes = [...document.querySelectorAll('[data-testid^="paragraph-"], [data-testid^="unordered-"] li')];
      if (!nodes.length) {
        const candidates = [...document.querySelectorAll('p')].filter((p) => clean(p).length >= 40 && !blocked(p));
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
      return JSON.stringify({ image, paragraphs: paragraphs.slice(0, 40) });
    })()
    """

    private struct Extracted: Decodable { let image: String; let paragraphs: [String] }

    static func load(_ url: URL) async -> (text: String, image: URL?)? {
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: CGRect(x: -2000, y: 0, width: 390, height: 844), configuration: configuration)
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(view)
        defer { view.stopLoading(); view.removeFromSuperview() }
        view.load(URLRequest(url: url, timeoutInterval: 20))
        var best: Extracted?
        for _ in 0..<30 {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return nil }
            guard let json = try? await view.evaluateJavaScript(extract) as? String,
                  let found = try? JSONDecoder().decode(Extracted.self, from: Data(json.utf8)) else { continue }
            best = found
            if found.paragraphs.count >= 3 { break }
        }
        guard let best, !best.paragraphs.isEmpty || !best.image.isEmpty else { return nil }
        let image = URL(string: best.image, relativeTo: url)?.absoluteURL
        let paragraphs = ArticleExtractor.clean(best.paragraphs, minimum: 30)
        return (String(paragraphs.joined(separator: "\n").prefix(6000)), image?.scheme == "https" ? image : nil)
    }
}
