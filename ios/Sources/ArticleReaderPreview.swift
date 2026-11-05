#if DEBUG
import SwiftUI

struct ArticleReaderPreview: View {
    let url: URL

    var body: some View {
        NavigationStack {
            StoryDetail(story: Story(id: url.absoluteString, externalId: "article-preview", title: "Article recovery test", summary: "", body: "", source: "Reader QA", url: url, publishedAt: .now, receivedAt: .now, category: "economy", priority: "normal", tickers: [], tags: ["headlines"], agent: "preview", imageUrl: nil))
        }
    }
}

struct TweetPreview: View {
    var body: some View {
        NavigationStack {
            StoryDetail(story: Story(id: "tweet-preview", externalId: "x:1", title: "US Considering Using 'Mother Of All Bombs' Against Iran, Sources Say - CNN", summary: "US Considering Using 'Mother Of All Bombs' Against Iran, Sources Say - CNN. Officials are weighing the option as talks stall, according to the report.\n\nQuoting @CNN: Exclusive: The US is considering using the GBU-43 against Iranian underground sites.", body: "Matched watchlist: geopolitical and security developments. Post by @LiveSquawk on X at 2026-10-15 04:03 UTC; topic classification establishes coverage of a topic, not the accuracy of the claim.", source: "@FT", url: URL(string: "https://x.com/FT/status/2110658629573759132")!, publishedAt: .now.addingTimeInterval(-3600), receivedAt: .now, category: "world", priority: "breaking", tickers: [], tags: ["deterministic", "x", "geopolitical-security"], agent: "preview", imageUrl: nil))
        }
    }
}

struct TweetFeedPreview: View {
    private func tweet(_ id: String, _ handle: String, _ title: String) -> Story {
        Story(id: id, externalId: "x:\(id)", title: title, summary: "", body: "Post by \(handle) on X", source: handle, url: URL(string: "https://x.com/\(handle.dropFirst())/status/\(id)")!, publishedAt: .now.addingTimeInterval(-1500), receivedAt: .now, category: "world", priority: "normal", tickers: [], tags: ["x"], agent: "preview", imageUrl: nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StoryRow(story: tweet("2110662839631331723", "@FT", "Healey promises to 'stay the path' on reducing UK deficit"))
            Divider()
            StoryRow(story: tweet("2110658629573759132", "@x", "Whilst I'm also getting DMs asking me to review profiles"))
            Divider()
            StoryRow(story: Story(id: "n", externalId: "n", title: "Fed holds rates steady", summary: "", body: "", source: "Reuters", url: URL(string: "https://example.com/n")!, publishedAt: .now.addingTimeInterval(-3000), receivedAt: .now, category: "economy", priority: "normal", tickers: [], tags: ["headlines"], agent: "preview", imageUrl: nil))
        }
        .padding(20).frame(maxHeight: .infinity, alignment: .top)
    }
}

struct StoryLayoutPreview: View {
    private static let paragraphs = (1...10).map { "<p>Paragraph \($0). Apple sued OpenAI in July, accusing it of misusing confidential Apple material. The judge ordered OpenAI to hand over hiring records, and the case continues while both sides collect more documents and testimony.</p>" }.joined()
    var body: some View {
        NavigationStack {
            StoryDetail(story: Story(id: "layout-preview", externalId: "layout-preview", title: "Judge orders OpenAI to turn over hiring records in Apple trade secrets case", summary: "", body: Self.paragraphs, source: "TechCrunch", url: URL(string: "https://example.com/layout-preview")!, publishedAt: .now, receivedAt: .now, category: "technology", priority: "urgent", tickers: ["AAPL"], tags: [], agent: "preview", imageUrl: "https://picsum.photos/seed/newswire-layout/1200/800"))
        }
    }
}

struct StoryDesignPreview: View {
    @State private var store = FeedStore()
    private static func story(_ id: String, _ title: String, source: String, minutes: Double, category: String = "economy", tickers: [String] = [], body: String = "") -> Story {
        let url = URL(string: "https://example.com/\(id)")!
        return Story(id: id, externalId: id, title: title, summary: "", body: body, source: source, url: url, publishedAt: .now.addingTimeInterval(-minutes * 60), receivedAt: .now, category: category, priority: "normal", tickers: tickers, tags: ["headlines"], agent: "preview", imageUrl: nil)
    }
    private let main = story("main", "[TEST] Fed holds rates steady, signals two cuts before year end", source: "Reuters", minutes: 42, body: "Matched watchlist: Fed, Inflation. Headline and link as published by Reuters.")

    var body: some View {
        NavigationStack {
            StoryDetail(story: main)
                .navigationDestination(for: Story.self) { StoryDetail(story: $0) }
        }
        .environment(\.feedStore, store)
        .task {
            let paragraphs = Array(repeating: "Federal Reserve officials left the benchmark rate unchanged on Wednesday, pointing to cooling inflation and a steady labor market while keeping the door open to easing later this year.", count: 6)
            Summarizer.shared.seedPreview(key: main.url.absoluteString, text: paragraphs.joined(separator: "\n"), glance: [
                "The Fed kept its benchmark rate at 4.25% to 4.5% for a fifth straight meeting.",
                "Officials now project two quarter-point cuts by December, up from one in June.",
                "Core inflation slowed to 2.6% in August, the lowest reading since 2021.",
            ], brief: CommandLine.arguments.contains("-storyDesignMore") ? "Policymakers voted 11 to 1 to hold rates. Chair Powell said the committee wants more evidence that inflation is settling before it moves.\n\nMarkets had priced in a September cut, so Treasury yields rose after the decision." : nil)
            try? await Task.sleep(for: .milliseconds(600))
            store.stories = [main,
                Self.story("a", "[TEST] Treasury yields climb as traders pare back rate-cut bets", source: "Bloomberg", minutes: 25, body: "Matched watchlist: Fed. x."),
                Self.story("b", "[TEST] Core PCE inflation cools for a third month", source: "WSJ", minutes: 180, body: "Matched watchlist: Inflation. x."),
                Self.story("c", "[TEST] Mortgage rates dip to lowest level since spring", source: "CNBC", minutes: 300),
            ]
        }
    }
}
struct ArticleMockupGallery: View {
    @State private var option = 0
    private let title = "Alphabet launches eurobond, testing AI debt markets"
    private let points = ["Alphabet launched its second euro bond sale this year.", "The offering tests investor appetite for AI debt.", "AI borrowing reached $500 billion by September."]
    private let names = ["Original", "Inset", "Immersive", "Split", "Feature"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Design", selection: $option) {
                        ForEach(0..<5) { Text("\($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    HStack { Text("OPTION \(option + 1)").font(.caption2.weight(.bold)).foregroundStyle(.secondary); Text(names[option]).font(.caption.weight(.semibold)) }
                        .padding(.horizontal, 22).padding(.bottom, 12)
                    switch option {
                    case 0: cover
                    case 1: insetCover
                    case 2: immersiveCover
                    case 3: splitCover
                    default: featureCover
                    }
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button {} label: { Image(systemName: "chevron.left") } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {} label: { Image(systemName: "message") }
                    Button {} label: { Image(systemName: "bookmark") }
                    Button {} label: { Image(systemName: "square.and.arrow.up") }
                    Button {} label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var cover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                photo(height: 380, radius: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 10) {
                    label("MARKETS")
                    Text(title).font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    metadata
                }.padding(22)
            }.frame(height: 380).clipped()
            VStack(alignment: .leading, spacing: 18) {
                quote
                Text("The story in brief").font(.title3.weight(.bold))
                Text(points[0] + " " + points[1]).font(.body).lineSpacing(4)
                Text("Read the full story  ↓").font(.subheadline.weight(.semibold)).foregroundStyle(.mint)
            }.padding(22)
        }
    }

    private var insetCover: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                photo(height: 370, radius: 22)
                LinearGradient(colors: [.clear, .black.opacity(0.94)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 10) {
                    Text("MARKETS").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                    Text(title).font(.title.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    metadata
                }.padding(20)
            }.frame(height: 370)
            quote
            Text("Summary").font(.headline)
            ForEach(points.prefix(2), id: \.self) { point in
                HStack(alignment: .top, spacing: 10) { Text("•").foregroundStyle(.secondary); Text(point).font(.callout) }
            }
            Text("Show more  ↓").font(.subheadline.weight(.semibold)).foregroundStyle(.mint)
        }.padding(.horizontal, 20).padding(.bottom, 30)
    }

    private var immersiveCover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                photo(height: 450, radius: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.98)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 12) {
                    Text("MARKETS  ·  SEMAFOR").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                    Text(title).font(.system(.largeTitle, design: .serif).weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    Text("MONDAY, NOV 2  ·  8:59 PM").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                }.padding(24)
            }.frame(height: 450).clipped()
            VStack(alignment: .leading, spacing: 18) {
                Text("Alphabet returns to the bond market as investors weigh the growing cost of the AI buildout.")
                    .font(.title3.weight(.medium)).lineSpacing(3)
                Divider()
                quote
                Text("Continue reading  ↓").font(.subheadline.weight(.semibold)).foregroundStyle(.mint)
            }.padding(24)
        }
    }

    private var splitCover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                photo(height: 300, radius: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                HStack { label("MARKETS"); Spacer(); Text("SEMAFOR  ·  8:59 PM").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8)) }
                    .padding(22)
            }.frame(height: 300).clipped()
            VStack(alignment: .leading, spacing: 17) {
                Text(title).font(.title.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                Text("Alphabet launched its second euro bond sale this year, testing investor appetite for AI debt.")
                    .font(.body).foregroundStyle(.secondary).lineSpacing(3)
                quote
                Divider()
                HStack { Text("What you need to know").font(.headline); Spacer(); Image(systemName: "chevron.down").foregroundStyle(.secondary) }
                ForEach(points.prefix(2), id: \.self) { point in Text("•  " + point).font(.callout) }
            }.padding(22)
        }
    }

    private var featureCover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                photo(height: 365, radius: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 10) {
                    Text("MARKETS").font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
                    Text(title).font(.title.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    metadata
                }.padding(22)
            }.frame(height: 365).clipped()
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("THE TAKEAWAY").font(.caption.weight(.bold)).foregroundStyle(.secondary); Spacer(); Image(systemName: "sparkle").foregroundStyle(.secondary) }
                Text("Alphabet is tapping European bond markets again as AI spending drives a historic borrowing wave.")
                    .font(.title3.weight(.semibold)).lineSpacing(2)
                Divider()
                quote
                HStack { Label("Read article", systemImage: "doc.text"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.mint)
            }.padding(20).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 30)
        }
    }

    private var brief: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) { label("MARKETS  /  BRIEFING"); Text(title).font(.title2.weight(.bold)) }
                photo(height: 88, radius: 12).frame(width: 88)
            }
            metadata
            VStack(alignment: .leading, spacing: 16) {
                Label("The takeaway", systemImage: "sparkle").font(.headline)
                Text("Alphabet is tapping European bond markets again as AI spending drives a historic borrowing wave.").font(.title3.weight(.medium))
                Divider()
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.mint).frame(width: 20, height: 20).background(.mint.opacity(0.15), in: Circle())
                        Text(point).font(.subheadline)
                    }
                }
            }.padding(20).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
            quote
            Label("Continue reading", systemImage: "arrow.down").font(.subheadline.weight(.semibold)).foregroundStyle(.mint)
        }.padding(.horizontal, 22).padding(.bottom, 30)
    }

    private var reader: some View {
        VStack(alignment: .leading, spacing: 18) {
            label("MARKETS  •  4 MIN READ")
            Text(title).font(.system(.largeTitle, design: .serif).weight(.bold)).fixedSize(horizontal: false, vertical: true)
            metadata
            Divider()
            Text("Alphabet returns to the bond market as investors weigh the growing cost of the AI buildout.")
                .font(.system(.title3, design: .serif)).foregroundStyle(.secondary).lineSpacing(3)
            photo(height: 180, radius: 4)
            Text("Alphabet launched its second euro bond sale this year, testing demand for the debt financing a new wave of AI investment.")
                .font(.system(.body, design: .serif)).lineSpacing(5)
            Text("AI borrowing reached $500 billion by September.").font(.system(.body, design: .serif)).lineSpacing(5)
        }.padding(.horizontal, 24).padding(.bottom, 30)
    }

    private var market: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { label("MARKET INTELLIGENCE"); Spacer(); Text("MON  ·  8:59 PM").font(.caption.monospaced()).foregroundStyle(.secondary) }
            Text(title).font(.title2.weight(.bold))
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) { Text("GOOG").font(.headline.monospaced()); Text("ALPHABET INC.").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) { Text("278.22").font(.title3.monospacedDigit().weight(.semibold)); Text("−1.45%   +0.62% after hours").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }.padding(16).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            photo(height: 155, radius: 10)
            HStack { Text("KEY POINTS").font(.caption.weight(.bold)); Spacer(); Text("SEMAFOR").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                HStack(alignment: .top, spacing: 14) { Text("0\(index + 1)").font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary); Text(point).font(.subheadline) }
                if index < points.count - 1 { Divider() }
            }
        }.padding(.horizontal, 20).padding(.bottom, 30)
    }

    private var journal: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "newspaper.fill").font(.headline).frame(width: 42, height: 42).background(.white.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) { Text("Semafor").font(.subheadline.weight(.semibold)); Text("Markets · Nov 2, 8:59 PM").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            Text(title).font(.title.weight(.bold))
            photo(height: 205, radius: 20)
            HStack(spacing: 8) { Image(systemName: "text.alignleft"); Text("QUICK READ").tracking(1) }.font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text("Alphabet is back in the euro bond market, testing how much debt investors will absorb as AI spending accelerates.")
                .font(.title3.weight(.medium)).lineSpacing(3)
            HStack { quote; Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.secondary) }
            Divider()
            Label("Read article", systemImage: "doc.text").font(.subheadline.weight(.semibold)).foregroundStyle(.mint)
        }.padding(.horizontal, 22).padding(.bottom, 30)
    }

    private func label(_ text: String) -> some View { Text(text).font(.caption.weight(.bold)).foregroundStyle(.secondary) }
    private var metadata: some View { HStack(spacing: 6) { Text("Semafor").fontWeight(.semibold); Text("·  Nov 2, 8:59 PM").foregroundStyle(.secondary) }.font(.subheadline) }
    private func photo(height: CGFloat, radius: CGFloat) -> some View {
        ThumbnailImage(url: URL(string: "https://picsum.photos/seed/newswire-layout/1200/800")!, size: ThumbnailLoader.large)
            .frame(maxWidth: .infinity).frame(height: height).clipped()
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityLabel("Sample article image")
    }
    private var quote: some View {
        HStack(spacing: 8) { Text("GOOG").fontWeight(.bold); Text("278.22").foregroundStyle(.secondary); Text("−1.45%").foregroundStyle(.red); Text("+0.62%").foregroundStyle(.green) }
            .font(.footnote.monospacedDigit()).padding(.horizontal, 12).padding(.vertical, 8).background(.quaternary, in: Capsule())
    }
}
#endif
