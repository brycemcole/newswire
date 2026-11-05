import Charts
import SwiftUI

extension GoalReview.Status {
    var color: Color {
        switch self {
        case .onTrack: .green
        case .attention: .orange
        case .action: .red
        }
    }
    var label: String {
        switch self {
        case .onTrack: "On track"
        case .attention: "Worth a look"
        case .action: "Needs a decision"
        }
    }
}

enum GoalIdeas {
    static let all = ["Keep my portfolio balanced", "Don't let any stock pass 20%", "Find stocks worth buying", "Tell me when news hits my holdings"]
}

private struct StatusPill: View {
    let review: GoalReview

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(review.status.color).frame(width: 8, height: 8)
            Text(review.status.label).font(.subheadline.weight(.medium))
        }
    }
}

/// The full goals and ideas lists, shown on their own screen.
struct GoalsListSections: View {
    @State private var goals = GoalStore.shared
    @State private var adding = false
    @State private var showAllIdeas = false

    var body: some View {
        Group {
            Section {
                ForEach(goals.goals.sorted { $0.severity > $1.severity }) { goal in
                    NavigationLink { GoalDetailView(id: goal.id) } label: {
                        GoalRow(goal: goal, busy: goals.reviewing.contains(goal.id), error: goals.errors[goal.id])
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { goals.remove(goal.id) }
                        Button(goal.enabled ? "Pause" : "Resume") { goals.setEnabled(goal.id, !goal.enabled) }.tint(.gray)
                    }
                }
                Button("Create a goal") { adding = true }
            } header: {
                Text("Goals")
            } footer: {
                if goals.goals.isEmpty { Text("Say what you want from this portfolio, like \"no stock above 20%\" or \"tell me when news hits what I own\", and it is watched for you.") }
            }
            Section {
                ForEach(showAllIdeas ? goals.ideas : Array(goals.ideas.prefix(3))) { idea in
                    IdeaRow(idea: idea)
                }
                if goals.ideas.count > 3 && !showAllIdeas { Button("\(goals.ideas.count - 3) more") { showAllIdeas = true } }
                NavigationLink { FullReviewView() } label: {
                    Text("I can write a full review of your portfolio")
                }
                if goals.ideas.isEmpty && goals.refreshingIdeas {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking through your holdings and the news…").foregroundStyle(.secondary) }
                }
            } header: {
                Text("Ideas")
            }
        }
        .sheet(isPresented: $adding) { AddGoalView() }
        .task { goals.kick() }
    }
}

struct GoalsScreen: View {
    var body: some View {
        List { GoalsListSections() }
            .navigationTitle("Goals and ideas")
            .navigationBarTitleDisplayMode(.inline)
            .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

extension GoalStore {
    struct Lead { let title: String; let detail: String; let symbol: String; let limit: Double?; let destination: GoalDestination }
    enum GoalDestination { case goal(UUID), idea(GoalIdea) }

    private static func firstSentence(_ markdown: String) -> String {
        let plain = markdown.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\n", with: " ")
        let end = plain.range(of: ". ")?.lowerBound ?? plain.endIndex
        return String(plain[..<end].prefix(140)).trimmingCharacters(in: .whitespaces)
    }

    /// The one thing the AI thinks the owner should see first: the most urgent goal, else its top idea.
    var lead: Lead? {
        let urgent = goals.filter { $0.enabled && ($0.review?.status ?? .onTrack) != .onTrack }
            .sorted { ($0.review?.status == .action ? 1 : 0) > ($1.review?.status == .action ? 1 : 0) }.first
        if let goal = urgent, let review = goal.review {
            let action = review.actions.first
            return Lead(title: review.headline.isEmpty ? goal.text : review.headline, detail: Self.firstSentence(review.body), symbol: action?.symbol ?? "",
                        limit: action?.targetWeightPct, destination: .goal(goal.id))
        }
        if let idea = ideas.first {
            return Lead(title: idea.title, detail: Self.firstSentence(idea.detail), symbol: idea.symbol, limit: nil, destination: .idea(idea))
        }
        if let goal = goals.first(where: \.enabled), let review = goal.review {
            return Lead(title: "Everything is on track", detail: review.headline, symbol: "", limit: nil, destination: .goal(goal.id))
        }
        return nil
    }
}

private struct GoalSparkline: View {
    let symbol: String
    let limit: Double?
    @State private var history = WeightHistory()
    @State private var store = PortfolioStore.shared

    var body: some View {
        let points = history.days.filter { $0.symbol == symbol }
        let values = points.map(\.percent) + (limit.map { [$0] } ?? [])
        Chart {
            ForEach(points) { day in
                LineMark(x: .value("Day", day.date, unit: .day), y: .value("Share", day.percent))
                    .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round))
                    .foregroundStyle(Color.orange)
            }
            if let limit { RuleMark(y: .value("Limit", limit)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(.secondary) }
        }
        .chartYScale(domain: ((values.min() ?? 0) - 0.15)...((values.max() ?? 1) + 0.15))
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .task(id: symbol) { if !symbol.isEmpty { await history.load(symbols: [symbol], snapshot: store.snapshot) } }
    }
}

/// Goals on the Portfolio screen: one plain sentence from the AI about what matters most, and a row into the full lists.
struct PortfolioGoalsSection: View {
    @State private var goals = GoalStore.shared
    @State private var adding = false

    var body: some View {
        Group {
            if goals.goals.isEmpty && goals.ideas.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tell me what you want from this portfolio").font(.headline)
                        Text("I'll watch your holdings and the news against it. For example, \"no single position above 20%\" or \"tell me when news hits what I own\".")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if goals.refreshingIdeas {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking through your holdings and the news…").font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Button("Write a goal") { adding = true }.buttonStyle(.glass).padding(.top, 2)
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Section {
                    if let lead = goals.lead {
                        NavigationLink {
                            switch lead.destination {
                            case let .goal(id): GoalDetailView(id: id)
                            case let .idea(idea): IdeaDetailView(idea: idea)
                            }
                        } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(lead.title).font(.headline)
                                    if !lead.detail.isEmpty { Text(lead.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer(minLength: 4)
                                if !lead.symbol.isEmpty { GoalSparkline(symbol: lead.symbol, limit: lead.limit).frame(width: 72, height: 34) }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    NavigationLink { GoalsScreen() } label: {
                        HStack {
                            Text("Goals and ideas")
                            Spacer()
                            if goals.refreshingIdeas || !goals.reviewing.isEmpty { ProgressView().controlSize(.small) }
                            Text("\(goals.goals.count) \(goals.goals.count == 1 ? "goal" : "goals"), \(goals.ideas.count) \(goals.ideas.count == 1 ? "idea" : "ideas")").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $adding) { AddGoalView() }
        .task { goals.kick() }
    }
}

private extension PortfolioGoal {
    /// Higher means the AI thinks it needs the owner sooner.
    var severity: Int {
        guard enabled, let review = goal_review else { return 0 }
        switch review.status { case .action: return 3; case .attention: return 2; case .onTrack: return 1 }
    }
    private var goal_review: GoalReview? { review }
}

private struct GoalRow: View {
    let goal: PortfolioGoal
    let busy: Bool
    let error: String?

    private var status: (text: String, color: Color)? {
        if busy { return ("Reviewing…", .secondary) }
        if error != nil { return ("Couldn't review", .orange) }
        if !goal.enabled { return ("Paused", .secondary) }
        guard let review = goal.review, review.status != .onTrack else { return nil }
        return (review.status.label, review.status.color)
    }

    var body: some View {
        HStack {
            Text(goal.text)
            Spacer(minLength: 8)
            if let status { Text(status.text).font(.footnote).foregroundStyle(status.color) }
        }
        .opacity(goal.enabled ? 1 : 0.6)
        .contextMenu {
            Button("Review now", systemImage: "arrow.clockwise") { Task { await GoalStore.shared.review(goal.id) } }
        }
    }
}

private struct IdeaRow: View {
    let idea: GoalIdea

    var body: some View {
        NavigationLink {
            IdeaDetailView(idea: idea)
        } label: { Text(idea.title) }
            .swipeActions {
                Button("Dismiss", role: .destructive) { GoalStore.shared.dismissIdea(idea.id) }
            }
    }
}

extension View {
    /// The app's glass container: the same 22pt glass as `QuoteSection`.
    func glassPanel() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct IdeaDetailView: View {
    let idea: GoalIdea

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(idea.title).font(.title2.weight(.bold))
                GoalWeightChart(symbols: idea.symbol.isEmpty ? [] : [idea.symbol])
                Text(idea.detail).font(.body).foregroundStyle(.secondary)
                GlassEffectContainer(spacing: 10) {
                  VStack(spacing: 10) {
                    if !idea.symbol.isEmpty {
                        NavigationLink { QuoteDetail(symbol: idea.symbol) } label: { Text("Open \(idea.symbol)").frame(maxWidth: .infinity) }.buttonStyle(.glass)
                    }
                    Button { 
                        let context = AskContext(symbol: idea.symbol, name: idea.symbol, screen: "An idea shown on the reader's Portfolio: \"\(idea.title)\". \(idea.detail) They want to talk it through.")
                        AppNavigator.shared.setScreen(context, for: .portfolio)
                        AppNavigator.shared.select(.ask)
                    } label: { Text("Talk it through in Ask").frame(maxWidth: .infinity) }.buttonStyle(.glass)
                    Button(role: .destructive) { GoalStore.shared.dismissIdea(idea.id) } label: { Text("Not interested").frame(maxWidth: .infinity) }.buttonStyle(.glass)
                  }
                }
                .controlSize(.large)
            }
            .padding(20)
        }
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

struct AddGoalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    private let ideas = ["Keep my portfolio balanced", "Don't let any stock pass 20%", "Keep at least 10% in cash", "Find stocks worth buying", "Tell me when news hits my holdings"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField("What should I watch for?", text: $text, axis: .vertical)
                        .font(.system(size: 30, weight: .bold)).lineLimit(1...4).focused($focused)
                    Text("I'll check your holdings and the news against this whenever you open Portfolio, and tell you what I'd change. You decide; nothing is traded.")
                        .font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Or start from").font(.footnote).foregroundStyle(.secondary).padding(.bottom, 6)
                        ForEach(ideas, id: \.self) { idea in
                            Button { text = idea } label: {
                                VStack(spacing: 0) {
                                    Divider()
                                    Text(idea).font(.body).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8)
            }
            .navigationTitle("New goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { GoalStore.shared.add(text); dismiss() }
                        .buttonStyle(.glassProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }
}

struct GoalDetailView: View {
    let id: UUID
    @State private var goals = GoalStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            if let goal = goals.goal(id) {
                VStack(alignment: .leading, spacing: 22) {
                    Text(goal.text).font(.title2.weight(.bold))
                    GoalWeightChart(symbols: goal.review?.actions.map(\.symbol) ?? [], limit: goal.review?.actions.compactMap(\.targetWeightPct).first)
                    if let error = goals.errors[id] {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    if let review = goal.review {
                        ReviewBody(review: review)
                        if !review.actions.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(review.actions) { Text(sentence($0)).font(.body.weight(.semibold)) }
                            }
                        }
                    }
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            Button("Ask about this") {
                                let lead = goal.review?.actions.first
                                let context = AskContext(symbol: lead?.symbol ?? "", name: lead?.symbol ?? "Markets",
                                                         screen: "The portfolio goal \"\(goal.text)\" and its latest review: \(goal.review?.headline ?? ""). \(goal.review?.body.prefix(600) ?? "")")
                                AppNavigator.shared.setScreen(context, for: .portfolio)
                                AppNavigator.shared.select(.ask)
                            }
                            .buttonStyle(.glassProminent)
                            Button(goals.reviewing.contains(id) ? "Reviewing…" : "Review now") { Task { await goals.review(id) } }
                                .buttonStyle(.glass).disabled(goals.reviewing.contains(id))
                        }
                    }
                    .controlSize(.large)
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Keep watching", isOn: Binding(get: { goal.enabled }, set: { goals.setEnabled(id, $0) }))
                        Button("Delete goal", role: .destructive) { goals.remove(id); dismiss() }
                    }
                }
                .padding(20)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .asksAbout(AskContext(screen: goals.goal(id).map { "The portfolio goal \"\($0.text)\" and its latest review: \($0.review?.headline ?? "not reviewed yet"). \($0.review?.body.prefix(500) ?? "")" } ?? ""))
    }

    private func sentence(_ action: GoalAction) -> String {
        let now = action.currentWeightPct.map { " from \($0.formatted(.number.precision(.fractionLength(0...1))))%" } ?? ""
        let target = action.targetWeightPct.map { " to \($0.formatted(.number.precision(.fractionLength(0...1))))%" } ?? ""
        return "\(action.action.capitalized) \(action.symbol)\(now)\(target)"
    }
}

private struct ReviewBody: View {
    let review: GoalReview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !review.headline.isEmpty { Text(review.headline).font(.title3.weight(.semibold)) }
            MarkdownText(review.body, sources: review.sources)
            if review.partialData {
                Label("Some brokerage data was stale or missing for this review.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            } else if let asOf = review.portfolioAsOf {
                Text("Portfolio data as of \(asOf.formatted(.dateTime.month().day().hour().minute())) · \(review.provider)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Suggestions only, not financial advice. Nothing is traded.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct FullReviewView: View {
    @State private var goals = GoalStore.shared

    var body: some View {
        List {
            if let error = goals.fullError {
                Section { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
            }
            if let review = goals.fullReview {
                Section { ReviewBody(review: review) }
            } else if !goals.reviewingFull {
                Section {
                    ForEach(["How balanced you are, and what's too concentrated", "What's driving your results", "News affecting what you own", "How you're doing on your goals", "What to consider doing next"], id: \.self) {
                        Label($0, systemImage: "checkmark")
                    }
                } header: { Text("The review covers") }
            }
            Section {
                Button { Task { await goals.runFullReview() } } label: {
                    if goals.reviewingFull { HStack { ProgressView(); Text("Researching your portfolio…").padding(.leading, 6) } }
                    else { Label(goals.fullReview == nil ? "Run full review" : "Run again", systemImage: "arrow.clockwise") }
                }
                .disabled(goals.reviewingFull)
            }
        }
        .navigationTitle("Full review")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .asksAbout(AskContext(screen: "The full AI portfolio review. " + (goals.fullReview.map { "Latest text: \($0.body.prefix(1500))" } ?? "No review has been run yet.")))
    }
}

#if DEBUG
struct GoalDetailPreview: View {
    private static let loaded: Void = { _ = PortfolioPreview(); GoalStore.shared.loadPreview() }()
    init() { _ = Self.loaded }
    var body: some View {
        NavigationStack {
            if let goal = GoalStore.shared.goals.first { GoalDetailView(id: goal.id) }
        }
    }
}

struct GoalsPreview: View {
    private static let loaded: Void = { _ = PortfolioPreview(); GoalStore.shared.loadPreview() }()
    init() { _ = Self.loaded }
    var body: some View {
        NavigationStack {
            List { PortfolioGoalsSection() }
                .navigationTitle("Portfolio")
                .navigationBarTitleDisplayMode(.inline)
        }

    }
}
#endif
