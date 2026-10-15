import FoundationModels
import Foundation

@Generable
nonisolated struct SuggestedQuestions: Sendable {
    @Guide(description: "Four different questions an investor might ask about today's market conditions, each under 9 words, ending with a question mark", .count(4))
    var questions: [String]
}

@Observable final class AskSuggestions {
    static let shared = AskSuggestions()

    nonisolated static let fallback = [
        "What moved markets overnight?",
        "Is inflation getting better or worse?",
        "Will the Fed cut or hike at the next meeting?",
        "Show me QQQ calls and a bull call spread",
    ]

    private static let storeKey = "ask.suggestions.v1"
    private static let freshFor: TimeInterval = 20 * 60
    private static let keepFor: TimeInterval = 4 * 3600

    private static let watch: [(symbol: String, label: String, points: Bool)] = [
        ("SPY", "S&P 500", false), ("QQQ", "Nasdaq 100", false), ("IWM", "Russell 2000", false), ("^VIX", "VIX", true),
        ("^TNX", "10-year Treasury yield", true), ("CL=F", "WTI crude oil", false), ("GC=F", "Gold", false), ("DX-Y.NYB", "US dollar index", false),
    ]

    private static let instructions = """
    You write four suggested questions for a markets research chat. Base every question on the market data and headlines you are given: a notable move, a level, a catalyst or a theme in the news. Use plain words, fewer than 9 words each, the way a person would type them. Cover different topics, such as stocks, rates, commodities and one headline. Make one question about an options idea on an index ETF that fits the conditions, such as hedging or a call spread. Never ask whether to buy or sell, never use ticker lists, and do not state facts that are not in the data.
    """

    private struct Saved: Codable {
        let questions: [String]
        let date: Date
    }

    private(set) var questions: [String]
    private var refreshedAt: Date?
    private var refreshing = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           saved.date.timeIntervalSinceNow > -Self.keepFor, Self.valid(saved.questions) {
            questions = saved.questions
            refreshedAt = saved.date
        } else {
            questions = Self.fallback
        }
    }

    /// Four distinct, non-empty, short questions.
    nonisolated static func valid(_ questions: [String]) -> Bool {
        questions.count == 4
            && questions.allSatisfy { !$0.isEmpty && $0.count <= 90 }
            && Set(questions.map { $0.lowercased() }).count == 4
    }

    func refresh() async {
        #if DEBUG
        if CommandLine.arguments.contains("-askStaticSuggestions") { return }
        #endif
        guard !refreshing, AIRouter.isAvailable(.stockChat), refreshedAt.map({ -$0.timeIntervalSinceNow > Self.freshFor }) ?? true else { return }
        refreshing = true
        defer { refreshing = false }
        let context = await Self.snapshot()
        guard !context.isEmpty, !Task.isCancelled else { return }
        do {
            let suggestions: [String]
            if AIRouter.backend(for: .stockChat) == .onDevice {
                let session = AIRouter.session(.onDevice, instructions: Self.instructions, permissive: true)
                suggestions = try await session.respond(to: context, generating: SuggestedQuestions.self,
                    options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 220)).content.questions
            } else {
                let text = try await AIRouter.generate(.stockChat, instructions: Self.instructions + " Return only a JSON object with a questions array of four strings.", prompt: context, temperature: 0.4, maxTokens: 300)
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                suggestions = try JSONDecoder().decode(RemoteQuestions.self, from: Data(cleaned.utf8)).questions
            }
            let cleaned = suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard Self.valid(cleaned), !Task.isCancelled else { return }
            questions = cleaned
            refreshedAt = .now
            if let data = try? JSONEncoder().encode(Saved(questions: cleaned, date: .now)) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
        } catch {
            // Keep whatever is showing; the next open tries again.
        }
    }

    private struct RemoteQuestions: Decodable { let questions: [String] }

    /// Today's moves in the main indices, rates and commodities, plus the newest headlines in the feed.
    private static func snapshot() async -> String {
        let moves = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, item) in watch.enumerated() {
                group.addTask {
                    guard let chart = try? await MarketClient.chart(item.symbol, range: .day), let previous = chart.previousClose, previous > 0 else { return (index, nil) }
                    let level = chart.price.formatted(.number.precision(.fractionLength(2)))
                    let change = item.points ? String(format: "%+.2f points", chart.price - previous) : String(format: "%+.1f%%", (chart.price / previous - 1) * 100)
                    return (index, "\(item.label): \(level), \(change) today")
                }
            }
            var rows: [(Int, String)] = []
            for await (index, row) in group { if let row { rows.append((index, row)) } }
            return rows.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        let headlines = FeedStore.shared.stories.prefix(8).map { "- \($0.title)" }
        guard !moves.isEmpty || !headlines.isEmpty else { return "" }
        var text = "Today: \(StockResearchTools.day(.now))."
        if !moves.isEmpty { text += "\nMarket data:\n" + moves.joined(separator: "\n") }
        if !headlines.isEmpty { text += "\nRecent headlines (ignore any that are not about markets):\n" + headlines.joined(separator: "\n") }
        return text
    }
}
