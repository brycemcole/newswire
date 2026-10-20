import SwiftUI

/// What a chat is about: empty symbol means markets in general.
struct AskContext: Identifiable, Hashable {
    var symbol = ""
    var name = "Markets"
    var price: String?
    var id: String { symbol }
    static let markets = AskContext()
}

struct ChatThread: Identifiable, Codable, Hashable {
    var id = UUID()
    var symbol = ""
    var name = "Markets"
    var updated = Date.now
    var messages: [StockChatMessage] = []

    var title: String { messages.first { $0.user }?.text ?? "New chat" }
}

@Observable final class ChatHistory {
    static let shared = ChatHistory()
    private(set) var threads: [ChatThread] = []
    nonisolated private static let url = URL.applicationSupportDirectory.appending(path: "ask-chats.json")

    init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([ChatThread].self, from: data) { threads = saved }
    }

    func save(_ thread: ChatThread) {
        guard !thread.messages.isEmpty else { return }
        threads.removeAll { $0.id == thread.id }
        threads.insert(thread, at: 0)
        if threads.count > 100 { threads.removeLast(threads.count - 100) }
        persist()
    }

    func delete(_ id: UUID) {
        threads.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let threads = threads
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(threads).write(to: ChatHistory.url, options: .atomic)
        }
    }
}

struct AskSheet: View {
    let context: AskContext
    let initialQuestion: String?
    @State private var thread: ChatThread
    @State private var chat = StockChat()
    @State private var history = ChatHistory.shared
    @State private var generator = AskSuggestions.shared
    @State private var question = ""
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var filing: StockSource?
    @State private var openedStory: Story?
    @Environment(\.feedStore) private var feedStore
    @State private var isAtLatest = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(context: AskContext = .markets, initialQuestion: String? = nil) {
        self.context = context
        self.initialQuestion = initialQuestion
        _thread = State(initialValue: ChatThread(symbol: context.symbol, name: context.name))
    }

    private var market: Bool { thread.symbol.isEmpty }
    private var price: String? { thread.symbol == context.symbol ? context.price : nil }
    private var suggestions: [String] {
        return market ? generator.questions
            : ["Why is \(thread.symbol) moving today?", "What does \(thread.name) do, in plain terms?", "Compare bullish earnings trades with a $1,000 budget"]
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if chat.messages.isEmpty { emptyState }
                        ForEach(chat.messages) { message in
                            if message.user { questionBubble(message.text) } else { answer(message) }
                        }
                        if let activity = chat.activity {
                            HStack(spacing: 8) {
                                Image(systemName: "ellipsis.bubble").symbolEffect(.pulse)
                                Text(activity)
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
                            .transition(.opacity)
                        }
                        if let error = chat.error {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                                if chat.canRetry {
                                    Button { chat.retry() } label: {
                                        Label("Retry answer", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chat.messages.count)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chat.activity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom >= geometry.contentSize.height - 48
                } action: { _, atLatest in
                    isAtLatest = atLatest
                }
                .onChange(of: chat.messages.count) {
                    guard isAtLatest else { return }
                    let action = { reader.scrollTo("bottom", anchor: .bottom) }
                    if reduceMotion { action() } else { withAnimation(.easeOut(duration: 0.25), action) }
                }
                .overlay(alignment: .bottom) {
                    if !isAtLatest && chat.messages.count > 2 {
                        Button {
                            let action = { reader.scrollTo("bottom", anchor: .bottom); isAtLatest = true }
                            if reduceMotion { action() } else { withAnimation(.easeOut(duration: 0.25), action) }
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.regularMaterial, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
            .navigationTitle(market ? "Ask" : "Ask about \(thread.symbol)")
            .navigationDestination(item: $filing) { FilingReaderView(url: $0.url, title: $0.title) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Past chats")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { startNew() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                        .disabled(chat.messages.isEmpty && !chat.busy)
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("AI settings")
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(isPresented: $showingSettings) { StockAISettings() }
            .navigationDestination(item: $openedStory) { StoryDetail(story: $0) }
            .navigationDestination(isPresented: $showingHistory) {
                ChatHistoryList(current: thread.id) { open($0) }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .task { if market { await generator.refresh() } }
            .task {
                guard let initialQuestion, !initialQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                question = initialQuestion
                await Task.yield()
                send()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: chat.messages) { _, messages in
            thread.messages = messages
            thread.updated = .now
            history.save(thread)
        }
        .onDisappear { chat.cancel() }
        #if DEBUG
        .task {
            if CommandLine.arguments.contains("-stockAISettings") { showingSettings = true }
            if let index = CommandLine.arguments.firstIndex(of: "-askPrompt"), CommandLine.arguments.indices.contains(index + 1) {
                chat.send(CommandLine.arguments[index + 1], symbol: context.symbol, name: context.name, price: context.price)
            }
            if CommandLine.arguments.contains("-askHistory") { showingHistory = true }
            if CommandLine.arguments.contains("-stockAIComposer") {
                question = "Why is BlackBerry up so much this year?"
                focused = true
            }
            if CommandLine.arguments.contains("-stockAISample") {
                let date = Date.now.addingTimeInterval(-86_400)
                chat.messages = [
                    StockChatMessage(user: true, text: "How does Visa compare to its payments peers on growth and margins?"),
                    StockChatMessage(user: false, text: """
                    **Visa still has the highest net margin in the group at about 50%, while Mastercard is growing earnings twice as fast.** [1][2]

                    Visa's revenue grew 14.4% over the past year, just ahead of Mastercard's 14.1% [1][2].

                    - **Mastercard** grew earnings 22.1%, versus 10.2% at Visa [2].
                    - **American Express** margins look low because it lends like a bank [3].
                    - **PayPal** is the laggard, with earnings down 3.1% [4].

                    | Company | Revenue growth (%, TTM) | Net margin (%, FY25) | P/E (TTM) |
                    |---|---|---|---|
                    | Visa (V) [1] | 14.4 | 50.2 | 34.3 |
                    | Mastercard (MA) [2] | 14.1 | 45.7 | 34.0 |
                    | American Express (AXP) [3] | 12.8 | 14.8 | 19.0 |
                    | PayPal (PYPL) [4] | 4.8 | 15.8 | n/a |

                    Visa and PayPal report on Tuesday, Oct 27 [1][4].

                    ```stories
                    [5, 6]
                    ```
                    """, sources: [StockSource(title: "Yahoo Finance · V", url: URL(string: "https://finance.yahoo.com/quote/V/")!),
                                   StockSource(title: "Yahoo Finance · MA", url: URL(string: "https://finance.yahoo.com/quote/MA/")!),
                                   StockSource(title: "SEC EDGAR · AXP", url: URL(string: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=AXP")!),
                                   StockSource(title: "Yahoo Finance · PYPL", url: URL(string: "https://finance.yahoo.com/quote/PYPL/")!),
                                   StockSource(title: "[TEST] Visa and Mastercard settle merchant fee case", url: URL(string: "https://example.com/visa")!, story: "test-visa", publisher: "Reuters", date: date),
                                   StockSource(title: "[TEST] PayPal outlines checkout turnaround plan", url: URL(string: "https://example.com/paypal")!, story: "test-paypal", publisher: "Bloomberg", date: date)],
                                     provider: "DeepSeek")
                ]
            }
            if CommandLine.arguments.contains("-askOptionsSample") { chat.messages = ChatWidgetFixture.messages }
            if CommandLine.arguments.contains("-askFailure") { chat.loadFailedAnswerFixture() }
            if CommandLine.arguments.contains("-askLongThread") { chat.loadLongThreadFixture() }
        }
        #endif
    }

    private func startNew() {
        chat.cancel()
        chat = StockChat()
        thread = ChatThread(symbol: context.symbol, name: context.name)
        question = ""
        focused = true
    }

    private func open(_ saved: ChatThread) {
        showingHistory = false
        guard saved.id != thread.id else { return }
        chat.cancel()
        let restored = StockChat()
        restored.messages = saved.messages
        thread = saved
        chat = restored
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(market ? "What do you want to know about the markets?" : "What do you want to know about \(thread.name)?")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(suggestions, id: \.self) { text in
                    Button { question = text; send() } label: {
                        HStack(spacing: 12) {
                            Text(text).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if text != suggestions.last { Divider().padding(.leading, 16) }
                }
            }
            .background(.fill.quaternary, in: .rect(cornerRadius: 20, style: .continuous))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: generator.questions)
        }
    }

    private func questionBubble(_ text: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
    }

    private func answer(_ message: StockChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MarkdownText(message.text, options: message.options, sources: message.sources)
                .environment(\.openURL, OpenURLAction { open($0, sources: message.sources) })
            if !message.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(Array(message.sources.enumerated()), id: \.element.id) { index, source in
                                Button {
                                    _ = open(source.url, sources: message.sources)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("\(index + 1)").font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.tint)
                                        Text(source.title).lineLimit(1)
                                    }
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12).frame(minHeight: 32).frame(maxWidth: 240)
                                    .contentShape(.capsule)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.primary)
                                .glassEffect(.regular.interactive(), in: .capsule)
                            }
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Citation chips and story cards: filings open in the native reader, wire stories in the story view, everything else in the in-app browser.
    private func open(_ url: URL, sources: [StockSource]) -> OpenURLAction.Result {
        let source = sources.first { $0.url == url }
        if let source, FilingLink.isFiling(url) {
            filing = source
        } else if let source, let id = source.story {
            openedStory = feedStore?.story(id: id) ?? Story(id: id, externalId: id, title: source.title, summary: "", body: "",
                source: source.publisher ?? url.host() ?? "News", url: url, publishedAt: source.date ?? .now, receivedAt: .now,
                category: "markets", priority: "normal", tickers: [], tags: ["markets"], agent: "market-feed", imageUrl: nil)
        } else {
            openURL(url)
        }
        return .handled
    }

    private var canSend: Bool { !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(market ? "Ask anything about the markets" : "Ask about \(thread.symbol)", text: $question, axis: .vertical)
                .lineLimit(1...5).focused($focused)
                .submitLabel(.send).onSubmit(send)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A vertical-axis field types a newline for Return instead of submitting, so treat a typed trailing newline as Send.
                .onChange(of: question) { old, new in
                    guard let text = ComposerReturn.stripped(old: old, new: new) else { return }
                    question = text
                    send()
                }
            Group {
                if chat.busy {
                    Button { chat.cancel() } label: {
                        Image(systemName: "stop.fill").font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 30, height: 30)
                            .background(.fill.tertiary, in: Circle())
                            .padding(7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop answer")
                } else if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.tint, in: Circle())
                            .padding(7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send question")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 4)
        .contentShape(.rect(cornerRadius: 24, style: .continuous))
        .onTapGesture { focused = true }
        .animation(.spring(duration: 0.25, bounce: 0.2), value: canSend)
        .animation(.spring(duration: 0.25, bounce: 0.2), value: chat.busy)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.busy else { return }
        focused = false
        chat.send(String(text.prefix(4000)), symbol: thread.symbol, name: thread.name, price: price)
        question = ""
    }
}

nonisolated enum ComposerReturn {
    /// The text without its trailing newline when one newline was just typed at the end; nil for any other edit, such as pasting several lines.
    static func stripped(old: String, new: String) -> String? {
        guard new.count == old.count + 1, new.hasSuffix("\n") else { return nil }
        return String(new.dropLast())
    }
}

struct ChatHistoryList: View {
    let current: UUID
    let open: (ChatThread) -> Void
    @State private var history = ChatHistory.shared

    var body: some View {
        List {
            ForEach(history.threads) { thread in
                Button { open(thread) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(thread.title).font(.body.weight(thread.id == current ? .semibold : .regular)).lineLimit(2)
                        Text([thread.symbol.isEmpty ? "Markets" : thread.symbol,thread.updated.formatted(.relative(presentation: .named))].joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { history.delete(thread.id) }
                }
            }
        }
        .overlay {
            if history.threads.isEmpty {
                ContentUnavailableView("No past chats", systemImage: "bubble.left.and.text.bubble.right", description: Text("Questions you ask are saved here."))
            }
        }
        .navigationTitle("Past Chats")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MarkdownText: View {
    private enum Block: Hashable {
        case paragraph(String)
        case heading(String)
        case item(marker: String, text: String, depth: Int)
        case code(String)
        case widget(ChatWidget)
        case table(header: [String], rows: [[String]])
        case stories([Int])
    }

    private let blocks: [Block]
    private let options: [ChatOption]
    private let sources: [StockSource]
    @State private var tableWidth: CGFloat = 0
    @Environment(\.openURL) private var openURL

    /// `options` are the quotes behind any ```options or ```strategy widget blocks in `source`; `sources` resolve [n] citations and ```stories blocks.
    init(_ source: String, options: [ChatOption] = [], sources: [StockSource] = []) {
        blocks = Self.parse(source)
        self.options = options
        self.sources = sources
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(inline(text))
                case .heading(let text):
                    Text(inline(text)).font(.headline).padding(.top, 4)
                case .item(let marker, let text, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(inline(text))
                    }
                    .padding(.leading, CGFloat(depth) * 18)
                case .code(let text):
                    Text(text)
                        .font(.footnote.monospaced())
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.quaternary, in: .rect(cornerRadius: 12, style: .continuous))
                case .widget(let widget):
                    ChatWidgetView(widget: widget, options: options)
                case .table(let header, let rows):
                    table(header: header, rows: rows).padding(.vertical, 4)
                case .stories(let numbers):
                    stories(numbers)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        let numeric = header.indices.map { column in
            column > 0 && rows.contains { Self.isNumeric($0[column]) } && rows.allSatisfy { Self.isNumeric($0[column]) || Self.isEmptyValue($0[column]) }
        }
        let nameWidth: CGFloat = header.count >= 4 ? 100 : 150
        let grid = Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    let parts = Self.headerParts(header[column])
                    VStack(alignment: numeric[column] ? .trailing : .leading, spacing: 1) {
                        Text(inline(parts.title))
                        if let detail = parts.detail { Text(detail).foregroundStyle(.tertiary) }
                    }
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .multilineTextAlignment(numeric[column] ? .trailing : .leading)
                    .gridColumnAlignment(numeric[column] ? .trailing : .leading)
                    .frame(maxWidth: column == 0 ? .infinity : 64, alignment: numeric[column] ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 8)
            ForEach(rows.indices, id: \.self) { row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        let value = rows[row][column]
                        if column == 0 {
                            let markers = value.matches(of: /\[\d{1,2}\]/).map { String($0.output) }.joined()
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(inline(value.replacing(/\s*\[\d{1,2}\]/, with: ""))).lineLimit(3)
                                if !markers.isEmpty { Text(inline(markers)) }
                                Spacer(minLength: 0)
                            }
                            .font(.footnote.weight(.medium))
                            .frame(width: nameWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(inline(value))
                                .font(numeric[column] ? .footnote.monospacedDigit() : .footnote)
                                .foregroundStyle(Self.isEmptyValue(value) ? .tertiary : .primary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 3)
        return ScrollView(.horizontal, showsIndicators: false) {
            grid.frame(minWidth: tableWidth, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
        .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func stories(_ numbers: [Int]) -> some View {
        let picked = numbers.compactMap { sources.indices.contains($0 - 1) ? sources[$0 - 1] : nil }
        return VStack(spacing: 0) {
            ForEach(picked) { source in
                Button { openURL(source.url) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                            Text([source.publisher ?? source.url.host(), source.date?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if source.id != picked.last?.id { Divider().padding(.leading, 14) }
            }
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let numbers = Set(text.matches(of: /\[(\d{1,2})\]/).compactMap { Int($0.1) })
        guard !numbers.isEmpty, !sources.isEmpty else { return result }
        for number in numbers {
            while let range = result.range(of: "[\(number)]") {
                guard sources.indices.contains(number - 1) else { result.removeSubrange(range); continue }
                var chip = AttributedString("\u{202F}\(number)\u{202F}")
                chip.font = .caption2.weight(.semibold).monospacedDigit()
                chip.foregroundColor = .accentColor
                chip.backgroundColor = Color.accentColor.opacity(0.14)
                chip.baselineOffset = 1.5
                chip.link = sources[number - 1].url
                var spaced = AttributedString("\u{202F}")
                spaced.append(chip)
                result.replaceSubrange(range, with: spaced)
            }
        }
        return result
    }

    private static func headerParts(_ header: String) -> (title: String, detail: String?) {
        guard let match = header.firstMatch(of: /^(.+?)\s*\(([^()]+)\)\s*$/) else { return (header, nil) }
        return (String(match.1), String(match.2))
    }

    private static func plain(_ cell: String) -> String {
        cell.replacing(/\[\d{1,2}\]/, with: "").replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func isNumeric(_ cell: String) -> Bool {
        plain(cell).wholeMatch(of: /[-+−–~≈]?[$€£¥]?\(?[-+−]?[\d.,]+\)?\s*(%|x|×|bp|bps|pts?|[KMBT])?\s*(→\s*[$€£]?[\d.,]+%?)?/) != nil
    }

    private static func isEmptyValue(_ cell: String) -> Bool {
        ["", "n/a", "na", "—", "-", "–", "n.m.", "nm"].contains(plain(cell).lowercased())
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A pipe table needs a header, a |---| separator and at least one row; short rows are padded so a slightly malformed table still renders as a grid.
    private static func table(_ lines: [String]) -> Block? {
        guard lines.count >= 3 else { return nil }
        let header = cells(lines[0])
        let separator = cells(lines[1])
        guard header.count >= 2, separator.count == header.count,
              separator.allSatisfy({ $0.wholeMatch(of: /:?-{2,}:?/) != nil }) else { return nil }
        let rows = lines.dropFirst(2).map { line in
            let row = cells(line)
            return Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
        }
        return .table(header: header, rows: rows)
    }

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var tableLines: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            if let block = table(tableLines) { blocks.append(block) } else { blocks.append(contentsOf: tableLines.map { .paragraph($0) }) }
            tableLines = []
        }
        var fence: (language: String, lines: [String])?
        for raw in source.components(separatedBy: .newlines) {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var open = fence {
                if line.hasPrefix("```") {
                    if let block = fenced(open.language, open.lines) { blocks.append(block) }
                    fence = nil
                } else {
                    open.lines.append(raw)
                    fence = open
                }
                continue
            }
            if line.hasPrefix("|") {
                flush()
                tableLines.append(line)
                continue
            }
            flushTable()
            if line.hasPrefix("```") {
                flush()
                fence = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                continue
            }
            if line.isEmpty || line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if let match = line.firstMatch(of: /^([-*•+])\s+(.*)$/) {
                flush()
                blocks.append(.item(marker: "•", text: String(match.2), depth: min(indent / 2, 3)))
            } else if let match = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                flush()
                blocks.append(.item(marker: "\(match.1).", text: String(match.2), depth: min(indent / 2, 3)))
            } else if case .item(let marker, let text, let depth)? = blocks.last, paragraph.isEmpty, indent > 0 {
                blocks[blocks.count - 1] = .item(marker: marker, text: text + " " + line, depth: depth)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        flushTable()
        if let open = fence, let block = fenced(open.language, open.lines) { blocks.append(block) }
        return tableLast(blocks)
    }

    /// Answers end with their table and story cards; a closing note the model adds after the table moves above it.
    private static func tableLast(_ blocks: [Block]) -> [Block] {
        guard let table = blocks.lastIndex(where: { if case .table = $0 { true } else { false } }) else { return blocks }
        let trailing = blocks[(table + 1)...]
        let text = trailing.filter { block in
            switch block {
            case .paragraph, .item: true
            default: false
            }
        }
        guard !text.isEmpty else { return blocks }
        let first = blocks.firstIndex(where: { if case .table = $0 { true } else { false } }) ?? table
        return Array(blocks[..<first]) + text + Array(blocks[first...table]) + trailing.filter { !text.contains($0) }
    }

    /// A widget when the fence names one and its JSON parses; plain code otherwise. A broken widget block is dropped rather than shown as raw JSON.
    private static func fenced(_ language: String, _ lines: [String]) -> Block? {
        let body = lines.joined(separator: "\n")
        if language.lowercased() == "stories" {
            var seen = Set<Int>()
            let numbers = body.matches(of: /\d{1,2}/).compactMap { Int($0.output) }.filter { seen.insert($0).inserted }
            return numbers.isEmpty ? nil : .stories(Array(numbers.prefix(3)))
        }
        if let widget = ChatWidget.parse(language: language, body: body) { return .widget(widget) }
        if ChatWidget.languages.contains(ChatWidget.normalize(language)) { return nil }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .code(body)
    }
}

struct StockAISettings: View {
    @AppStorage(AIFeature.stockChat.defaultsKey) private var stock = true
    @AppStorage(AIFeature.articleSummaries.defaultsKey) private var summaries = true
    @AppStorage(AIFeature.moveExplanations.defaultsKey) private var moves = true
    @State private var provider = AIRouter.provider
    @State private var key = ""
    @State private var hasKey = false
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("Answering with", selection: $provider) {
                    Label("DeepSeek Free", systemImage: "sparkles").tag("newswire")
                    Label("Apple on device", systemImage: "apple.intelligence").tag("onDevice")
                    Label("DeepSeek · personal API key", systemImage: "key").tag("deepSeek")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Answering with")
            } footer: {
                Text(footer)
            }
            if provider == "deepSeek" {
                Section {
                    SecureField(hasKey ? "Replace saved API key" : "API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save API key") {
                        do {
                            try StockAIKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            hasKey = !StockAIKeychain.read().isEmpty
                            key = ""; saved = true; error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey {
                        Label(saved ? "API key saved" : "API key configured", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        Button("Remove API key", role: .destructive) {
                            do { try StockAIKeychain.save(""); hasKey = false; saved = false; error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    Link("Get an API key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                } header: {
                    Text("DeepSeek API key")
                } footer: {
                    Text("The key is stored in this device's Keychain and sent only to DeepSeek. Saving a key doesn't switch providers; choose DeepSeek above to use it.")
                }
            }
            if provider == "deepSeek" || provider == "newswire" {
                Section {
                    Toggle("Ask", isOn: $stock)
                    Toggle("Article summaries", isOn: $summaries)
                    Toggle("Why it moved", isOn: $moves)
                } header: {
                    Text("Use DeepSeek for")
                } footer: {
                    Text("Features turned off here use Apple's models instead.")
                }
                .disabled(provider == "deepSeek" && !hasKey)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .onAppear { hasKey = !StockAIKeychain.read().isEmpty }
        .onChange(of: provider) { _, value in
            UserDefaults.standard.set(value, forKey: AIRouter.providerKey)
        }
    }

    private var footer: String {
        switch provider {
        case "newswire": "DeepSeek V4.1 Flash through OpenCode. Free, with a 200K context window and no API key needed. Questions, article text and fetched market context go through your Newswire server. Brokerage holdings are never included. Free availability and rate limits may change."
        case "deepSeek": hasKey ? "Questions, article text and fetched market context go directly to DeepSeek, billed to your account. Your brokerage holdings are never included." : "Add an API key below to use DeepSeek. Until then Apple's models answer."
        default: "Answers are generated on this device. Market research still needs an internet connection."
        }
    }
}
