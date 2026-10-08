import AppIntents
import SwiftUI
import WidgetKit

@main struct NewswireWidgets: WidgetBundle {
    var body: some Widget {
        PortfolioWidget()
        NewsWidget()
    }
}

struct PortfolioWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetPortfolio.kind, intent: PortfolioIntent.self, provider: PortfolioProvider()) { entry in
            PortfolioEntryView(entry: entry)
        }
        .configurationDisplayName("Portfolio")
        .description("Your portfolio value and today's change. Larger sizes add the chart, holdings, and allocation.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

struct PortfolioIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Portfolio"
    static let description = IntentDescription("Shows your portfolio value and today's change.")
}

struct PortfolioEntry: TimelineEntry {
    let date: Date
    let portfolio: WidgetPortfolio?
}

struct PortfolioEntryView: View {
    let entry: PortfolioEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        PortfolioWidgetView(portfolio: entry.portfolio, family: family)
            .containerBackground(for: .widget) {
                if family.isAccessory { Color.clear } else { Color(uiColor: .systemBackground) }
            }
            .widgetURL(URL(string: "newswire://portfolio"))
    }
}

extension WidgetFamily {
    var isAccessory: Bool { self == .accessoryInline || self == .accessoryCircular || self == .accessoryRectangular }
}

struct PortfolioProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry(date: .now, portfolio: .sample)
    }

    func snapshot(for configuration: PortfolioIntent, in context: Context) async -> PortfolioEntry {
        if context.isPreview { return PortfolioEntry(date: .now, portfolio: WidgetPortfolio.load() ?? .sample) }
        return await entry(for: context.family)
    }

    func timeline(for configuration: PortfolioIntent, in context: Context) async -> Timeline<PortfolioEntry> {
        Timeline(entries: [await entry(for: context.family)], policy: .after(WidgetMarket.nextRefresh()))
    }

    private func entry(for family: WidgetFamily) async -> PortfolioEntry {
        guard let stored = WidgetPortfolio.load() else { return PortfolioEntry(date: .now, portfolio: nil) }
        let dayFresh = (stored.fetched ?? .distantPast).timeIntervalSinceNow > -60
        if dayFresh && stored.accountingVersion == 1 && Calendar.current.isDateInToday(stored.updated) {
            return PortfolioEntry(date: .now, portfolio: stored)
        }
        let symbols = stored.holdings.map(\.symbol)
        let day = await WidgetMarket.charts(symbols, range: "1d", interval: "5m", prePost: true)
        let refreshed = stored.refreshed(day: day, month: [:])
        refreshed.save()
        return PortfolioEntry(date: .now, portfolio: refreshed)
    }
}

enum WidgetMarket {
    private struct Envelope: Decodable {
        struct Chart: Decodable { let result: [Result]? }
        struct Result: Decodable { let meta: Meta; let timestamp: [Double]?; let indicators: Indicators }
        struct Meta: Decodable { let previousClose: Double?; let chartPreviousClose: Double? }
        struct Indicators: Decodable { let quote: [Bars] }
        struct Bars: Decodable { let close: [Double?]? }
        let chart: Chart
    }

    static func charts(_ symbols: [String], range: String, interval: String, prePost: Bool) async -> [String: WidgetChart] {
        await withTaskGroup(of: (String, WidgetChart?).self) { group in
            for symbol in symbols {
                group.addTask { (symbol, try? await chart(symbol, range: range, interval: interval, prePost: prePost)) }
            }
            var found: [String: WidgetChart] = [:]
            for await (symbol, chart) in group { if let chart, !chart.points.isEmpty { found[symbol] = chart } }
            return found
        }
    }

    private static func chart(_ symbol: String, range: String, interval: String, prePost: Bool) async throws -> WidgetChart {
        var components = URLComponents(string: "https://query1.finance.yahoo.com")!
        components.path = "/v8/finance/chart/\(symbol)"
        components.queryItems = [URLQueryItem(name: "range", value: range), URLQueryItem(name: "interval", value: interval),
                                 URLQueryItem(name: "includePrePost", value: prePost ? "true" : "false")]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONDecoder().decode(Envelope.self, from: data).chart.result?.first else { throw URLError(.badServerResponse) }
        let closes = result.indicators.quote.first?.close ?? []
        let points = (result.timestamp ?? []).enumerated().compactMap { index, stamp in
            index < closes.count ? closes[index].map { WidgetPoint(date: Date(timeIntervalSince1970: stamp), value: $0) } : nil
        }
        return WidgetChart(previousClose: result.meta.previousClose ?? result.meta.chartPreviousClose, points: points)
    }

    static func nextRefresh(from now: Date = .now) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let parts = calendar.dateComponents([.weekday, .hour], from: now)
        let weekday = (2...6).contains(parts.weekday ?? 1)
        let trading = weekday && (4..<20).contains(parts.hour ?? 0)
        return now.addingTimeInterval(trading ? 15 * 60 : 60 * 60)
    }
}
