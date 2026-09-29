import Foundation

nonisolated enum ArticleExtractor {
    struct Result: Sendable {
        let paragraphs: [String]
        let image: URL?
        let complete: Bool
        var text: String { String(paragraphs.joined(separator: "\n").prefix(6000)) }
    }

    private static let hidden = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<(script|style|noscript|svg|template|iframe|head|nav|footer|aside|form|dialog|button|figure|select|textarea)\b[^>]*>[\s\S]*?</\1\s*>"#,
        options: [.caseInsensitive]
    )
    private static let block = try! NSRegularExpression(
        pattern: #"<(p|li)\b[^>]*>([\s\S]*?)</\1\s*>"#,
        options: [.caseInsensitive]
    )
    private static let jsonString = #"((?:[^"\\]|\\.)*)""#
    private static let articleBody = try! NSRegularExpression(pattern: #""articleBody"\s*:\s*""# + jsonString)
    private static let embeddedHTML = try! NSRegularExpression(pattern: #""(?:content|body|html|articleHtml|bodyHtml)"\s*:\s*""# + jsonString)

    static func extract(html: String, baseURL: URL) -> Result {
        let image = metaImage(in: html, relativeTo: baseURL)
        if let body = strings(articleBody, in: html).max(by: { $0.count < $1.count }) {
            let paragraphs = clean(body.split(whereSeparator: \.isNewline).map(String.init), minimum: 20)
            if paragraphs.joined().count >= 200 { return Result(paragraphs: paragraphs, image: image, complete: true) }
        }
        let embedded = strings(embeddedHTML, in: html)
            .filter { $0.range(of: #"<p\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
            .map { clean(blocks(in: $0), minimum: 20) }
            .max { $0.joined().count < $1.joined().count } ?? []
        let dom = clean(blocks(in: html), minimum: 40)
        var paragraphs = embedded.joined().count >= dom.joined().count ? embedded : dom
        let complete = paragraphs.joined().count >= 400 || (!embedded.isEmpty && paragraphs == embedded)
        if paragraphs.isEmpty, let summary = metaDescription(in: html) { paragraphs = [summary] }
        return Result(paragraphs: paragraphs, image: image, complete: complete)
    }

    static func clean(_ candidates: [String], minimum: Int) -> [String] {
        var seen = Set<String>()
        return candidates.compactMap { raw in
            let text = raw.replacing(/,? opens new tab/, with: "")
                .replacing(/[\u{200B}-\u{200D}\u{2060}\u{FEFF}]/, with: "")
                .replacing(/\s+/, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bullet = text.hasPrefix("• ")
            guard text.count > (bullet ? 20 : minimum), !isBoilerplate(text), !looksLikeCode(text), seen.insert(text).inserted else { return nil }
            return text
        }
    }

    static func isBoilerplate(_ text: String) -> Bool {
        text.contains(/^(?i)(reporting by|writing by|editing by|additional reporting|our standards|adds |updates with|sign up|sign in|subscribe|read more|click here|get a look|this article|if you type a company|have a tip\?|found a factual error|close dialogue|skip to|advertisement|support the guardian|newsletter promotion|connecting decision makers|before it's here, it's on the bloomberg terminal|we use cookies|by continuing|already a subscriber|create a free account|to continue reading)/)
    }

    static func looksLikeCode(_ text: String) -> Bool {
        if text.contains(/function\s*\(|=>|\}\s*\)|\bdocument\.|\bwindow\.|\b(?:var|const) \w+\s*=|\|\||&&|\/\*\*|\w\.\w+\(/) { return true }
        let symbols = text.unicodeScalars.filter { "{};=<>[]|\\".unicodeScalars.contains($0) }.count
        return Double(symbols) / Double(max(text.count, 1)) > 0.03
    }

    static func blocks(in html: String) -> [String] {
        let visible = hidden.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: " ")
        let source = visible as NSString
        return block.matches(in: visible, range: NSRange(location: 0, length: source.length)).prefix(80).compactMap { match in
            let inner = source.substring(with: match.range(at: 2))
            guard source.substring(with: match.range(at: 1)).lowercased() == "li" else { return strip(inner) }
            guard inner.range(of: #"<(div|h[1-6]|img|picture|time|ul|ol)\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            let unlinked = strip(inner.replacing(/(?i)<a\b[^>]*>[\s\S]*?<\/a\s*>/, with: ""))
            return unlinked.count(where: \.isLetter) < 3 ? nil : "• " + strip(inner)
        }
    }

    private static func strings(_ pattern: NSRegularExpression, in html: String) -> [String] {
        let source = html as NSString
        return pattern.matches(in: html, range: NSRange(location: 0, length: source.length)).prefix(40).compactMap { match in
            let raw = source.substring(with: match.range(at: 1))
            guard raw.count >= 80 else { return nil }
            return try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))
        }
    }

    private static func metaTags(in html: String) -> [String] {
        var cursor = html.startIndex
        var tags: [String] = []
        while tags.count < 150,
              let start = html.range(of: "<meta", options: .caseInsensitive, range: cursor..<html.endIndex),
              let end = html[start.upperBound...].firstIndex(of: ">") {
            tags.append(String(html[start.lowerBound...end]))
            cursor = html.index(after: end)
        }
        return tags
    }

    static func metaImage(in html: String, relativeTo baseURL: URL) -> URL? {
        for tag in metaTags(in: html) {
            let lowered = tag.lowercased()
            if lowered.contains("og:image") || lowered.contains("twitter:image"),
               let content = attribute("content", in: tag),
               let url = URL(string: strip(content), relativeTo: baseURL)?.absoluteURL,
               url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    private static func metaDescription(in html: String) -> String? {
        for tag in metaTags(in: html) {
            let lowered = tag.lowercased()
            guard lowered.contains("\"og:description\"") || lowered.contains("\"description\"") || lowered.contains("\"twitter:description\""),
                  let content = attribute("content", in: tag) else { continue }
            let text = strip(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 60 { return text }
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let nameRange = tag.range(of: #"\b\#(name)\s*="#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        var start = nameRange.upperBound
        while start < tag.endIndex, tag[start].isWhitespace { start = tag.index(after: start) }
        guard start < tag.endIndex else { return nil }
        let quote = tag[start]
        if quote == "\"" || quote == "'" {
            let valueStart = tag.index(after: start)
            guard let end = tag[valueStart...].firstIndex(of: quote) else { return nil }
            return String(tag[valueStart..<end])
        }
        let end = tag[start...].firstIndex(where: { $0.isWhitespace || $0 == ">" }) ?? tag.endIndex
        return String(tag[start..<end])
    }

    static func strip(_ html: String) -> String {
        var text = html.replacing(/<br\s*\/?>/.ignoresCase(), with: " ").replacing(/<[^>]+>/, with: "")
        for (entity, value) in ["&quot;": "\"", "&#39;": "'", "&apos;": "'", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&amp;": "&"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacing(/&#(x[0-9a-fA-F]+|\d+);/) { match in
            let code = String(match.1)
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
        return text.replacing(/[\u{200B}-\u{200D}\u{2060}\u{FEFF}]/, with: "").replacing(/\s+/, with: " ")
    }
}
