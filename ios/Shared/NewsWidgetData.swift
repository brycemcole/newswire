import Foundation
import SwiftUI

nonisolated struct NewsItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let summary: String
    let source: String
    let published: Date
    let priority: String
    let category: String
    let tickers: [String]
    let url: URL

    var isUrgent: Bool { priority == "breaking" || priority == "urgent" }

    var link: URL {
        var components = URLComponents()
        components.scheme = "newswire"
        components.host = "story"
        components.path = "/" + id
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url ?? URL(string: "newswire://")!
    }

    var tag: (label: String, symbol: String, color: Color) {
        switch priority {
        case "breaking": return ("Breaking", "bolt.fill", .red)
        case "urgent": return ("Urgent", "exclamationmark.circle.fill", .orange)
        default:
            let style = NewsItem.categoryStyle(category)
            return (category.isEmpty ? "Latest" : category.capitalized, style.symbol, style.color)
        }
    }

    static func categoryStyle(_ category: String) -> (symbol: String, color: Color) {
        switch category {
        case "markets": ("chart.line.uptrend.xyaxis", .green)
        case "technology": ("cpu", .blue)
        case "economy": ("dollarsign.circle", .orange)
        case "politics": ("building.columns", .indigo)
        case "world": ("globe.americas", .teal)
        case "science": ("atom", .purple)
        default: ("newspaper", .gray)
        }
    }

    func age(at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(published))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

nonisolated struct WidgetNews: Codable, Sendable {
    static let kind = "News"
    static let rotationStep: TimeInterval = 10 * 60

    var stories: [NewsItem]
    var updated: Date

    /// Recent urgent stories, newest first; topped up with the latest stories so the rotation always has a few to show.
    func rotation(at now: Date) -> [NewsItem] {
        let urgent = stories.filter { $0.isUrgent && now.timeIntervalSince($0.published) < 12 * 3600 }
            .sorted { $0.published > $1.published }
        guard urgent.count < 3 else { return Array(urgent.prefix(8)) }
        let ids = Set(urgent.map(\.id))
        return urgent + stories.filter { !ids.contains($0.id) }.prefix(6 - urgent.count)
    }

    func lead(at now: Date, step: Int) -> NewsItem? {
        let rotation = rotation(at: now)
        return rotation.isEmpty ? nil : rotation[step % rotation.count]
    }

    func urgentCount(at now: Date) -> Int {
        stories.filter { $0.isUrgent && now.timeIntervalSince($0.published) < 86_400 }.count
    }

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetPortfolio.group)
    }

    /// Thumbnails were saved here by an earlier build; the widget is text-only now.
    static func removeLegacyImages() {
        guard let folder = directory?.appending(path: "news-images", directoryHint: .isDirectory) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func load() -> WidgetNews? {
        guard let url = directory?.appending(path: "news-widget.json"), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetNews.self, from: data)
    }

    func save() {
        guard let url = Self.directory?.appending(path: "news-widget.json") else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try? encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static var sample: WidgetNews {
        let now = Date.now
        let rows: [(String, String, String, String, Double, [String])] = [
            ("Fed holds rates steady but signals two cuts before year end as inflation cools and hiring slows across most sectors", "Reuters", "breaking", "economy", 4, []),
            ("Nvidia shares jump 8% after record data center revenue tops Wall Street estimates for a sixth straight quarter", "Bloomberg", "urgent", "markets", 22, ["NVDA"]),
            ("Apple unveils on-device model upgrades for iPhone", "The Verge", "normal", "technology", 48, ["AAPL"]),
            ("Oil slides as OPEC+ agrees to lift output again", "CNBC", "normal", "markets", 75, []),
            ("Senate passes stopgap funding bill hours before a government shutdown deadline, sending it to the president", "AP", "urgent", "politics", 130, []),
            ("Webb telescope spots water vapor on a distant rocky planet", "Nature", "normal", "science", 190, []),
            ("Treasury yields climb after strong jobs report", "WSJ", "normal", "markets", 240, []),
        ]
        let stories = rows.enumerated().map { index, row in
            NewsItem(id: "sample-\(index)", title: row.0,
                     summary: "A short summary of the story that gives the reader enough context to decide whether to open it.",
                     source: row.1, published: now.addingTimeInterval(-row.4 * 60), priority: row.2, category: row.3,
                     tickers: row.5, url: URL(string: "https://example.com/\(index)")!)
        }
        return WidgetNews(stories: stories, updated: now)
    }
}
