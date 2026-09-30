import SwiftUI
import WidgetKit

struct NewsWidgetView: View {
    let news: WidgetNews?
    let date: Date
    let step: Int
    let family: WidgetFamily

    var body: some View {
        if let news, let lead = news.lead(at: date, step: step) {
            let rest = news.stories.filter { $0.id != lead.id }
            switch family {
            case .accessoryInline:
                Label(lead.title, systemImage: lead.isUrgent ? "bolt.fill" : "newspaper")
            case .accessoryCircular:
                UrgentCount(count: news.urgentCount(at: date), latest: lead, date: date)
            case .accessoryRectangular:
                LockHeadline(story: lead, date: date)
            case .systemMedium:
                MediumNews(lead: lead, rest: rest, date: date)
            case .systemLarge:
                LargeNews(lead: lead, rest: rest, date: date)
            case .systemExtraLarge:
                ExtraLargeNews(lead: lead, rest: rest, date: date)
            default:
                SmallNews(story: lead, date: date)
            }
        } else {
            EmptyNews(family: family)
        }
    }
}

private struct TagLine: View {
    let story: NewsItem
    let date: Date
    var showsSource = false

    var body: some View {
        let tag = story.tag
        HStack(spacing: 4) {
            Image(systemName: tag.symbol)
            Text(tag.label).fontWeight(.semibold)
            Text("· " + story.age(at: date)).foregroundStyle(.secondary)
            if showsSource { Text("· " + story.source).foregroundStyle(.secondary).lineLimit(1) }
        }
        .font(.caption2)
        .foregroundStyle(tag.color)
    }
}

private struct StoryIcon: View {
    let story: NewsItem
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: story.tag.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(story.tag.color)
            .frame(width: size + 5)
    }
}

private struct HeadlineRow: View {
    let story: NewsItem
    let date: Date

    var body: some View {
        Link(destination: story.link) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                StoryIcon(story: story)
                VStack(alignment: .leading, spacing: 1) {
                    Text(story.title).font(.footnote.weight(.medium)).fullText()
                    Text("\(story.source) · \(story.age(at: date))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .tint(.primary)
    }
}

// MARK: Lock Screen

private struct UrgentCount: View {
    let count: Int
    let latest: NewsItem
    let date: Date

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: count > 0 ? "bolt.fill" : "newspaper").font(.system(size: 11, weight: .bold))
                Text(count > 0 ? "\(count)" : latest.age(at: date))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .widgetAccentable()
                Text(count > 0 ? "urgent" : "latest").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "\(count) urgent stories today" : "Latest story \(latest.age(at: date)) ago")
    }
}

private struct LockHeadline: View {
    let story: NewsItem
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: story.tag.symbol)
                Text(story.isUrgent ? story.tag.label.uppercased() : story.source)
                    .fontWeight(.bold)
                    .widgetAccentable()
                Text("· " + story.age(at: date))
            }
            .font(.caption2)
            .lineLimit(1)
            Text(story.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(4)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(story.link)
    }
}

// MARK: Home Screen

private struct SmallNews: View {
    let story: NewsItem
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TagLine(story: story, date: date)
            Text(story.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(9)
                .minimumScaleFactor(0.6)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(story.link)
    }
}

/// Shows as many whole rows as fit in the space left over, so no headline is ever cut off mid-sentence.
private struct FittingRows<Row: View>: View {
    let stories: [NewsItem]
    let limit: Int
    var spacing: CGFloat = 8
    @ViewBuilder let row: (NewsItem) -> Row

    var body: some View {
        let counts = Array((1...max(1, min(limit, stories.count))).reversed())
        ViewThatFits(in: .vertical) {
            ForEach(counts, id: \.self) { count in
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(stories.prefix(count)) { row($0) }
                }
            }
            Color.clear.frame(height: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct LeadHeadline: View {
    let story: NewsItem
    let font: Font
    var lines = 6

    var body: some View {
        Text(story.title)
            .font(font)
            .lineLimit(lines)
            .minimumScaleFactor(0.7)
            .leadingText()
            .layoutPriority(1)
    }
}

private struct LeadStory: View {
    let story: NewsItem
    let date: Date
    let font: Font

    var body: some View {
        Link(destination: story.link) {
            VStack(alignment: .leading, spacing: 3) {
                TagLine(story: story, date: date, showsSource: true)
                LeadHeadline(story: story, font: font, lines: 5)
            }
        }
        .tint(.primary)
        .layoutPriority(1)
    }
}

private struct MediumNews: View {
    let lead: NewsItem
    let rest: [NewsItem]
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LeadStory(story: lead, date: date, font: .headline)
            FittingRows(stories: rest, limit: 3, spacing: 5) { story in
                Link(destination: story.link) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        StoryIcon(story: story, size: 9)
                        Text(story.title).font(.caption.weight(.medium)).fullText()
                        Text(story.age(at: date)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
        }
    }
}

private struct LargeNews: View {
    let lead: NewsItem
    let rest: [NewsItem]
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LeadStory(story: lead, date: date, font: .title3.weight(.semibold))
            Divider()
            FittingRows(stories: rest, limit: 8, spacing: 9) { HeadlineRow(story: $0, date: date) }
        }
    }
}

private struct ExtraLargeNews: View {
    let lead: NewsItem
    let rest: [NewsItem]
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                LeadStory(story: lead, date: date, font: .title2.weight(.semibold))
                if !lead.tickers.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(lead.tickers.prefix(4), id: \.self) { ticker in
                            Text(ticker).font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.secondary.opacity(0.15), in: .capsule)
                        }
                    }
                }
                if rest.count > 8 {
                    Divider()
                    FittingRows(stories: Array(rest.dropFirst(8)), limit: 4, spacing: 9) { HeadlineRow(story: $0, date: date) }
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Latest").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FittingRows(stories: Array(rest.prefix(8)), limit: 8, spacing: 9) { HeadlineRow(story: $0, date: date) }
            }
            .frame(width: 330)
        }
    }
}

private struct EmptyNews: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline: Label("No stories yet", systemImage: "newspaper")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "newspaper").font(.title3)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Newswire").font(.headline)
                Text("Open the app to load stories").font(.caption).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "newspaper.fill").font(.title2).foregroundStyle(.secondary)
                Spacer()
                Text("Newswire").font(.headline)
                Text("Open the app to load the latest stories.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private extension View {
    func fullText() -> some View {
        multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    func leadingText() -> some View {
        multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}
