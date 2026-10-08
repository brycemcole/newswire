import PDFKit
import SwiftUI
import Vision

nonisolated struct HousePTRTransaction: Identifiable, Hashable, Sendable {
    let asset: String
    let owner: String
    let type: String
    let tradeDate: String
    let notificationDate: String?
    let amount: String
    let symbol: String?

    var id: String { [asset, owner, type, tradeDate, amount].joined(separator: "|") }
}

private nonisolated struct PTRRecognizedToken: Sendable {
    let text: String
    let x: Double
    let y: Double
}

private nonisolated struct PTRDateLine: Sendable {
    var y: Double
    var tokens: [PTRRecognizedToken]
}

private nonisolated struct PTRTradeRecord: Sendable {
    let type: String
    let tradeDate: String
    let notificationDate: String
    let amount: String
}

private nonisolated struct PTRParseResult: Sendable {
    let transactions: [HousePTRTransaction]
    let recognizedText: String
}

private nonisolated enum PTRDocumentError: Error, Sendable {
    case invalidPDF
    case tooManyPages
}

private nonisolated enum PTRDocumentParser {
    private static let datePattern = try! NSRegularExpression(pattern: #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#)
    private static let trailingCode = try! NSRegularExpression(pattern: #"(?i)(?:^|\s)(P|S|E)(?:\s*\(([^)]*)\))?\s*$"#)
    private static let textLayerTickerPattern = try! NSRegularExpression(pattern: #"\(([A-Z][A-Z0-9.\-]{0,8})\)\s*\[[A-Z]{2,3}\]"#)
    private static let textLayerTradePattern = try! NSRegularExpression(pattern: #"(?i)(?:^|\s)(P|S|E)(?:\s*\((partial)\))?\s+(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\s+(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b"#)
    private static let ocrActionDatePattern = try! NSRegularExpression(pattern: #"(?i)\b(?:P|S|E)(?:\s*\(partial\))?\s+\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\s+\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#)
    private static let textLayerMoneyPattern = try! NSRegularExpression(pattern: #"\$\s*[\d,]+"#)
    private static let ocrTradeTailPattern = try! NSRegularExpression(pattern: #"(?i)\s+(?:P|S|E)(?:\s*\([^)]*\))?\s+\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\s+\d{1,2}[/-]\d{1,2}[/-]\d{2,4}.*$"#)
    private static let moneyPattern = try! NSRegularExpression(pattern: #"\$\s*([\d,]+)"#)

    static func parse(_ data: Data) throws -> PTRParseResult {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw PTRDocumentError.invalidPDF }
        guard document.pageCount <= 60 else { throw PTRDocumentError.tooManyPages }
        return try parseScannedPages(document, textLayerTrades: textLayerTrades(in: document))
    }

    private static func textLayerTrades(in document: PDFDocument) -> [[PTRTradeRecord]] {
        var pages: [[PTRTradeRecord]] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex), let pageText = page.string else { pages.append([]); continue }
            let lines = pageText.replacingOccurrences(of: "\0", with: "").components(separatedBy: .newlines)
            var trades: [PTRTradeRecord] = []
            for lineIndex in lines.indices {
                let line = lines[lineIndex]
                guard let match = firstMatch(in: line, pattern: textLayerTradePattern),
                      let code = capture(line, match: match, group: 1),
                      let tradeDate = capture(line, match: match, group: 3),
                      let notificationDate = capture(line, match: match, group: 4) else { continue }
                var amountText = line
                var nextLine = lineIndex + 1
                while nextLine < lines.count,
                      nextLine < lineIndex + 4,
                      firstMatch(in: lines[nextLine], pattern: textLayerTradePattern) == nil {
                    amountText += " " + lines[nextLine]
                    nextLine += 1
                }
                let amounts = matches(in: amountText, pattern: textLayerMoneyPattern)
                let type: String
                switch code.uppercased() {
                case "P": type = "Purchase"
                case "E": type = "Exchange"
                default: type = capture(line, match: match, group: 2) == nil ? "Sale" : "Partial sale"
                }
                let amount = amounts.count > 1 ? "\(amounts.first!)–\(amounts.last!)" : amounts.first ?? "Amount not reported"
                trades.append(PTRTradeRecord(type: type, tradeDate: isoDate(tradeDate), notificationDate: isoDate(notificationDate), amount: amount))
            }
            pages.append(trades)
        }
        return pages
    }

    private static func parseScannedPages(_ document: PDFDocument, textLayerTrades: [[PTRTradeRecord]]) throws -> PTRParseResult {
        var transactions: [HousePTRTransaction] = []
        var recognizedText: [String] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let tokens = try recognize(page)
            let orderedTokens = tokens.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y > $1.y }
            recognizedText.append(contentsOf: orderedTokens.map(\.text))
            var dateLines: [PTRDateLine] = []
            for token in tokens where !matches(in: token.text, pattern: datePattern).isEmpty &&
                (token.x >= 0.55 || firstMatch(in: token.text, pattern: ocrActionDatePattern) != nil) {
                if let index = dateLines.firstIndex(where: { abs($0.y - token.y) < 0.012 }) {
                    dateLines[index].tokens.append(token)
                } else {
                    dateLines.append(PTRDateLine(y: token.y, tokens: [token]))
                }
            }

            var availableTrades = textLayerTrades.indices.contains(pageIndex) ? textLayerTrades[pageIndex] : []
            for dateLine in dateLines.sorted(by: { $0.y > $1.y }) {
                let nearby = tokens.filter { abs($0.y - dateLine.y) < 0.04 }
                let action = nearby.compactMap { token -> (PTRRecognizedToken, String, String)? in
                    guard let (raw, type) = transactionType(token.text) else { return nil }
                    return (token, raw, type)
                }.min { left, right in
                    let leftScore = abs(left.0.y - dateLine.y) + abs(left.0.x - 0.43) * 0.05
                    let rightScore = abs(right.0.y - dateLine.y) + abs(right.0.x - 0.43) * 0.05
                    return leftScore < rightScore
                }
                let rowTokens = tokens.filter { abs($0.y - dateLine.y) <= 0.025 }
                let assetTokens = rowTokens.filter { token in
                    token.x >= 0.13 && token.x < 0.43 &&
                    !token.text.localizedCaseInsensitiveContains("filing status") &&
                    !token.text.localizedCaseInsensitiveContains("owner asset") &&
                    !token.text.localizedCaseInsensitiveContains("transactions") &&
                    !token.text.localizedCaseInsensitiveContains("filer information") &&
                    !token.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("F S")
                }
                var seenAssetLines = Set<String>()
                let assetText = assetTokens.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y > $1.y }
                    .map { cleanOCRAssetLine($0.text) }.filter { !$0.isEmpty && seenAssetLines.insert($0).inserted }
                let joinedAsset = normalize(assetText.joined(separator: " "))

                let dates = dateLine.tokens.sorted { $0.x < $1.x }
                    .flatMap { matches(in: $0.text, pattern: datePattern).map(isoDate) }
                guard let tradeDate = dates.first, !tradeDate.isEmpty else { continue }
                let notificationDate = dates.count > 1 ? dates[1] : nil
                let exactTradeIndex = availableTrades.firstIndex { trade in
                    trade.tradeDate == tradeDate && (notificationDate == nil || trade.notificationDate == notificationDate)
                }
                let tradeIndex = exactTradeIndex ?? availableTrades.firstIndex { $0.tradeDate == tradeDate }
                let textTrade = tradeIndex.map { availableTrades.remove(at: $0) }
                guard textTrade != nil || action != nil else { continue }

                let ownerCode = rowTokens.filter { $0.x >= 0.04 && $0.x < 0.145 }
                    .sorted { $0.y > $1.y }.compactMap(ownerCode(in:)).first ?? "F"
                let amountTokens = rowTokens.filter { $0.x >= 0.68 && $0.x < 0.89 }
                    .sorted { $0.y > $1.y }
                let money = amountTokens.flatMap { matches(in: $0.text, pattern: moneyPattern) }
                let amount = money.count >= 2 ? "\(money.first!)–\(money.last!)" : money.first ?? textTrade?.amount ?? "Amount not reported"
                let symbol = capture(joinedAsset, pattern: textLayerTickerPattern, group: 1)
                let asset = joinedAsset.count > 2
                    ? normalize(joinedAsset.replacingOccurrences(of: #"\s*\[[A-Z]+\]"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"\s*\([A-Z][A-Z0-9.\-]{0,8}\)\s*$"#, with: "", options: .regularExpression))
                    : "Asset name not recognized"
                let transaction = HousePTRTransaction(
                    asset: asset,
                    owner: ownerLabel(ownerCode),
                    type: textTrade?.type ?? action!.2,
                    tradeDate: tradeDate,
                    notificationDate: notificationDate,
                    amount: amount,
                    symbol: symbol
                )
                transactions.append(transaction)
            }
        }

        return PTRParseResult(transactions: transactions, recognizedText: String(recognizedText.joined(separator: " ").prefix(16000)))
    }

    private static func recognize(_ page: PDFPage) throws -> [PTRRecognizedToken] {
        let image = page.thumbnail(of: CGSize(width: 1800, height: 2500), for: .mediaBox)
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.0025
        try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return PTRRecognizedToken(text: text, x: observation.boundingBox.midX, y: observation.boundingBox.midY)
        }
    }

    private static func transactionType(_ text: String) -> (String, String)? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = value.uppercased()
        if ["P", "PURCHASE", "BUY"].contains(upper) { return (value, "Purchase") }
        if ["S", "SALE", "PARTIAL SALE", "S (PARTIAL)"].contains(upper) { return (value, upper.contains("PARTIAL") ? "Partial sale" : "Sale") }
        if ["E", "EXCHANGE"].contains(upper) { return (value, "Exchange") }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = trailingCode.firstMatch(in: value, range: range), let codeRange = Range(match.range(at: 1), in: value) else { return nil }
        let code = value[codeRange].uppercased()
        let partial = match.range(at: 2).location != NSNotFound
        return (value, code == "P" ? "Purchase" : code == "E" ? "Exchange" : partial ? "Partial sale" : "Sale")
    }

    private static func ownerCode(in token: PTRRecognizedToken) -> String? {
        let value = token.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["F", "S", "SP", "JT", "DC"].contains(value) ? value : nil
    }

    private static func ownerLabel(_ code: String) -> String {
        switch code {
        case "S", "SP": "Spouse"
        case "JT": "Joint"
        case "DC": "Dependent child"
        default: "Member"
        }
    }

    private static func cleanAssetLine(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trailingCode.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)), let range = Range(match.range, in: result) {
            result.removeSubrange(range)
        }
        return result
    }

    private static func cleanOCRAssetLine(_ value: String) -> String {
        var result = value
        if let match = firstMatch(in: result, pattern: ocrTradeTailPattern), let range = Range(match.range, in: result) {
            result.removeSubrange(range)
        }
        return cleanAssetLine(result)
    }

    private static func matches(in value: String, pattern: NSRegularExpression) -> [String] {
        let range = NSRange(value.startIndex..., in: value)
        return pattern.matches(in: value, range: range).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            return String(value[range]).replacingOccurrences(of: " ", with: "")
        }
    }

    private static func firstMatch(in value: String, pattern: NSRegularExpression) -> NSTextCheckingResult? {
        pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    }

    private static func capture(_ value: String, pattern: NSRegularExpression, group: Int) -> String? {
        guard let match = firstMatch(in: value, pattern: pattern) else { return nil }
        return capture(value, match: match, group: group)
    }

    private static func capture(_ value: String, match: NSTextCheckingResult, group: Int) -> String? {
        guard let range = Range(match.range(at: group), in: value) else { return nil }
        return String(value[range])
    }

    private static func isoDate(_ value: String) -> String {
        let parts = value.split(whereSeparator: { $0 == "/" || $0 == "-" }).compactMap { Int($0) }
        guard parts.count == 3 else { return value }
        let year = parts[2] < 100 ? (parts[2] < 50 ? 2000 + parts[2] : 1900 + parts[2]) : parts[2]
        return String(format: "%04d-%02d-%02d", year, parts[0], parts[1])
    }

    private static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct HousePTRDetailView: View {
    let member: String
    let filed: String
    let filingID: String
    let year: Int
    let source: URL

    @State private var transactions: [HousePTRTransaction] = []
    @State private var recognizedText = ""
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("HOUSE CLERK · PTR \(filingID)")
                        .font(.caption2.weight(.semibold).monospaced()).tracking(0.7).foregroundStyle(.secondary)
                    Text(member).font(.title3.weight(.semibold))
                    Text("Filed \(DataFormat.day(filed)) · Report may include the member, spouse, or dependent child")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Trade disclosures are delayed. Amounts are reported ranges, not exact trade values.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if isLoading {
                    ProgressView("Reading official filing…")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                } else if let error {
                    ContentUnavailableView("Filing could not be read", systemImage: "doc.text.magnifyingglass", description: Text(error))
                } else if !transactions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("REPORTED TRANSACTIONS").font(.caption.weight(.semibold).monospaced()).tracking(0.5)
                            Spacer()
                            Text("\(transactions.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }.padding(.bottom, 6)
                        ForEach(Array(transactions.enumerated()), id: \.offset) { index, transaction in
                            transactionRow(transaction)
                            if index < transactions.count - 1 { Divider() }
                        }
                    }
                } else {
                    ContentUnavailableView("No transactions were recognized", systemImage: "doc.text.magnifyingglass", description: Text("The filing is still available as the original House Clerk PDF below."))
                    if !recognizedText.isEmpty {
                        DisclosureGroup("Show recognized filing text") {
                            Text(recognizedText).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                        }
                        .font(.subheadline)
                    }
                }

                Link(destination: source) {
                    Label("Open original House Clerk PDF", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .navigationTitle("House PTR")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: source) { await load() }
    }

    @ViewBuilder
    private func transactionRow(_ transaction: HousePTRTransaction) -> some View {
        let content = HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.asset).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text("\(transaction.owner) · Trade \(DataFormat.day(transaction.tradeDate))\(transaction.notificationDate.map { " · Filed \(DataFormat.day($0))" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(transaction.type).font(.subheadline.weight(.semibold))
                    .foregroundStyle(transaction.type.localizedCaseInsensitiveContains("sale") ? .orange : .green)
                Text(transaction.amount).font(.caption.monospacedDigit()).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                if let symbol = transaction.symbol { Text(symbol).font(.caption2.weight(.semibold).monospaced()).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: 120, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())

        if let symbol = transaction.symbol {
            NavigationLink { QuoteDetail(symbol: symbol) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        guard source.scheme == "https", source.host == "disclosures-clerk.house.gov" else {
            error = "The filing link is not an official House Clerk document."
            isLoading = false
            return
        }
        do {
            var request = URLRequest(url: source)
            request.timeoutInterval = 45
            request.setValue("Mozilla/5.0 (compatible; Newswire/1.0)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 30_000_000 else {
                throw PTRDocumentError.invalidPDF
            }
            let result = try await Task.detached(priority: .userInitiated) {
                try PTRDocumentParser.parse(data)
            }.value
            transactions = result.transactions
            recognizedText = result.recognizedText
        } catch PTRDocumentError.tooManyPages {
            error = "This report is over 60 pages. Open the original PDF to review it."
        } catch {
            self.error = "The official PDF could not be downloaded or processed. Try opening the source PDF below."
        }
        isLoading = false
    }
}
