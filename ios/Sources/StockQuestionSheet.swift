import SwiftUI

struct StockQuestionSheet: View {
    let symbol: String
    let name: String
    let price: String?
    @State private var chat = StockChat()
    @State private var question = ""
    @State private var showingSettings = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private let suggestions = ["Why is this stock moving?", "Tell me about this company", "Compare bullish earnings trades with a $1,000 budget"]

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        if chat.messages.isEmpty { emptyState }
                        ForEach(chat.messages) { message in
                            if message.user { questionBubble(message.text) } else { answer(message) }
                        }
                        if let activity = chat.activity {
                            HStack(spacing: 8) {
                                Image(systemName: "apple.intelligence").symbolEffect(.pulse)
                                Text(activity)
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
                            .transition(.opacity)
                        }
                        if let error = chat.error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
                    .animation(.easeOut(duration: 0.2), value: chat.messages.count)
                    .animation(.easeOut(duration: 0.2), value: chat.activity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.count) { withAnimation(.easeOut(duration: 0.25)) { reader.scrollTo("bottom", anchor: .bottom) } }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
            .navigationTitle("Ask \(symbol)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(isPresented: $showingSettings) { StockAISettings() }
            .scrollEdgeEffectStyle(.soft, for: .all)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { chat.cancel() }
        #if DEBUG
        .task {
            if CommandLine.arguments.contains("-stockAISettings") { showingSettings = true }
            if CommandLine.arguments.contains("-stockAISample") {
                chat.messages = [
                    StockChatMessage(user: true, text: "Why is this stock moving?"),
                    StockChatMessage(user: false, text: "The stock price for Kodiak Sciences Inc. (KOD) is at $94.80 as of 2026-09-30, with a previous close of $91.12. The recent movement appears to be influenced by:\n\n1. **Stock Acquisitions & Ownership Changes**: A significant stock acquisition altered beneficial ownership by more than 1% (source: stocktitan.net). Additionally, Baker funds purchased shares in 30 transactions.\n2. **Phase 3 Clinical Wins**: Reports of Phase 3 successes may have contributed to investor interest.\n3. **Form 4 Filing**: A recent Form 4 filing suggests insider activity.\n\nThese factors may have driven price shifts, but their exact causal impact cannot be confirmed from the available headlines.", sources: [StockSource(title: "Kodiak insider purchase — Stock Titan", url: URL(string: "https://stocktitan.net")!), StockSource(title: "Yahoo Finance · KOD", url: URL(string: "https://finance.yahoo.com/quote/KOD")!)], provider: "Apple Intelligence")
                ]
            }
        }
        #endif
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).lineLimit(1)
                Text([symbol, price].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button { showingSettings = true } label: {
                Label(chat.provider, systemImage: chat.backend == .deepSeek ? "sparkles" : chat.backend == .privateCloud ? "lock.icloud" : "apple.intelligence")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).frame(minHeight: 32)
                    .contentShape(.capsule)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(PressSpringStyle())
            .accessibilityHint("Choose the AI provider")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about the company, today's move, or an options idea.")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(suggestions, id: \.self) { text in
                    Button { question = text; focused = true } label: {
                        HStack(spacing: 12) {
                            Text(text).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if text != suggestions.last { Divider().padding(.leading, 16) }
                }
            }
            .background(.fill.quaternary, in: .rect(cornerRadius: 20, style: .continuous))
            Text(chat.backend == .deepSeek ? "Questions and fetched market context are sent directly to DeepSeek. API usage is billed to your account." : chat.backend == .privateCloud ? "Answers are generated by Apple's Private Cloud Compute." : "Answers are generated on this device. Market research needs an internet connection.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func questionBubble(_ text: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.fill.tertiary, in: .rect(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
    }

    private func answer(_ message: StockChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message.provider, systemImage: message.provider == "DeepSeek" ? "sparkles" : "apple.intelligence")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            MarkdownText(message.text)
            if !message.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(message.sources) { source in
                            Link(destination: source.url) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.right").font(.caption2.weight(.bold))
                                    Text(source.title).lineLimit(1)
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12).frame(minHeight: 32).frame(maxWidth: 240)
                                .background(.fill.quaternary, in: .capsule)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canSend: Bool { !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about \(symbol)", text: $question, axis: .vertical)
                .lineLimit(1...5).focused($focused)
                .submitLabel(.send).onSubmit(send)
                .disabled(chat.busy)
                .padding(.leading, 18).padding(.vertical, 12)
            Group {
                if chat.busy {
                    Button { chat.cancel() } label: {
                        Image(systemName: "stop.fill").font(.footnote).frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Stop answer")
                } else if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.subheadline.weight(.bold)).frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel("Send question")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .buttonBorderShape(.circle)
            .padding(6)
        }
        .animation(.spring(duration: 0.25, bounce: 0.2), value: canSend)
        .animation(.spring(duration: 0.25, bounce: 0.2), value: chat.busy)
        .frame(minHeight: 48)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.busy else { return }
        focused = false
        chat.send(String(text.prefix(4000)), symbol: symbol, name: name, price: price)
        question = ""
    }
}

struct MarkdownText: View {
    private enum Block: Hashable {
        case paragraph(String)
        case heading(String)
        case item(marker: String, text: String, depth: Int)
    }

    private let blocks: [Block]

    init(_ source: String) { blocks = Self.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(Self.inline(text))
                case .heading(let text):
                    Text(Self.inline(text)).font(.headline).padding(.top, 4)
                case .item(let marker, let text, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(Self.inline(text))
                    }
                    .padding(.leading, CGFloat(depth) * 18)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in source.components(separatedBy: .newlines) {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
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
        return blocks
    }
}

struct StockAISettings: View {
    @AppStorage(AIRouter.appleKey) private var apple = "onDevice"
    @AppStorage(AIFeature.stockChat.defaultsKey) private var stock = true
    @AppStorage(AIFeature.articleSummaries.defaultsKey) private var summaries = true
    @AppStorage(AIFeature.moveExplanations.defaultsKey) private var moves = true
    @State private var key = ""
    @State private var hasKey = false
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        Form {
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
                Text("DeepSeek")
            } footer: {
                Text("With a key saved, every feature below uses DeepSeek Flash. Turn a feature off to keep it on Apple's models.")
            }
            Section {
                Toggle("Stock questions", isOn: $stock)
                Toggle("Article summaries", isOn: $summaries)
                Toggle("Why it moved", isOn: $moves)
            } header: {
                Text("Use DeepSeek for")
            }
            .disabled(!hasKey)
            Section {
                Picker("Apple model", selection: $apple) {
                    Text("On device").tag("onDevice")
                    if AIRouter.privateCloudAvailable || apple == "privateCloud" { Text("Private Cloud Compute").tag("privateCloud") }
                }
            } header: {
                Text("Without DeepSeek")
            } footer: {
                Text(AIRouter.privateCloudAvailable
                     ? "Private Cloud Compute runs larger Apple models on Apple's servers without storing your requests. On device works offline."
                     : "Private Cloud Compute isn't available on this device or OS version.")
            }
            Section {
                Text("The key is stored in this device's Keychain and sent only to DeepSeek. Prompts, article text and fetched market context go directly to DeepSeek when it is used, and usage is billed to your account. Your brokerage holdings are never included.")
            }.font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .onAppear { hasKey = !StockAIKeychain.read().isEmpty }
    }
}
