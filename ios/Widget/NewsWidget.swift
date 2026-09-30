import AppIntents
import SwiftUI
import WidgetKit

struct NewsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetNews.kind, intent: NewsIntent.self, provider: NewsProvider()) { entry in
            NewsEntryView(entry: entry)
        }
        .configurationDisplayName("Headlines")
        .description("The latest urgent stories, rotating through the day. Larger sizes add more headlines.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

struct NewsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Headlines"
    static let description = IntentDescription("Shows the latest urgent stories.")
}

struct NewsEntry: TimelineEntry {
    let date: Date
    let step: Int
    let news: WidgetNews?
}

struct NewsEntryView: View {
    let entry: NewsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        NewsWidgetView(news: entry.news, date: entry.date, step: entry.step, family: family)
            .containerBackground(for: .widget) {
                if family.isAccessory { Color.clear } else { Color(uiColor: .systemBackground) }
            }
    }
}

struct NewsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NewsEntry {
        NewsEntry(date: .now, step: 0, news: .sample)
    }

    func snapshot(for configuration: NewsIntent, in context: Context) async -> NewsEntry {
        NewsEntry(date: .now, step: 0, news: WidgetNews.load() ?? (context.isPreview ? .sample : nil))
    }

    /// Two hours of entries that step through the urgent rotation every ten minutes. The app reloads the
    /// timeline whenever the feed changes, so new stories appear without waiting for the rotation to end.
    func timeline(for configuration: NewsIntent, in context: Context) async -> Timeline<NewsEntry> {
        let now = Date.now
        let news = WidgetNews.load()
        let entries = (0..<12).map { step in
            NewsEntry(date: now.addingTimeInterval(Double(step) * WidgetNews.rotationStep), step: step, news: news)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }
}

