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
    var title: String { self == .brain ? "BRAIN" : "NEWSWIRE" }
    var symbol: String { self == .brain ? "brain" : "antenna.radiowaves.left.and.right" }
}

nonisolated enum WireFilter: Hashable, Identifiable, Sendable {
    case category(String), priority(String), source(String), ticker(String), tag(String)

    var id: String { name + ":" + value }

    var name: String {
        switch self {
        case .category: "category"
        case .priority: "priority"
        case .source: "source"
        case .ticker: "ticker"
        case .tag: "tag"
        }
    }

    var value: String {
        switch self {
        case .category(let value), .priority(let value), .source(let value), .ticker(let value), .tag(let value): value
        }
    }

    var title: String {
        switch self {
        case .category(let value), .priority(let value): value.capitalized
        case .source(let value), .ticker(let value): value
        case .tag(let value): "#" + value
        }
    }

    var symbol: String {
        switch self {
        case .category: "square.grid.2x2"
        case .priority(let value): value == "breaking" ? "bell.badge.fill" : "bell.fill"
        case .source: "newspaper"
        case .ticker: "chart.line.uptrend.xyaxis"
        case .tag: "number"
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
        case .configuration: "Enter an HTTPS server URL and reader token in Settings."
        case .response: "The server returned an unreadable response."
        case .status(let code): "Server request failed (\(code)). Try again."
        }
    }
}

nonisolated struct NewswireAPI: Sendable {
    let baseURL: URL
    let token: String

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
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WireError.response }
        guard (200..<300).contains(response.statusCode) else {
            if let error = try? Self.decoder().decode(APIError.self, from: data) { throw error }
            throw WireError.status(response.statusCode)
        }
        return try Self.decoder().decode(StoryPage.self, from: data)
    }

    nonisolated struct StoryEnvelope: Decodable { let story: Story }

    func brain(_ story: Story, action: String, body: [String: String] = [:]) async throws -> Story? {
        var request = URLRequest(url: baseURL.appending(path: "v1/brain/stories/\(story.id)/\(action)"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WireError.response }
        guard (200..<300).contains(response.statusCode) else { throw WireError.status(response.statusCode) }
        return try? Self.decoder().decode(StoryEnvelope.self, from: data).story
    }

    func register(device: String, environment: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/devices"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["token": device, "environment": environment])
        let (_, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WireError.response }
        guard (200..<300).contains(response.statusCode) else { throw WireError.status(response.statusCode) }
    }
}

nonisolated final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
