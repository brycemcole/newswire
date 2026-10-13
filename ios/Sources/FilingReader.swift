import PDFKit
import SwiftUI

nonisolated struct FilingDocument: Codable, Sendable, Hashable {
    nonisolated struct Block: Codable, Sendable, Hashable {
        let kind: String
        let text: String?
        let rows: [[String]]?
        let level: Int?
    }
    let title: String
    let url: String
    let blocks: [Block]
}

nonisolated enum FilingLink {
    /// SEC EDGAR documents that Newswire can render natively instead of in a browser.
    static func isFiling(_ url: URL) -> Bool {
        url.host() == "www.sec.gov" && url.path().hasPrefix("/Archives/edgar/data/")
            && ["htm", "html", "txt", "pdf"].contains(url.pathExtension.lowercased())
    }
}

/// Filed documents never change, so parsed copies are kept on disk for instant, offline reopening.
nonisolated enum FilingCache {
    private static let directory = URL.cachesDirectory.appending(path: "filings", directoryHint: .isDirectory)

    static func file(_ url: URL) -> URL {
        directory.appending(path: url.path().split(separator: "/").suffix(3).joined(separator: "-") + ".json")
    }

    static func load(_ url: URL) -> FilingDocument? {
        guard let data = try? Data(contentsOf: file(url)) else { return nil }
        return try? JSONDecoder().decode(FilingDocument.self, from: data)
    }

    static func store(_ data: Data, for url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(url), options: .atomic)
    }
}

extension NewswireAPI {
    @concurrent func filingDocument(_ url: URL) async throws -> FilingDocument {
        if let cached = FilingCache.load(url) { return cached }
        let data = try await dataBytes("v1/data/sec/reader", ["url": url.absoluteString])
        let document = try JSONDecoder().decode(FilingDocument.self, from: data)
        FilingCache.store(data, for: url)
        return document
    }
}

private nonisolated struct IndexedFiling: Sendable {
    let document: FilingDocument
    let searchText: [String]
    let outline: [(index: Int, title: String)]
    /// Multiplier stated near each table, such as "(In millions, except per share data)".
    let scales: [Int: Double]

    init(_ document: FilingDocument) {
        self.document = document
        searchText = document.blocks.map { block in
            (block.text ?? block.rows?.map { $0.joined(separator: " ") }.joined(separator: " ") ?? "").lowercased()
        }
        var scales: [Int: Double] = [:]
        for (index, block) in document.blocks.enumerated() where block.kind == "table" {
            var context = (block.rows ?? []).prefix(3).map { $0.joined(separator: " ") }
            for previous in document.blocks[max(0, index - 6)..<index].reversed() {
                if previous.kind == "table" { break }
                context.append(previous.text ?? "")
            }
            if let scale = FilingNumbers.scale(in: context.joined(separator: " ")) { scales[index] = scale }
        }
        self.scales = scales
        outline = document.blocks.enumerated().compactMap { index, block in
            guard block.kind == "heading", block.level == 1, let text = block.text else { return nil }
            return (index, text)
        }
    }
}

struct FilingReaderView: View {
    let url: URL
    var title: String?

    @State private var filing: IndexedFiling?
    @State private var pdf: PDFDocument?
    @State private var failure: String?
    @State private var query = ""
    @State private var searching = false
    @State private var target: Int?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let pdf {
                PDFReader(document: pdf).ignoresSafeArea(edges: .bottom)
            } else if let filing {
                reader(filing)
            } else if let failure {
                ContentUnavailableView {
                    Label("Couldn't open this filing", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try again") { attempt += 1 }.buttonStyle(.bordered)
                }
            } else {
                ProgressView("Loading filing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title ?? filing?.document.title ?? "Filing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let filing, !filing.outline.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(filing.outline, id: \.index) { item in
                            Button(item.title) { target = item.index }
                        }
                    } label: { Image(systemName: "list.bullet.indent") }
                    .accessibilityLabel("Sections")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Link(destination: url) { Label("Open on SEC.gov", systemImage: "safari") }
                    ShareLink(item: url)
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Filing actions")
            }
        }
        .task(id: attempt) { await load() }
    }

    private func reader(_ filing: IndexedFiling) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if searching && !query.isEmpty {
                        results(filing)
                    } else {
                        ForEach(filing.document.blocks.indices, id: \.self) { index in
                            FilingBlockView(block: filing.document.blocks[index], scale: filing.scales[index]).id(index)
                        }
                        Text("Source: SEC EDGAR. Formatting is converted from the filed document; open it on SEC.gov for the original layout.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .dockClearance()
            .searchable(text: $query, isPresented: $searching, prompt: "Find in filing")
            .onChange(of: target) { _, index in
                guard let index else { return }
                proxy.scrollTo(index, anchor: .top)
                target = nil
            }
        }
    }

    @ViewBuilder
    private func results(_ filing: IndexedFiling) -> some View {
        let needle = query.lowercased()
        let matches = filing.searchText.indices.filter { filing.searchText[$0].contains(needle) }
        Text(matches.isEmpty ? "No matches" : "\(matches.count) \(matches.count == 1 ? "match" : "matches")")
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(matches.prefix(200), id: \.self) { index in
            Button {
                searching = false
                query = ""
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    target = index
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let heading = filing.document.blocks[..<index].last(where: { $0.kind == "heading" })?.text {
                        Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(Self.snippet(filing.searchText[index], around: needle, original: filing.document.blocks[index]))
                        .font(.subheadline).lineLimit(3).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.fill.quaternary, in: .rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private static func snippet(_ lower: String, around needle: String, original block: FilingDocument.Block) -> AttributedString {
        let text = block.text ?? block.rows?.map { $0.joined(separator: "  ") }.joined(separator: " · ") ?? ""
        let source = text.lowercased() == lower ? text : lower
        guard let range = source.range(of: needle) else { return AttributedString(String(source.prefix(240))) }
        let start = source.index(range.lowerBound, offsetBy: -80, limitedBy: source.startIndex) ?? source.startIndex
        var result = AttributedString((start > source.startIndex ? "…" : "") + source[start...].prefix(260))
        if let hit = result.range(of: String(source[range]), options: .caseInsensitive) {
            result[hit].font = .subheadline.weight(.bold)
            result[hit].foregroundColor = .accentColor
        }
        return result
    }

    private func load() async {
        failure = nil
        do {
            if url.pathExtension.lowercased() == "pdf" {
                var request = URLRequest(url: url, timeoutInterval: 60)
                request.setValue("Newswire iOS admin@bryce-newswire.workers.dev", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let document = PDFDocument(data: data) else { throw URLError(.cannotDecodeContentData) }
                pdf = document
                return
            }
            guard let api = NewswireAPI.validatedURL(FeedStore.shared.serverURL).map({ NewswireAPI(baseURL: $0) }) else {
                failure = "Set a Newswire server in Settings to read filings."
                return
            }
            let document = try await api.filingDocument(url)
            filing = await Task.detached(priority: .userInitiated) { IndexedFiling(document) }.value
            #if DEBUG
            if let index = CommandLine.arguments.firstIndex(of: "-filingBlock"), let raw = CommandLine.arguments.dropFirst(index + 1).first, let block = Int(raw) {
                try? await Task.sleep(for: .milliseconds(500))
                target = block
            }
            #endif
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct FilingBlockView: View {
    let block: FilingDocument.Block
    let scale: Double?

    var body: some View {
        switch block.kind {
        case "heading":
            let text = block.text ?? ""
            if text.hasPrefix("(") {
                Text(text).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(text)
                    .font(block.level == 1 ? .title3.weight(.semibold) : .headline)
                    .padding(.top, block.level == 1 ? 14 : 4)
                    .accessibilityAddTraits(.isHeader)
            }
        case "table":
            FilingTableView(rows: block.rows ?? [], scale: scale)
        default:
            Text(block.text ?? "")
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }
}

nonisolated enum FilingNumbers {
    static func scale(in text: String) -> Double? {
        let lower = text.lowercased()
        if lower.contains("in billions") { return 1e9 }
        if lower.contains("in millions") { return 1e6 }
        if lower.contains("in thousands") { return 1e3 }
        return nil
    }

    /// Rows whose figures are not amounts of money in the stated unit.
    static func isPlain(_ label: String) -> Bool {
        let lower = label.lowercased()
        return ["per share", "per diluted", "per basic", "eps", "basic", "diluted", "ratio", "margin", "rate", "percent", "days", "employees", "headcount"]
            .contains { lower.contains($0) }
    }

    /// "96,221" in a millions table becomes "$96.2B"; "(102)" becomes "−$102M".
    static func compact(_ text: String, scale: Double, shares: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains("%"), trimmed.contains(where: \.isNumber), !trimmed.contains(where: \.isLetter),
              let raw = Double(trimmed.filter { $0.isNumber || $0 == "." }) else { return nil }
        let negative = trimmed.hasPrefix("(") || trimmed.hasPrefix("-") || trimmed.hasPrefix("\u{2212}")
        let value = raw * scale
        guard value != 0 else { return trimmed }
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        let (divisor, suffix) = units.first { value >= $0.0 } ?? (1, "")
        let amount = value / divisor
        let places = amount >= 100 ? 0 : amount >= 10 ? 1 : 2
        var number = String(format: "%.\(places)f", amount)
        if number.contains(".") { while number.hasSuffix("0") { number.removeLast() }; if number.hasSuffix(".") { number.removeLast() } }
        return (negative ? "\u{2212}" : "") + (shares ? "" : "$") + number + suffix
    }
}

private struct FilingTableView: View {
    let rows: [[String]]
    let scale: Double?
    @State private var exact = false

    private func display(_ value: String, row: [String]) -> String {
        guard let scale, !exact, !FilingNumbers.isPlain(row[0]) else { return value }
        return FilingNumbers.compact(value, scale: scale, shares: row[0].lowercased().contains("shares")) ?? value
    }

    private static func isNumber(_ text: String) -> Bool {
        text.contains(where: \.isNumber) && !text.contains(where: \.isLetter)
    }
    private var width: Int { max(2, rows.map(\.count).max() ?? 0) }
    private var labelWidth: CGFloat { width > 3 ? 150 : 190 }
    /// Rows before the first figure are column headings, merged into one stacked heading per column.
    private var headerCount: Int { rows.prefix { !$0.dropFirst().contains(where: Self.isNumber) }.count }
    private var header: (label: String, columns: [String]) {
        let top = rows.prefix(headerCount)
        let label = top.map { $0.first ?? "" }.filter { !$0.isEmpty }.joined(separator: "\n")
        let columns = (1..<width).map { column in
            top.compactMap { column < $0.count && !$0[column].isEmpty ? $0[column] : nil }.joined(separator: "\n")
        }
        return (label, columns)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid }
                .scrollIndicators(.visible)
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 40)
                    }
                }
        }
        .background(.fill.quinary, in: .rect(cornerRadius: 16))
        .overlay(alignment: .bottomTrailing) {
            if scale != nil {
                Text(exact ? "As filed" : "Scaled")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .contentShape(.rect)
        .onTapGesture { if scale != nil { withAnimation(.easeOut(duration: 0.2)) { exact.toggle() } } }
        .sensoryFeedback(.selection, trigger: exact)
        .accessibilityHint(scale != nil ? "Double-tap to switch between scaled and as-filed figures" : "")
    }

    private var grid: some View {
        let header = header
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            if headerCount > 0 {
                GridRow(alignment: .bottom) {
                    Text(header.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(header.columns.indices, id: \.self) { column in
                        Text(header.columns[column])
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize()
                            .gridColumnAlignment(.trailing)
                    }
                }
                .padding(.bottom, 8)
                Divider().opacity(0.5)
            }
            ForEach(Array(rows.dropFirst(headerCount).enumerated()), id: \.offset) { offset, row in
                let section = row.dropFirst().allSatisfy(\.isEmpty)
                let total = !section && ["Total", "Net income", "Net loss"].contains { row[0].hasPrefix($0) }
                let top: CGFloat = section && offset > 0 ? 18 : 9
                let bottom: CGFloat = section ? 6 : 9
                if offset > 0 && !section { Divider().opacity(0.35) }
                GridRow(alignment: .firstTextBaseline) {
                    Text(row[0])
                        .font(section || total ? .subheadline.weight(.semibold) : .subheadline)
                        .frame(width: labelWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, top).padding(.bottom, bottom)
                    ForEach(1..<width, id: \.self) { column in
                        Text(column < row.count ? display(row[column], row: row) : "")
                            .font(total ? .subheadline.weight(.semibold) : .subheadline)
                            .monospacedDigit()
                            .fixedSize()
                            .padding(.top, top).padding(.bottom, bottom)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
        .padding(14)
        .padding(.bottom, scale == nil ? 0 : 12)
    }
}

private struct PDFReader: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
