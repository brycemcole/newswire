import Foundation

nonisolated enum EconomicHistory {
    struct Observation: Codable, Hashable, Sendable {
        let date: String
        let value: Double
    }
    struct Snapshot: Codable, Sendable {
        let fetched: Date
        let observations: [Observation]
    }
    enum Window: String, CaseIterable, Identifiable, Sendable {
        case year = "1Y", five = "5Y", ten = "10Y", all = "All"
        var id: String { rawValue }
        var years: Int? { switch self { case .year: 1; case .five: 5; case .ten: 10; case .all: nil } }
    }

    @concurrent static func load(_ id: String) async throws -> Snapshot {
        guard id.range(of: #"^[A-Z0-9_]{2,40}$"#, options: .regularExpression) != nil else { throw WireError.configuration }
        let file = URL.cachesDirectory.appending(path: "economic-history-\(id).json")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        if let saved, saved.fetched.timeIntervalSinceNow > -3600 { return saved }
        var url = URLComponents(string: "https://fred.stlouisfed.org/graph/fredgraph.csv")!
        url.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "cosd", value: "1776-07-04")]
        var request = URLRequest(url: url.url!, timeoutInterval: 30)
        request.setValue("text/csv", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw WireError.status((response as? HTTPURLResponse)?.statusCode ?? 0) }
            let observations = parse(String(decoding: data, as: UTF8.self), id: id)
            guard !observations.isEmpty else { throw WireError.configuration }
            let snapshot = Snapshot(fetched: .now, observations: observations)
            try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            return snapshot
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let saved { return saved }
            throw error
        }
    }

    static func parse(_ csv: String, id: String) -> [Observation] {
        let lines = csv.split(whereSeparator: \.isNewline)
        guard let heading = lines.first, heading.split(separator: ",").last == Substring(id) else { return [] }
        return lines.dropFirst().compactMap { line in
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cells.count == 2, DataFormat.date(String(cells[0])) != nil, let value = Double(cells[1]), value.isFinite else { return nil }
            return Observation(date: String(cells[0]), value: value)
        }.sorted { $0.date < $1.date }
    }

    static func points(_ observations: [Observation], transform: String) -> [DataPayload.Point] {
        let calendar = Calendar(identifier: .gregorian)
        let byDate = Dictionary(observations.map { ($0.date, $0.value) }, uniquingKeysWith: { _, last in last })
        return observations.enumerated().compactMap { index, observation in
            switch transform {
            case "diff":
                guard index > 0 else { return nil }
                return DataPayload.Point(x: observation.date, value: observation.value - observations[index - 1].value)
            case "yoy":
                guard let date = DataFormat.date(observation.date), let yearAgo = calendar.date(byAdding: .year, value: -1, to: date) else { return nil }
                let key = yearAgo.formatted(.iso8601.year().month().day().dateSeparator(.dash))
                guard let base = byDate[key], base != 0 else { return nil }
                return DataPayload.Point(x: observation.date, value: (observation.value / base - 1) * 100)
            default: return DataPayload.Point(x: observation.date, value: observation.value)
            }
        }
    }

    @concurrent static func prepare(_ observations: [Observation], transform: String) async -> [DataPayload.Point] {
        points(observations, transform: transform)
    }

    static func visible(_ points: [DataPayload.Point], window: Window) -> [DataPayload.Point] {
        guard let years = window.years, let last = points.last, let date = DataFormat.date(last.x), let start = Calendar(identifier: .gregorian).date(byAdding: .year, value: -years, to: date) else { return points }
        let key = start.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return points.filter { $0.x >= key }
    }

    static func chart(_ points: [DataPayload.Point], limit: Int = 600) -> [DataPayload.Point] {
        guard points.count > limit else { return points }
        let stride = Double(points.count - 1) / Double(limit - 1)
        return (0..<limit).map { points[Int((Double($0) * stride).rounded())] }
    }
}
