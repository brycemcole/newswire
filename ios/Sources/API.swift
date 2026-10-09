import Foundation

nonisolated struct Story: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let externalId: String
    let title: String
    let summary: String
    let body: String
    let source: String
    let url: URL
    let publishedAt: Date
    let receivedAt: Date
    let category: String
    let priority: String
    let tickers: [String]
    let tags: [String]
    let agent: String
    let imageUrl: String?
    var interaction: String? = nil

    var thumbnail: URL? { imageUrl.flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil } }
    var isBrain: Bool { agent == "brain" && externalId.hasPrefix("brain:") }
}

nonisolated struct StoryPage: Codable, Sendable {
    let stories: [Story]
    let nextCursor: String?
}

nonisolated enum FeedMode: String, CaseIterable, Sendable {
    case wire, brain

    var path: String { self == .brain ? "v1/brain/stories" : "v1/stories" }
}

nonisolated enum WireFilter: Hashable, Identifiable, Sendable {
    case category(String), priority(String), source(String), ticker(String), tag(String), agent(String)

    var id: String { name + ":" + value }

    var name: String {
        switch self {
        case .category: "category"
        case .priority: "priority"
        case .source: "source"
        case .ticker: "ticker"
        case .tag: "tag"
        case .agent: "agent"
        }
    }

    var value: String {
        switch self {
        case .category(let value), .priority(let value), .source(let value), .ticker(let value), .tag(let value), .agent(let value): value
        }
    }

    var title: String {
        switch self {
        case .category(let value), .priority(let value): value.capitalized
        case .source(let value), .ticker(let value): value
        case .tag(let value): "#" + value
        case .agent(let value): value == "brain" ? "Brain" : value
        }
    }

    var symbol: String {
        switch self {
        case .category: "square.grid.2x2"
        case .priority(let value): value == "breaking" ? "bell.badge.fill" : "bell.fill"
        case .source: "newspaper"
        case .ticker: "chart.line.uptrend.xyaxis"
        case .tag: "number"
        case .agent(let value): value == "brain" ? "brain" : "person"
        }
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "newswire-filter"
        components.host = name
        components.queryItems = [URLQueryItem(name: "value", value: value)]
        return components.url
    }

    init?(url: URL) {
        guard url.scheme == "newswire-filter",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "value" })?.value,
              !value.isEmpty else { return nil }
        switch url.host() {
        case "category": self = .category(value)
        case "priority": self = .priority(value)
        case "source": self = .source(value)
        case "ticker": self = .ticker(value)
        case "tag": self = .tag(value)
        case "agent": self = .agent(value)
        default: return nil
        }
    }
}

nonisolated struct APIError: Decodable, LocalizedError {
    nonisolated struct Detail: Decodable, Sendable {
        let code: String
        let message: String
    }
    let error: Detail
    var errorDescription: String? { error.message }
}

nonisolated enum WireError: LocalizedError {
    case configuration, response, status(Int)
    var errorDescription: String? {
        switch self {
        case .configuration: "Enter an HTTPS server URL in Settings."
        case .response: "The server returned an unreadable response."
        case .status(let code): "Server request failed (\(code)). Try again."
        }
    }
}

nonisolated struct NewswireAPI: Sendable {
    let baseURL: URL

    static func validatedURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        return parts.url
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }()

    // ISO8601DateFormatter is thread-safe and expensive to create, so decoding reuses two shared instances
    // instead of building new ones for every timestamp.
    nonisolated(unsafe) private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainDates = ISO8601DateFormatter()

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.fractionalDates.date(from: value) ?? Self.plainDates.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 timestamp")
        }
        return decoder
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var result = try await sendOnce(request, refresh: false)
        if result.1.statusCode == 401 { result = try await sendOnce(request, refresh: true) }
        return result
    }

    private func sendOnce(_ request: URLRequest, refresh: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(try await Attestation.shared.token(for: baseURL, refresh: refresh))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WireError.response }
        return (data, response)
    }

    /// Runs on the concurrent pool so the network wait, JSON parsing and date decoding never touch the main thread.
    @concurrent func page(mode: FeedMode = .wire, cursor: String? = nil, limit: Int = 50, category: String, query: String, filters: [WireFilter] = []) async throws -> StoryPage {
        var components = URLComponents(url: baseURL.appending(path: mode.path), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if !category.isEmpty { items.append(URLQueryItem(name: "category", value: category)) }
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        items += filters.map { URLQueryItem(name: $0.name, value: $0.value) }
        components?.queryItems = items
        guard let url = components?.url else { throw WireError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            if let error = try? Self.decoder().decode(APIError.self, from: data) { throw error }
            throw WireError.status(response.statusCode)
        }
        return try Self.decoder().decode(StoryPage.self, from: data)
    }

    private nonisolated struct FeedCursor: Codable, Sendable {
        var wire: String?
        var brain: String?
        var wireDone = false
        var brainDone = false
    }

    /// The wire and Brain interleaved by time. A source's cursor only advances once its whole page has been shown;
    /// otherwise its older rows would land above newer rows from the other source on the next page.
    @concurrent func feedPage(cursor: String? = nil, limit: Int = 50, category: String, query: String, filters: [WireFilter] = []) async throws -> StoryPage {
        var state = cursor.flatMap { try? JSONDecoder().decode(FeedCursor.self, from: Data($0.utf8)) } ?? FeedCursor()
        let agent = filters.first { $0.name == "agent" }?.value
        if agent == "brain" { state.wireDone = true }
        if (agent != nil && agent != "brain") || filters.contains(where: { $0.name == "ticker" }) { state.brainDone = true }
        let useWire = !state.wireDone, useBrain = !state.brainDone
        let brainFilters = filters.filter { $0.name != "agent" }
        let wireCursor = state.wire, brainCursor = state.brain
        async let wireResult: StoryPage? = useWire ? page(mode: .wire, cursor: wireCursor, limit: limit, category: category, query: query, filters: filters) : nil
        async let brainResult: StoryPage? = useBrain ? page(mode: .brain, cursor: brainCursor, limit: limit, category: category, query: query, filters: brainFilters) : nil
        let brain = try? await brainResult
        let wire = try await wireResult
        let parts = [wire, brain ?? nil].compactMap { $0 }
        let cutoff = parts.filter { $0.nextCursor != nil }.compactMap { $0.stories.last?.publishedAt }.max()
        func complete(_ part: StoryPage?) -> Bool {
            guard let part, let cutoff, let oldest = part.stories.last?.publishedAt else { return true }
            return oldest >= cutoff
        }
        if let wire, complete(wire) { state.wire = wire.nextCursor; state.wireDone = wire.nextCursor == nil }
        if let brain = brain ?? nil, complete(brain) { state.brain = brain.nextCursor; state.brainDone = brain.nextCursor == nil }
        let stories = parts.flatMap(\.stories)
            .filter { cutoff == nil || $0.publishedAt >= cutoff! }
            .sorted { $0.publishedAt > $1.publishedAt }
        let next = state.wireDone && state.brainDone ? nil : (try? JSONEncoder().encode(state)).map { String(decoding: $0, as: UTF8.self) }
        return StoryPage(stories: stories, nextCursor: next)
    }

    nonisolated struct StoryEnvelope: Decodable { let story: Story }

    func brain(_ story: Story, action: String, body: [String: String] = [:]) async throws -> Story? {
        var request = URLRequest(url: baseURL.appending(path: "v1/brain/stories/\(story.id)/\(action)"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw WireError.status(response.statusCode) }
        return try? Self.decoder().decode(StoryEnvelope.self, from: data).story
    }

    func register(device: String, environment: String, symbols: [String] = [], muted: [String] = []) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/devices"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": device, "environment": environment, "stock_symbols": symbols, "muted_topics": muted])
        let (_, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw WireError.status(response.statusCode) }
    }
}

nonisolated final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
