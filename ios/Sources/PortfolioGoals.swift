import Foundation

struct GoalAction: Codable, Hashable, Identifiable {
    var symbol: String
    var action: String
    var targetWeightPct: Double?
    /// Filled in by the app from the portfolio, never by the model.
    var currentWeightPct: Double?
    var reason: String
    var id: String { symbol + action }
}

struct GoalReview: Codable, Hashable {
    enum Status: String, Codable { case onTrack = "on_track", attention, action }
    var date: Date
    /// When the portfolio data behind this review was last refreshed from every brokerage; nil when that is unknown or partial.
    var portfolioAsOf: Date?
    var partialData: Bool
    var status: Status
    var headline: String
    var body: String
    var actions: [GoalAction]
    var sources: [StockSource]
    var provider: String
}

struct GoalIdea: Codable, Identifiable, Hashable {
    var id = UUID()
    var emoji: String
    var title: String
    var detail: String
    var symbol: String
    var priority = 3
    var created = Date.now
}

struct PortfolioGoal: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var created = Date.now
    var enabled = true
    var review: GoalReview?
}

@Observable final class GoalStore {
    static let shared = GoalStore()
    private(set) var goals: [PortfolioGoal] = []
    private(set) var fullReview: GoalReview?
    private(set) var ideas: [GoalIdea] = []
    private(set) var ideasUpdated: Date?
    /// Titles of ideas the owner dismissed, so the AI does not bring them back.
    private(set) var dismissed: [String] = []
    private var work: Task<Void, Never>?
    private(set) var refreshingIdeas = false
    private(set) var reviewing: Set<UUID> = []
    private(set) var reviewingFull = false
    private(set) var errors: [UUID: String] = [:]
    private(set) var fullError: String?
    /// A goal is re-reviewed when its last review is older than this and the portfolio is on screen.
    static let refreshInterval: TimeInterval = 6 * 3600
    nonisolated private static let url = URL.applicationSupportDirectory.appending(path: "portfolio-goals.json")

    private struct Saved: Codable { var goals: [PortfolioGoal]; var fullReview: GoalReview?; var ideas: [GoalIdea]?; var ideasUpdated: Date?; var dismissed: [String]? }

    init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            goals = saved.goals
            fullReview = saved.fullReview
            ideas = saved.ideas ?? []
            ideasUpdated = saved.ideasUpdated
            dismissed = saved.dismissed ?? []
        }
    }

    #if DEBUG
    func loadPreview() {
        let weights = GoalReviewer.currentWeights().sorted { $0.value > $1.value }
        let over = weights.prefix(2)
        let top = over.first
        let limit = GoalReview(date: .now.addingTimeInterval(-1800), portfolioAsOf: .now.addingTimeInterval(-600), partialData: false, status: .action,
                               headline: "\(top?.key ?? "NVDA") is \(Int(top?.value ?? 24))% of positions, over your 5% limit",
                               body: "**\(top?.key ?? "NVDA") is the largest position at \(String(format: "%.1f", top?.value ?? 24))%, above the 5% limit you set.**\n\n- Trimming it back to 5% frees about \(Money.text(((top?.value ?? 5) - 5) / 100 * PortfolioStore.shared.snapshot.totalValue)).\n- Nothing else is far over the limit.",
                               actions: over.map { GoalAction(symbol: $0.key, action: "trim", targetWeightPct: 5, currentWeightPct: $0.value, reason: "Over the 5% limit.") },
                               sources: [], provider: "Preview")
        let balance = GoalReview(date: .now.addingTimeInterval(-7200), portfolioAsOf: .now.addingTimeInterval(-600), partialData: false, status: .attention,
                                 headline: "Tech makes up most of the portfolio", body: "**Technology is about 60% of your positions.** Adding to financials or health care would balance it.",
                                 actions: [], sources: [], provider: "Preview")
        let buy = GoalReview(date: .now.addingTimeInterval(-3600), portfolioAsOf: .now.addingTimeInterval(-600), partialData: false, status: .onTrack,
                             headline: "Nothing stands out this week", body: "**No stories this week point to a buy that fits your goals.** I'll keep watching.",
                             actions: [], sources: [], provider: "Preview")
        ideas = [GoalIdea(emoji: "✂️", title: "I can show how to bring \(top?.key ?? "AAPL") back under your 5% limit",
                          detail: "\(top?.key ?? "AAPL") is \(String(format: "%.1f", top?.value ?? 5.9))% of your positions. Selling about \(Money.text(((top?.value ?? 5.9) - 5) / 100 * PortfolioStore.shared.snapshot.totalValue)) puts it at 5%, and I'd keep the cash for the second position over the limit.", symbol: top?.key ?? "AAPL", priority: 1),
                 GoalIdea(emoji: "📰", title: "I noticed three stories on NVDA since yesterday",
                          detail: "Two cover export limits and one is an analyst upgrade. NVDA is 5.3% of your portfolio, so I'd read the export story before adding.", symbol: "NVDA"),
                 GoalIdea(emoji: "📅", title: "I can watch AMD's earnings this Tuesday",
                          detail: "You hold about 5% in AMD. I'll check the results against what the options market expected and tell you if it changes your balance goal.", symbol: "AMD")]
        goals = [PortfolioGoal(text: "No single position above 5%", review: limit),
                 PortfolioGoal(text: "Keep my portfolio balanced", review: balance),
                 PortfolioGoal(text: "Find stocks worth buying", review: buy)]
    }
    #endif

    func goal(_ id: UUID) -> PortfolioGoal? { goals.first { $0.id == id } }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let goal = PortfolioGoal(text: String(trimmed.prefix(300)))
        goals.append(goal)
        persist()
        Task { await review(goal.id) }
    }

    func remove(_ id: UUID) {
        goals.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[index].enabled = enabled
        persist()
    }

    func dismissIdea(_ id: UUID) {
        if let idea = ideas.first(where: { $0.id == id }) { dismissed = Array((dismissed + [idea.title]).suffix(20)) }
        ideas.removeAll { $0.id == id }
        persist()
    }

    func refreshIdeas(force: Bool = false) async {
        guard !refreshingIdeas else { return }
        if !force, let last = ideasUpdated, -last.timeIntervalSinceNow < Self.refreshInterval { return }
        refreshingIdeas = true
        defer { refreshingIdeas = false }
        do {
            ideas = try await GoalReviewer.ideas(goals: goals.filter(\.enabled).map(\.text), dismissed: dismissed)
            ideasUpdated = .now
            persist()
        } catch {}
    }

    /// Starts the ideas and goal reviews in the background, independent of which screen is showing. A run in progress is left alone.
    func kick() {
        guard work == nil else { return }
        work = Task { [self] in
            await reviewDue()
            work = nil
        }
    }

    /// Ideas and every due goal run side by side, so the first review does not wait behind the ideas.
    func reviewDue() async {
        guard !PortfolioStore.shared.snapshot.positions.isEmpty else { return }
        let due = goals.filter { goal in
            guard goal.enabled, !reviewing.contains(goal.id) else { return false }
            if let last = goal.review?.date, -last.timeIntervalSinceNow < Self.refreshInterval { return false }
            return true
        }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshIdeas() }
            for id in due { group.addTask { await self.review(id) } }
        }
    }

    func review(_ id: UUID) async {
        guard let goal = goal(id), !reviewing.contains(id) else { return }
        reviewing.insert(id)
        errors[id] = nil
        defer { reviewing.remove(id) }
        do {
            let result = try await GoalReviewer.run(prompt: GoalReviewer.goalPrompt(goal.text), structured: true)
            guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
            goals[index].review = result
            persist()
        } catch is CancellationError {} catch {
            errors[id] = error.localizedDescription
        }
    }

    func runFullReview() async {
        guard !reviewingFull else { return }
        reviewingFull = true
        fullError = nil
        defer { reviewingFull = false }
        do {
            fullReview = try await GoalReviewer.run(prompt: GoalReviewer.fullPrompt(goals: goals.filter(\.enabled).map(\.text)), structured: false)
            persist()
        } catch is CancellationError {} catch {
            fullError = error.localizedDescription
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Saved(goals: goals, fullReview: fullReview, ideas: ideas, ideasUpdated: ideasUpdated, dismissed: dismissed)) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try? data.write(to: GoalStore.url, options: .atomic)
        }
    }
}

struct GoalReviewError: LocalizedError {
    let errorDescription: String?
}

/// Runs a goal review through the AI backend the reader configured for Ask, so it has the same research tools and stories.
@MainActor enum GoalReviewer {
    private static let goalFormat = """
    You are reviewing one portfolio goal for the owner. Output exactly two parts and nothing else. Part 1 is a fenced block with language goalreview holding one JSON object: {"status":"on_track" | "attention" | "action","headline":"under 12 words","actions":[{"symbol":"NVDA","action":"trim" | "add" | "hold" | "watch","targetWeightPct":15,"reason":"one short sentence"}]}. Use on_track when the goal is met and nothing needs doing, attention when something is drifting or worth watching, action when the owner should consider changing positions. Include an action only for positions that matter to the goal (use hold when a position near a limit should stay put, and say why); targetWeightPct is a suggested share of total positions value, or omit it. Part 2 is a message to the owner in plain markdown, under 180 words, no headings: what you found, the numbers behind it, and what you suggest. Cite news or data you used with the bracketed source number from tool results. Weights and totals in the portfolio block are computed by the app; use them as given and never recompute them. If the data is stale, partial or missing, say so and lower your confidence rather than guessing. These are suggestions for the owner to decide on, not instructions to trade.
    """

    private static let fullFormat = """
    You are writing a full portfolio review for the owner. Use markdown with these level-two headings in this order: Snapshot, Concentration and balance, What is driving results, News that matters, Goal progress, Next steps. Keep each section to a short paragraph or at most five bullets, with the figures that support it. Weights and totals in the portfolio block are computed by the app; use them as given and never recompute them. Cite news or data you used with the bracketed source number from tool results. If the data is stale, partial or missing, say so up front. Under Next steps give at most four concrete suggestions for the owner to consider, each with its reason; these are suggestions, not instructions to trade, and say nothing is guaranteed. Keep the whole review under 600 words.
    """

    private static let ideasFormat = """
    You are an assistant watching the owner's portfolio, the news and their goals, and surfacing ideas worth their attention. Output only one fenced block with language ideas holding a JSON array of at most 4 objects: {"priority":1,"title":"first person, starts with I can or I noticed, under 14 words","detail":"two or three plain sentences with the specific figures and why now","symbol":"a ticker the idea is about, or empty"}. priority is 1 to 4, 1 meaning the owner should look at it first; order the array by priority and include only what is worth their time. Every idea must be specific, checkable and drawn from the portfolio block, a story or a tool result; skip generic advice. Weights and totals in the portfolio block are computed by the app; use them as given. Never say you placed or will place a trade; you suggest and the owner decides. If nothing is worth surfacing return [].
    """

    private struct IdeaDTO: Decodable { var priority: Int?; var emoji: String?; var title: String; var detail: String?; var symbol: String? }

    static func ideas(goals: [String], dismissed: [String]) async throws -> [GoalIdea] {
        let prompt = """
        Find ideas for the owner. Their goals: \(goals.isEmpty ? "none set" : goals.map { "\"\($0)\"" }.joined(separator: "; ")). Look at concentration drift, news on held or watched symbols (read the stories that matter with wire_search or stock_news), upcoming earnings for held names (verify with tools), and candidates to buy that fit the goals.\(dismissed.isEmpty ? "" : " The owner dismissed these earlier, so do not bring them back or restate them: " + dismissed.map { "\"\($0)\"" }.joined(separator: "; ") + ".")

        \(context())
        """
        let answer = try await raw(prompt: prompt, format: ideasFormat)
        guard let match = answer.text.firstMatch(of: /```ideas\s*([\s\S]*?)```/),
              let items = try? JSONDecoder().decode([IdeaDTO].self, from: Data(String(match.1).utf8)) else { return [] }
        return items.prefix(4).map { GoalIdea(emoji: "", title: $0.title, detail: $0.detail ?? "", symbol: ($0.symbol ?? "").uppercased(), priority: $0.priority ?? 3) }.sorted { $0.priority < $1.priority }
    }

    private static func raw(prompt: String, format: String) async throws -> StockChatMessage {
        let chat = StockChat()
        chat.customFormat = format
        chat.send(prompt, symbol: "", name: "Portfolio", price: nil)
        do {
            while chat.busy { try await Task.sleep(for: .milliseconds(250)) }
        } catch {
            chat.cancel()
            throw error
        }
        if let message = chat.error { throw GoalReviewError(errorDescription: message) }
        guard let answer = chat.messages.last, !answer.user else { throw GoalReviewError(errorDescription: "The AI returned no answer.") }
        return answer
    }

    static func run(prompt: String, structured: Bool) async throws -> GoalReview {
        let answer = try await raw(prompt: prompt, format: structured ? goalFormat : fullFormat)
        let snapshot = PortfolioStore.shared.snapshot
        let partial = !(snapshot.failedItemIDs ?? []).isEmpty || snapshot.aggregateSyncedAt == nil
        var review = GoalReview(date: .now, portfolioAsOf: snapshot.aggregateSyncedAt, partialData: partial, status: .attention,
                                headline: "", body: answer.text, actions: [], sources: answer.sources, provider: answer.provider)
        if structured { parse(answer.text, into: &review) }
        return review
    }

    private struct Parsed: Decodable {
        var status: String
        var headline: String
        var actions: [GoalAction]?
    }

    private static func parse(_ text: String, into review: inout GoalReview) {
        guard let match = text.firstMatch(of: /```goalreview\s*([\s\S]*?)```/) else {
            review.headline = String(text.prefix(80))
            return
        }
        let json = String(match.1)
        let rest = text.replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        review.body = rest.isEmpty ? review.body : rest
        if let parsed = try? JSONDecoder().decode(Parsed.self, from: Data(json.utf8)) {
            review.status = GoalReview.Status(rawValue: parsed.status) ?? .attention
            review.headline = parsed.headline
            let weights = currentWeights()
            review.actions = (parsed.actions ?? []).map { action in
                var action = action
                action.symbol = action.symbol.uppercased()
                action.currentWeightPct = weights[action.symbol]
                return action
            }
        } else {
            review.headline = String(rest.prefix(80))
        }
    }

    /// Share of total valued positions per symbol, in percent.
    static func currentWeights() -> [String: Double] {
        var values: [String: Double] = [:]
        for position in PortfolioStore.shared.snapshot.positions {
            if let value = position.value { values[position.symbol, default: 0] += value }
        }
        let total = values.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return values.mapValues { $0 / total * 100 }
    }

    static func goalPrompt(_ goal: String) -> String {
        """
        Goal: \(goal)

        Review the portfolio below against this goal. If the goal implies weight limits or balance, name each affected position with its current weight and a suggested target weight, or hold it where it is. If the goal is about finding stocks to buy or being told about news, use wire_search and stock_news to find recent stories that fit the owner's holdings and the goal, read the most relevant ones, and give at most three candidates or items, each with the reason it fits. Recent stories the app already has are listed after the portfolio.

        \(context())
        """
    }

    static func fullPrompt(goals: [String]) -> String {
        """
        Write a full review of this portfolio. Owner's goals: \(goals.isEmpty ? "none set" : goals.map { "\"\($0)\"" }.joined(separator: "; ")). Use stock_news, wire_search, stock_fundamentals and quote for the largest positions and for any sector exposure you state; do not state a sector weight you did not verify.

        \(context())
        """
    }

    /// The portfolio the model reasons over: weights are computed here so the model never does the arithmetic, and data gaps are stated rather than implied.
    static func context() -> String {
        let store = PortfolioStore.shared
        let snapshot = store.snapshot
        var bySymbol: [String: (value: Double, quantity: Double)] = [:]
        var unvalued: [String] = []
        for position in snapshot.positions {
            guard let value = position.value else { unvalued.append(position.symbol); continue }
            bySymbol[position.symbol, default: (0, 0)].value += value
            bySymbol[position.symbol, default: (0, 0)].quantity += position.quantity
        }
        let total = bySymbol.values.reduce(0) { $0 + $1.value }
        let rows = bySymbol.sorted { $0.value.value > $1.value.value }.map { symbol, entry in
            let weight = total > 0 ? entry.value / total * 100 : 0
            return "\(symbol): \(String(format: "%.1f", weight))% of positions, \(Money.text(entry.value)), \(entry.quantity.formatted()) units"
        }
        var lines = ["PORTFOLIO (computed by the app, today \(Date.now.formatted(.dateTime.weekday().month().day().year())))"]
        lines.append("Total positions value \(Money.text(total)); cash \(Money.text(snapshot.cash)) (not included in weights).")
        if let synced = snapshot.aggregateSyncedAt {
            lines.append("Every brokerage last refreshed successfully at \(synced.formatted(.dateTime.month().day().hour().minute())) or later.")
        } else {
            lines.append("DATA GAP: at least one brokerage has no successful refresh time, so the oldest values may be stale.")
        }
        let failed = store.activeItems.filter { (snapshot.failedItemIDs ?? []).contains($0.id) }.map(\.institution)
        if !failed.isEmpty { lines.append("DATA GAP: \(failed.joined(separator: ", ")) failed its latest refresh; its positions are retained from an older sync.") }
        if !unvalued.isEmpty { lines.append("Positions with no current value, excluded from weights: \(unvalued.joined(separator: ", ")).") }
        lines.append(rows.isEmpty ? "No valued positions." : "Positions by weight:\n" + rows.prefix(40).joined(separator: "\n"))

        let alerts = PriceWatchStore.shared.watches.map { watch in
            "\(watch.symbol) \(watch.direction)" + (watch.target.map { " \($0)" } ?? "") + (watch.percent.map { " (\($0)% move)" } ?? "")
        }
        let asked = ChatHistory.shared.threads.prefix(8).compactMap { thread in
            thread.messages.first(where: \.user).map { String($0.text.prefix(120)) }
        }
        var signals: [String] = []
        if !Watchlist.shared.symbols.isEmpty { signals.append("Watchlist: " + Watchlist.shared.symbols.prefix(30).joined(separator: ", ")) }
        if !alerts.isEmpty { signals.append("Price alerts they set: " + alerts.prefix(12).joined(separator: "; ")) }
        if !asked.isEmpty { signals.append("What they asked the markets assistant recently: " + asked.map { "\"\($0)\"" }.joined(separator: "; ")) }
        if !signals.isEmpty { lines.append("OWNER SIGNALS (what they care about; use for relevance, do not quote back)\n" + signals.joined(separator: "\n")) }

        let held = Set(snapshot.positions.map(\.symbol)).union(Watchlist.shared.symbols)
        let cutoff = Date.now.addingTimeInterval(-72 * 3600)
        let stories = FeedStore.shared.stories
            .filter { $0.publishedAt > cutoff && !held.isDisjoint(with: $0.tickers) }
            .sorted { $0.publishedAt > $1.publishedAt }.prefix(15)
            .map { "- [\($0.tickers.filter(held.contains).joined(separator: ","))] \($0.title) (\($0.source), \($0.publishedAt.formatted(.dateTime.month().day().hour().minute()))): \($0.summary.prefix(240))" }
        lines.append(stories.isEmpty ? "No recent Newswire stories mention held or watched symbols." : "RECENT STORIES ON HELD OR WATCHED SYMBOLS (last 72 hours):\n" + stories.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }
}
