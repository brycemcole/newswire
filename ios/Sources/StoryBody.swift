import SwiftUI

enum StoryHTML {
    struct Block: Identifiable {
        enum Kind: Equatable {
            case paragraph, heading(Int), quote, listItem(marker: String), rule, pre
        }
        let id: Int
        let kind: Kind
        let content: AttributedString
    }

    private static let detector = try! NSRegularExpression(
        pattern: #"<\s*/?\s*(?:p|br|div|span|ul|ol|li|h[1-6]|blockquote|pre|strong|em|b|i|u|s|strike|del|ins|small|sub|sup|a|code|kbd|samp|tt|mark|q|cite|var|hr|section|article|aside|header|footer|nav|figure|figcaption|table|thead|tbody|tfoot|tr|td|th|dl|dd|dt|font|center)\b"#,
        options: [.caseInsensitive]
    )
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:"[^"]*"|'[^']*'|[^>])*)>"#,
        options: [.caseInsensitive]
    )
    private static let hiddenPattern = try! NSRegularExpression(
        pattern: #"(?is)<(script|style|head)\b[\s\S]*?</\s*\1\s*>"#
    )
    private static let hrefPattern = try! NSRegularExpression(
        pattern: #"(?i)\bhref\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#
    )

    static func isHTML(_ text: String) -> Bool {
        detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func parse(_ html: String) -> [Block] {
        let normalized = normalizedHTML(html)
        guard isHTML(normalized) else {
            return [Block(id: 0, kind: .paragraph, content: AttributedString(decodeEntities(normalized)))]
        }
        var cleaned = normalized
        cleaned = hiddenPattern.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: " ")
        var parser = Parser()
        let source = cleaned as NSString
        let full = NSRange(location: 0, length: source.length)
        var cursor = 0
        for match in tagPattern.matches(in: cleaned, range: full) {
            if match.range.location > cursor {
                parser.text(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            parser.tag(closing: !group(match, 1, source).isEmpty, name: group(match, 2, source).lowercased(), attrs: group(match, 3, source))
            cursor = match.range.location + match.range.length
        }
        if cursor < source.length { parser.text(source.substring(from: cursor)) }
        parser.flush()
        return parser.blocks
    }

    static func plainText(_ text: String) -> String {
        parse(text).map { String($0.content.characters) }.joined(separator: " ")
    }

    private static func normalizedHTML(_ text: String) -> String {
        var result = text
        for _ in 0..<3 {
            guard !isHTML(result) else { break }
            let decoded = decodeEntities(result)
            guard decoded != result else { break }
            result = decoded
        }
        return result
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ source: NSString) -> String {
        let range = match.range(at: index)
        return range.location != NSNotFound ? source.substring(with: range) : ""
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while let amp = text[index...].firstIndex(of: "&") {
            result += text[index..<amp]
            let rest = text[text.index(after: amp)...]
            if let semi = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: semi) <= 10,
               let value = entityValue(String(rest[..<semi])) {
                result += value
                index = rest.index(after: semi)
            } else {
                result += "&"
                index = text.index(after: amp)
            }
        }
        result += text[index...]
        return result
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷",
        "middot": "·", "bull": "•", "laquo": "«", "raquo": "»", "sect": "§", "para": "¶",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "dagger": "†",
    ]

    private static func entityValue(_ entity: String) -> String? {
        guard entity.hasPrefix("#") else { return namedEntities[entity] }
        let digits = entity.dropFirst()
        if digits.first == "x" || digits.first == "X" {
            guard let value = UInt32(digits.dropFirst(), radix: 16) else { return nil }
            return scalarValue(value)
        }
        guard let value = UInt32(digits) else { return nil }
        return scalarValue(value)
    }

    private static func scalarValue(_ value: UInt32) -> String? {
        guard value > 0, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    private struct Parser {
        struct Format {
            var intents: InlinePresentationIntent = []
            var underline = false
            var link: URL?
        }

        var blocks: [Block] = []
        var buffer = AttributedString()
        var pendingSpace = false
        var format = Format()
        var formatStack: [Format] = []
        var quoteDepth = 0
        var preDepth = 0
        var headingLevel: Int?
        var listMarker: String?
        var lists: [(ordered: Bool, count: Int)] = []

        mutating func tag(closing: Bool, name: String, attrs: String) {
            switch name {
            case "br":
                if !closing { buffer += AttributedString("\n"); pendingSpace = false }
            case "hr":
                flush()
                if !closing { blocks.append(Block(id: blocks.count, kind: .rule, content: AttributedString())) }
            case "b", "strong": inline(closing: closing) { $0.intents.formUnion(.stronglyEmphasized) }
            case "i", "em", "cite", "var": inline(closing: closing) { $0.intents.formUnion(.emphasized) }
            case "u", "ins": inline(closing: closing) { $0.underline = true }
            case "s", "strike", "del": inline(closing: closing) { $0.intents.formUnion(.strikethrough) }
            case "code", "kbd", "samp", "tt": inline(closing: closing) { $0.intents.formUnion(.code) }
            case "a":
                inline(closing: closing) { _ in }
                if !closing { format.link = Self.linkTarget(attrs) }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if !closing { headingLevel = Int(name.dropFirst()); listMarker = nil }
            case "blockquote":
                flush()
                if closing {
                    quoteDepth = max(0, quoteDepth - 1)
                } else {
                    quoteDepth += 1
                    headingLevel = nil
                    listMarker = nil
                }
            case "ul", "ol":
                flush()
                if closing {
                    if !lists.isEmpty { lists.removeLast() }
                } else {
                    lists.append((name == "ol", 0))
                    headingLevel = nil
                }
            case "li":
                flush()
                if !closing {
                    if !lists.isEmpty {
                        lists[lists.count - 1].count += 1
                        let list = lists[lists.count - 1]
                        listMarker = list.ordered ? "\(list.count)." : "•"
                    } else {
                        listMarker = "•"
                    }
                    headingLevel = nil
                }
            case "pre":
                flush()
                if closing {
                    preDepth = max(0, preDepth - 1)
                } else {
                    preDepth += 1
                    headingLevel = nil
                    listMarker = nil
                }
            case "p", "div", "section", "article", "aside", "header", "footer", "nav", "figure", "figcaption", "dl", "dd", "dt", "table", "thead", "tbody", "tfoot", "tr":
                flush()
                if !closing { headingLevel = nil; listMarker = nil }
            default: break
            }
        }

        private mutating func inline(closing: Bool, _ apply: (inout Format) -> Void) {
            if closing {
                format = formatStack.popLast() ?? Format()
            } else {
                formatStack.append(format)
                apply(&format)
            }
        }

        mutating func text(_ raw: String) {
            let decoded = StoryHTML.decodeEntities(raw)
            if decoded.isEmpty { return }
            if preDepth > 0 {
                append(decoded)
                return
            }
            let piece = decoded.replacingOccurrences(of: "[ \t\r\n\u{000C}]+", with: " ", options: .regularExpression)
            if piece == " " {
                if attachable { pendingSpace = true }
                return
            }
            var body = piece[...]
            var trailing = false
            if body.first == " " {
                if attachable { pendingSpace = true }
                body = body.dropFirst()
            }
            if body.last == " " {
                trailing = true
                body = body.dropLast()
            }
            if !body.isEmpty {
                if pendingSpace && attachable { buffer += AttributedString(" ") }
                pendingSpace = false
                append(String(body))
            }
            pendingSpace = trailing && attachable
        }

        private var attachable: Bool {
            guard let last = buffer.characters.last else { return false }
            return last != " " && last != "\n"
        }

        private mutating func append(_ value: String) {
            var run = AttributedString(value)
            if !format.intents.isEmpty { run.inlinePresentationIntent = format.intents }
            if format.underline { run.underlineStyle = .single }
            if let link = format.link { run.link = link }
            buffer += run
        }

        mutating func flush() {
            guard !buffer.characters.isEmpty else { return }
            let kind: Block.Kind
            if preDepth > 0 {
                kind = .pre
            } else if let level = headingLevel {
                kind = .heading(level)
            } else if let marker = listMarker {
                kind = .listItem(marker: marker)
            } else if quoteDepth > 0 {
                kind = .quote
            } else {
                kind = .paragraph
            }
            blocks.append(Block(id: blocks.count, kind: kind, content: buffer))
            buffer = AttributedString()
            pendingSpace = false
            headingLevel = nil
            listMarker = nil
        }

        private static func linkTarget(_ attrs: String) -> URL? {
            guard let match = hrefPattern.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)),
                  let range = Range(match.range(at: 1), in: attrs) else { return nil }
            var href = attrs[range][...]
            if href.first == "\"" || href.first == "'" { href = href.dropFirst().dropLast() }
            guard let url = URL(string: StoryHTML.decodeEntities(String(href))),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
            return url
        }
    }
}

struct StoryBodyView: View {
    private let blocks: [StoryHTML.Block]
    private let inline: [Int: [Quote]]

    init(html: String, quotes: [Quote] = []) {
        blocks = StoryHTML.parse(html)
        inline = quotes.isEmpty ? [:] : QuoteInline.plan(blocks.map { String($0.content.characters) }, quotes: quotes)
    }

    private func content(_ block: StoryHTML.Block) -> AttributedString {
        guard let quotes = inline[block.id] else { return block.content }
        return QuoteInline.annotate(block.content, quotes: quotes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                blockView(block)
                    .padding(.bottom, gap(after: block))
            }
        }
    }

    private func gap(after block: StoryHTML.Block) -> CGFloat {
        guard block.id + 1 < blocks.count else { return 0 }
        let next = blocks[block.id + 1].kind
        switch (block.kind, next) {
        case (.listItem, .listItem): return 6
        case (_, .rule), (.rule, _): return 8
        default: return 14
        }
    }

    @ViewBuilder
    private func blockView(_ block: StoryHTML.Block) -> some View {
        switch block.kind {
        case .paragraph:
            Text(content(block))
                .font(.body)
                .lineSpacing(3)
        case .heading(let level):
            Text(block.content)
                .font(.system(headingStyle(level)).weight(.bold))
                .padding(.top, 4)
        case .quote:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Rectangle().fill(.quaternary).frame(width: 2)
                Text(block.content)
                    .font(.body)
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
            }
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(content(block))
                    .font(.body)
                    .lineSpacing(3)
            }
        case .rule:
            Divider()
        case .pre:
            Text(block.content)
                .font(.system(.footnote, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func headingStyle(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }
}
