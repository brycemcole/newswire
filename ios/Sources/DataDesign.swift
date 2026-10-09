import SwiftUI

/// A titled group of rows on a glass card, the data screens' equivalent of an inset grouped list section.
struct DataCard<Content: View>: View {
    var title: String?
    var trailing: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader) }
                    Spacer(minLength: 8)
                    if let trailing { Text(trailing).font(.footnote).foregroundStyle(.tertiary) }
                }
                .padding(.horizontal, 16)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// Divider inset to the row text, like a grouped list, so the leading badge column stays clean.
struct RowDivider: View {
    var inset: CGFloat = 52
    var body: some View { Divider().padding(.leading, inset) }
}

/// Settings-style symbol on a tinted rounded square.
struct ToolIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Leading identity mark for a row: a ticker when there is one, otherwise the name's initials.
struct Monogram: View {
    let text: String
    var tint: Color = .secondary
    var circle = false

    var body: some View {
        Text(text)
            .font(.system(size: text.count > 3 ? 10 : 12, weight: .bold))
            .lineLimit(1).minimumScaleFactor(0.6)
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
            .padding(.horizontal, 3)
            .frame(width: 38, height: 38)
            .background(tint.opacity(tint == .secondary ? 0.16 : 0.15), in: circle ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: 10, style: .continuous)))
            .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let skip: Set<String> = ["the", "of", "and", "&", "inc", "llc", "lp", "co", "corp", "ltd"]
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "&" }).filter { !skip.contains($0.lowercased()) }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

nonisolated enum DataText {
    private static let acronyms: Set<String> = ["LLC", "LP", "LLP", "L.P.", "N.A.", "NA", "PLC", "AG", "SA", "NV", "SE", "ETF", "USA", "US", "UK", "II", "III", "IV", "REIT", "ADR", "ADS", "SPDR", "AI", "AMD", "IBM", "ASA", "AB", "NYSE", "JP", "BNY", "UBS", "HSBC", "TD", "RBC", "BMO", "CIBC", "MSCI", "S&P"]
    private static let words: [String: String] = ["ISHARES": "iShares", "TR": "Trust", "HLDG": "Holdings", "HLDGS": "Holdings", "CENTY": "Century", "JPMORGAN": "JPMorgan", "MGMT": "Management", "INTL": "International", "TECHN": "Technologies", "GRP": "Group"]

    /// SEC filings shout names in capitals; render them the way the company writes them.
    static func name(_ raw: String) -> String {
        let letters = raw.filter(\.isLetter)
        guard letters.count > 3, letters == letters.uppercased() else { return raw }
        return raw.split(separator: " ").map { word in
            let token = String(word)
            let bare = token.trimmingCharacters(in: .punctuationCharacters)
            if let replacement = words[bare] { return token.replacingOccurrences(of: bare, with: replacement) }
            if acronyms.contains(token) || acronyms.contains(bare) { return token }
            if bare.contains(where: \.isNumber) { return token.lowercased() }
            return token.prefix(1).uppercased() + token.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    static func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// "2026-06-30" → "Q2 2026".
    static func quarter(_ text: String) -> String {
        guard let date = DataFormat.date(String(text.prefix(10))) else { return text }
        let components = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: date)
        return "Q\(((components.month ?? 1) - 1) / 3 + 1) \(components.year ?? 0)"
    }

    /// "2026-08-07" → "Aug 7, 2026", or "Aug 7" in the current year.
    static func day(_ text: String) -> String {
        guard let date = DataFormat.date(String(text.prefix(10))) else { return text }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: .now)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func number(_ text: Substring) -> Double? { Double(text.replacingOccurrences(of: ",", with: "")) }

    /// "CUSIP 594918104 · 554,281,607 shares · prior 500,000" → "554.3M shares · was 500K".
    static func holdingDetail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let parts = detail.components(separatedBy: " · ").compactMap { part -> String? in
            if part.hasPrefix("CUSIP") { return nil }
            if let match = part.wholeMatch(of: /([\d,]+) shares( in prior report)?/), let shares = number(match.1) {
                return match.2 == nil ? "\(compact(shares)) shares" : "Held \(compact(shares)) shares last quarter"
            }
            if let match = part.wholeMatch(of: /prior ([\d,]+)/), let shares = number(match.1) { return "was \(compact(shares))" }
            return part
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "+814,273 (+18.4%) shares" → ("+18.4%", green); huge percentages from tiny prior stakes fall back to the share count.
    static func positionChange(_ label: String?) -> (text: String, tint: Color)? {
        guard let label else { return nil }
        switch label {
        case "NEW": return ("New position", .green)
        case "EXITED": return ("Sold out", .red)
        default: break
        }
        guard let match = label.firstMatch(of: /([+−-])([\d,]+) \(([+−-]?)([\d,]+(?:\.\d+)?)%\)/), let shares = number(match.2) else {
            return (label, label.hasPrefix("+") ? .green : label.hasPrefix("−") ? .orange : .secondary)
        }
        let up = match.1 == "+"
        let sign = up ? "+" : "−"
        if let percent = number(match.4), percent < 1000 {
            return ("\(sign)\(percent.formatted(.number.precision(.fractionLength(0...1))))%", up ? .green : .orange)
        }
        return ("\(sign)\(compact(shares)) sh", up ? .green : .orange)
    }
}
