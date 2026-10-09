import Charts
import MapKit
import SwiftUI

nonisolated struct DataPayload: Decodable, Sendable, Hashable {
    nonisolated struct Row: Decodable, Sendable, Hashable {
        let label: String
        let value: String
        let detail: String?
        let change: Double?
        let changeLabel: String?
        let date: String?
        let symbol: String?
        let series: String?
        let story: String?
        let url: String?
        let destination: String?
        let points: [Double]?
        let forecast: String?
        let previous: String?
        let actual: String?
        let surprise: Double?
        let ptrId: String?
        let ptrYear: Int?
    }
    nonisolated struct Section: Decodable, Sendable, Hashable {
        let title: String
        var rows: [Row]
    }
    nonisolated struct Page: Decodable, Sendable, Hashable {
        let total: Int
        let offset: Int
        let limit: Int
    }
    nonisolated struct Point: Decodable, Sendable, Hashable {
        let x: String
        let value: Double
    }
    nonisolated struct Series: Decodable, Sendable, Hashable {
        let label: String
        let unit: String?
        let points: [Point]
    }
    nonisolated struct Pin: Decodable, Sendable, Hashable {
        let lat: Double
        let lon: Double
        let label: String
        let detail: String?
        let heading: Double?
        let kind: String?
    }
    nonisolated struct Region: Decodable, Sendable, Hashable {
        let center: [Double]
        let span: Double
        let pins: [Pin]
    }
    let title: String
    let source: String
    let url: String
    let asOf: String
    let note: String?
    var sections: [Section]
    var page: Page?
    let chart: Series?
    let map: Region?
    let text: String
}

nonisolated struct DataRoute: Hashable, Identifiable, Sendable {
    let path: String
    var items: [String: String] = [:]
    var id: String { token }

    /// Routes travel through the dock's symbol callback as `data:` tokens so the existing selection path can open them.
    var token: String {
        var components = URLComponents()
        components.path = path
        components.queryItems = items.isEmpty ? nil : items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return "data:" + (components.string ?? path)
    }

    init(_ path: String, _ items: [String: String] = [:]) {
        self.path = path
        self.items = items
    }

    init?(token: String) {
        guard token.hasPrefix("data:"), let components = URLComponents(string: String(token.dropFirst(5))), !components.path.isEmpty else { return nil }
        path = components.path
        items = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }) { first, _ in first }
    }
}

struct FollowedInstitution: Codable, Identifiable, Hashable {
    let cik: String
    let name: String
    var id: String { cik }
    var route: DataRoute { DataRoute("sec/institutions", ["manager": cik]) }
}

@Observable final class FollowedInstitutionStore {
    static let shared = FollowedInstitutionStore()
    private let key = "followedSECInstitutions"
    private(set) var institutions: [FollowedInstitution]

    private init() {
        institutions = (try? JSONDecoder().decode([FollowedInstitution].self, from: UserDefaults.standard.data(forKey: key) ?? Data())) ?? []
    }

    func contains(_ cik: String) -> Bool { institutions.contains { $0.cik == cik } }

    func toggle(_ institution: FollowedInstitution) {
        if contains(institution.cik) {
            institutions.removeAll { $0.cik == institution.cik }
        } else {
            institutions.append(institution)
            institutions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        if let data = try? JSONEncoder().encode(institutions) { UserDefaults.standard.set(data, forKey: key) }
    }
}

nonisolated struct TerminalFunction: Identifiable, Sendable {
    let code: String
    let title: String
    let symbol: String
    let route: DataRoute
    var summary = ""
    var id: String { code }

    var category: String {
        switch code {
        case "WEI", "FXC", "CMDTY": "Markets"
        case "WIRP", "GC", "GCEU", "GCJP", "CRED", "WB", "BTMM": "Rates"
        case "SHIP", "MAPS": "Shipping"
        case "INST", "FLOW", "PTR": "Institutions"
        default: "Economy"
        }
    }

    var tint: Color {
        switch code {
        case "WEI", "FXC", "CMDTY", "BTMM": .green
        case "ECO", "ECOS", "ECST", "JOBS", "INFL": .blue
        case "WIRP", "GC", "GCEU", "GCJP", "CRED", "WB": .orange
        case "WEO": .cyan
        case "SHIP", "MAPS": .teal
        case "INST", "FLOW", "PTR": .indigo
        default: .gray
        }
    }

    static let all: [TerminalFunction] = [
        TerminalFunction(code: "WEI", title: "World indices", symbol: "globe", route: DataRoute("board/world"), summary: "Major stock indexes around the world"),
        TerminalFunction(code: "FXC", title: "Currencies", symbol: "dollarsign.arrow.circlepath", route: DataRoute("board/fx"), summary: "Dollar, euro, yen and other major pairs"),
        TerminalFunction(code: "CMDTY", title: "Commodities", symbol: "drop.fill", route: DataRoute("board/commodities"), summary: "Oil, gold, gas, metals and crops"),
        TerminalFunction(code: "ECO", title: "Economic calendar", symbol: "calendar", route: DataRoute("calendar"), summary: "Upcoming reports with forecasts"),
        TerminalFunction(code: "WIRP", title: "Fed odds", symbol: "building.columns.fill", route: DataRoute("fed/odds"), summary: "Market-implied odds for the next Fed meetings"),
        TerminalFunction(code: "GC", title: "Yield curve", symbol: "chart.xyaxis.line", route: DataRoute("yields"), summary: "US Treasury yields from 1 month to 30 years"),
        TerminalFunction(code: "GCEU", title: "Euro yield curve", symbol: "eurosign", route: DataRoute("yields", ["region": "euro"]), summary: "Euro area government bond yields"),
        TerminalFunction(code: "GCJP", title: "JGB yields", symbol: "yensign", route: DataRoute("yields", ["region": "japan"]), summary: "Japanese government bond yields"),
        TerminalFunction(code: "ECOS", title: "Surprises", symbol: "exclamationmark.bubble.fill", route: DataRoute("releases", ["impact": "medium"]), summary: "Recent reports against expectations"),
        TerminalFunction(code: "ECST", title: "Economy", symbol: "chart.bar.fill", route: DataRoute("macro"), summary: "Growth, jobs, prices and sentiment"),
        TerminalFunction(code: "JOBS", title: "Jobs", symbol: "person.2.fill", route: DataRoute("macro", ["group": "jobs"]), summary: "Payrolls, unemployment and claims"),
        TerminalFunction(code: "INFL", title: "Inflation", symbol: "cart.fill", route: DataRoute("macro", ["group": "inflation"]), summary: "CPI, PCE and inflation expectations"),
        TerminalFunction(code: "CRED", title: "Credit spreads", symbol: "creditcard.fill", route: DataRoute("macro", ["group": "credit"]), summary: "Corporate bond risk premiums"),
        TerminalFunction(code: "WB", title: "World bonds", symbol: "percent", route: DataRoute("macro", ["group": "global"]), summary: "Government bond yields by country"),
        TerminalFunction(code: "BTMM", title: "US rates", symbol: "banknote.fill", route: DataRoute("board/rates"), summary: "Fed funds, SOFR and Treasury bills"),
        TerminalFunction(code: "SHIP", title: "Shipping", symbol: "ferry.fill", route: DataRoute("chokepoints"), summary: "Daily ship transits through key straits"),
        TerminalFunction(code: "MAPS", title: "Ship map", symbol: "map.fill", route: DataRoute("ships", ["area": "hormuz"]), summary: "Vessels near Hormuz, Suez and other chokepoints"),
        TerminalFunction(code: "WEO", title: "IMF outlook", symbol: "globe.europe.africa.fill", route: DataRoute("world"), summary: "IMF growth and inflation forecasts"),
        TerminalFunction(code: "INST", title: "13F filers", symbol: "building.2.fill", route: DataRoute("sec/institution-search"), summary: "What BlackRock, Berkshire and other managers hold"),
        TerminalFunction(code: "FLOW", title: "Institutional flow", symbol: "arrow.up.arrow.down", route: DataRoute("finviz/institutional-flow", ["side": "buying"]), summary: "Stocks where institutions added or cut the most"),
        TerminalFunction(code: "PTR", title: "House trades", symbol: "person.text.rectangle.fill", route: DataRoute("congress/ptrs", ["days": "90"]), summary: "Stock trades disclosed by House members"),
    ]
}

nonisolated enum TerminalCommand: Hashable, Sendable {
    case route(DataRoute, String)
    case symbol(String, String)

    var token: String {
        switch self {
        case .route(let route, _): route.token
        case .symbol(let symbol, _): symbol
        }
    }
    var title: String {
        switch self {
        case .route(_, let title), .symbol(_, let title): title
        }
    }

    static let exchanges: [String: String] = [
        "US": "", "UN": "", "UW": "", "UQ": "", "JP": ".T", "JT": ".T", "HK": ".HK", "LN": ".L", "GR": ".DE", "GY": ".DE", "FP": ".PA", "NA": ".AS",
        "IM": ".MI", "SM": ".MC", "SW": ".SW", "SE": ".SW", "CN": ".TO", "CT": ".TO", "AU": ".AX", "KS": ".KS", "TT": ".TW", "IN": ".NS", "IB": ".BO",
        "SS": ".ST", "DC": ".CO", "NO": ".OL", "FH": ".HE", "BB": ".BR", "SP": ".SI", "BZ": ".SA", "MM": ".MX", "SJ": ".JO", "IT": ".TA", "CH": ".SS", "CS": ".SZ",
    ]
    static let fredSeries: Set<String> = [
        "DFEDTARU", "DFEDTARL", "EFFR", "SOFR", "WALCL", "PAYEMS", "UNRATE", "ICSA", "JTSJOL", "CES0500000003", "CPIAUCSL", "CPILFESL", "PCEPILFE", "T5YIE",
        "GDPC1", "UMCSENT", "RSAFS", "INDPRO", "DGS2", "DGS10", "DGS30", "T10Y2Y", "T10Y3M", "MORTGAGE30US", "M2SL", "BAMLC0A0CM", "BAMLC0A4CBBB", "BAMLH0A0HYM2",
        "BAMLH0A3HYC", "WPU101", "PPIACO", "CCSA", "PCE", "GDP", "HOUST", "PERMIT", "DCOILWTICO", "VIXCLS", "SP500", "NFCI", "STLFSI4",
    ]

    /// Bloomberg-style short codes: a function (`ECO`, `WIRP`), a function with an argument (`CN fed`, `AAPL HDS`),
    /// a foreign listing (`7203 JP`), or a FRED series id typed directly.
    static func parse(_ input: String) -> TerminalCommand? {
        let words = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        guard let first = words.first?.uppercased() else { return nil }
        let rest = words.dropFirst().joined(separator: " ")
        if words.count == 1, let function = TerminalFunction.all.first(where: { $0.code == first || ($0.code == "CMDTY" && first == "GLCO") || ($0.code == "ECST" && first == "ECON") || ($0.code == "ECO" && first == "ECOW") || ($0.code == "INST" && first == "13F") || ($0.code == "MAPS" && first == "SHIPS") }) {
            return .route(function.route, "\(function.code) · \(function.title)")
        }
        if words.count == 1, fredSeries.contains(first) { return .route(DataRoute("series/\(first)"), "\(first) · FRED series") }
        let prefixes: Set<String> = ["CN", "NEWS", "WIRE", "FRED", "GOVT", "CONT", "USAS", "EQS", "HDS", "CF", "INS", "FORM4", "WEO", "SHIP", "MAPS", "INST", "13F", "FLOW", "PTR", "POL", "CONGRESS"]
        if words.count == 2, !prefixes.contains(first), let suffix = exchanges[words[1].uppercased()], first.range(of: #"^[A-Z0-9.\-]{1,12}$"#, options: .regularExpression) != nil {
            var code = first
            if suffix == ".HK", code.allSatisfy(\.isNumber) { code = String(repeating: "0", count: max(0, 4 - code.count)) + code }
            if suffix.isEmpty { code = code.replacingOccurrences(of: ".", with: "-") }
            return .symbol(code + suffix, "\(code + suffix) · \(words[1].uppercased()) listing")
        }
        if words.count == 2, ["HDS", "CF", "INS", "FORM4"].contains(words[1].uppercased()) { return ticker(words[1].uppercased(), first) }
        guard !rest.isEmpty else { return nil }
        switch first {
        case "INST", "13F":
            let normalized = rest.lowercased().replacingOccurrences(of: " ", with: "-")
            if ["flow", "market", "market-wide", "finviz", "buying", "selling"].contains(normalized) {
                let side = normalized == "selling" ? "selling" : "buying"
                return .route(DataRoute("finviz/institutional-flow", ["side": side]), "Finviz · Institutional \(side)")
            }
            let query = rest.isEmpty ? "BlackRock" : rest
            return .route(DataRoute("sec/institution-search", ["q": query]), "SEC 13F · \(query)")
        case "FLOW":
            let side = rest.lowercased().hasPrefix("sell") ? "selling" : "buying"
            return .route(DataRoute("finviz/institutional-flow", ["side": side]), "Finviz · Institutional \(side)")
        case "PTR", "POL", "CONGRESS":
            var items = ["days": "90"]
            if !rest.isEmpty { items["member"] = rest }
            return .route(DataRoute("congress/ptrs", items), rest.isEmpty ? "House transaction disclosures" : "House disclosures · \(rest)")
        case "CN", "NEWS", "WIRE": return .route(DataRoute("wire/search", ["q": rest, "days": "90"]), "Search the wire for “\(rest)”")
        case "FRED":
            let id = rest.uppercased()
            if words.count == 2, id.range(of: #"^[A-Z0-9_]{3,30}$"#, options: .regularExpression) != nil, id.contains(where: \.isNumber) || fredSeries.contains(id) || id.count >= 5 && !rest.contains(where: \.isLowercase) {
                return .route(DataRoute("series/\(id)"), "\(id) · FRED series")
            }
            return .route(DataRoute("series/search", ["q": rest]), "Search FRED for “\(rest)”")
        case "GOVT", "CONT", "USAS": return .route(DataRoute("contracts", ["company": rest]), "Federal contracts: \(rest)")
        case "EQS":
            let region = words[1].lowercased()
            let sector = words.dropFirst(2).joined(separator: " ")
            var items = ["region": region]
            if let match = ["Technology", "Financial Services", "Healthcare", "Consumer Cyclical", "Consumer Defensive", "Industrials", "Energy", "Basic Materials", "Utilities", "Real Estate", "Communication Services"]
                .first(where: { !sector.isEmpty && $0.lowercased().hasPrefix(sector.lowercased()) || sector.lowercased() == "banks" && $0 == "Financial Services" }) { items["sector"] = match }
            return .route(DataRoute("screener", items), "Screen \(region.uppercased()) stocks\(items["sector"].map { " · \($0)" } ?? "")")
        case "HDS", "CF", "INS", "FORM4": return ticker(first, rest)
        case "WEO":
            return .route(DataRoute("world", ["indicator": rest.lowercased()]), "IMF outlook: \(rest)")
        case "SHIP": return .route(DataRoute("chokepoints", ["name": rest]), "Shipping: \(rest)")
        case "MAPS":
            let area = rest.lowercased().replacingOccurrences(of: " ", with: "-")
            let known = ["hormuz", "bab-el-mandeb", "suez", "malacca", "panama", "bosporus", "taiwan", "gibraltar"].first { $0.hasPrefix(area) || area.contains($0) } ?? "hormuz"
            return .route(DataRoute("ships", ["area": known]), "Ship map: \(known)")
        default: return nil
        }
    }

    private static func ticker(_ function: String, _ symbol: String) -> TerminalCommand {
        let ticker = symbol.uppercased()
        switch function {
        case "HDS": return .route(DataRoute("sec/holders", ["symbol": ticker]), "\(ticker) holders")
        case "CF": return .route(DataRoute("sec/filings", ["symbol": ticker]), "\(ticker) SEC filings")
        default: return .route(DataRoute("sec/insiders", ["symbol": ticker]), "\(ticker) insider trades")
        }
    }
}

/// Last good response per route, so screens open on known values and refresh behind them.
nonisolated enum DataCache {
    private static let directory = URL.cachesDirectory.appending(path: "data-v1", directoryHint: .isDirectory)
    private static let maximumBytes = 300 * 1024 * 1024

    private static func file(_ route: DataRoute) -> URL {
        let name = route.token.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return directory.appending(path: String(name.prefix(180)) + ".json")
    }

    static func store(_ data: Data, for route: DataRoute) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(route)
        try? data.write(to: url, options: .atomic)
        trim(keeping: url)
    }

    private static func trim(keeping newest: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > maximumBytes else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > maximumBytes {
            if url == newest, entries.count == 1 { continue }
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    static func load(_ route: DataRoute) async -> (payload: DataPayload, age: TimeInterval)? {
        await Task.detached(priority: .userInitiated) {
            let url = file(route)
            guard let data = try? Data(contentsOf: url), let payload = try? NewswireAPI.decoder().decode(DataPayload.self, from: data) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return (payload, -modified.timeIntervalSinceNow)
        }.value
    }
}

extension NewswireAPI {
    @concurrent func data(_ route: DataRoute) async throws -> DataPayload {
        let bytes = try await dataBytes("v1/data/\(route.path)", route.items)
        let payload = try Self.decoder().decode(DataPayload.self, from: bytes)
        DataCache.store(bytes, for: route)
        return payload
    }

    @concurrent func dataTool(_ name: String, arguments: [String: String]) async throws -> DataPayload {
        try Self.decoder().decode(DataPayload.self, from: await dataBytes("v1/data/tool/\(name)", arguments))
    }

    @concurrent func dataCatalog() async throws -> Data { try await dataBytes("v1/data/tools.json", [:]) }

    private func dataBytes(_ path: String, _ items: [String: String]) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !items.isEmpty { components?.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components?.url else { throw WireError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            if let error = try? Self.decoder().decode(APIError.self, from: data) { throw error }
            throw WireError.status(response.statusCode)
        }
        return data
    }
}

struct DataScreen: View {
    let route: DataRoute
    private let preview: Bool
    @State private var payload: DataPayload?
    @State private var error: String?
    @State private var history: EconomicHistory.Snapshot?
    @State private var historyPoints: [DataPayload.Point]?
    @State private var historyError: String?
    @State private var historyLimit = 24
    @State private var lookback: Int
    @State private var resultLimit: Int
    @State private var institutionalManager: String
    @State private var institutionalOffset: Int
    @State private var institutionalLoadingMore = false
    @State private var institutionalFlowSide: String
    @State private var institutionalFilter = "Buying"
    @State private var showAllQuarters = false
    @State private var searchText: String
    @State private var submittedSearch: String
    @State private var shipArea: String
    @State private var followedInstitutions = FollowedInstitutionStore.shared
    @State private var institutionSearchRoute: DataRoute?
    @State private var window = EconomicHistory.Window(rawValue: UserDefaults.standard.string(forKey: "economicHistoryWindow") ?? "5Y") ?? .five
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Screens laid out as native grouped cards rather than the generic row list.
    static let designedPaths: Set<String> = ["sec/institutions", "sec/institution-search", "finviz/institutional-flow", "congress/ptrs", "ships"]

    init(route: DataRoute, previewPayload: DataPayload? = nil) {
        self.route = route
        preview = previewPayload != nil
        _payload = State(initialValue: previewPayload)
        _institutionalManager = State(initialValue: route.items["manager"] ?? "0002012383")
        _institutionalOffset = State(initialValue: Int(route.items["offset"] ?? "0") ?? 0)
        _institutionalFlowSide = State(initialValue: route.items["side"] ?? "buying")
        let search = route.items["q"] ?? route.items["member"] ?? ""
        _searchText = State(initialValue: search)
        _submittedSearch = State(initialValue: search)
        _shipArea = State(initialValue: route.items["area"] ?? "hormuz")
        if previewPayload != nil, let index = CommandLine.arguments.firstIndex(of: "-historyRange"), let raw = CommandLine.arguments.dropFirst(index + 1).first, let window = EconomicHistory.Window(rawValue: raw) {
            _window = State(initialValue: window)
        }
        if previewPayload != nil, let index = CommandLine.arguments.firstIndex(of: "-dataFilter"), let raw = CommandLine.arguments.dropFirst(index + 1).first {
            _institutionalFilter = State(initialValue: raw)
        }
        _lookback = State(initialValue: Int(route.items["days"] ?? "") ?? (route.path == "economic/history" || route.path == "releases" ? 60 : route.path == "contracts" ? 365 : 90))
        _resultLimit = State(initialValue: Int(route.items["limit"] ?? "") ?? (route.path == "sec/insiders" ? 10 : 15))
    }

    private var lookbackOptions: [(String, Int)] {
        switch route.path {
        case "releases", "economic/history": [("1 month", 30), ("2 months", 60), ("3 months", 90)]
        case "contracts", "wire/search": [("3 months", 90), ("1 year", 365), ("5 years", 1825), ("10 years", 3650)]
        case "congress/ptrs": [("1 month", 30), ("3 months", 90), ("1 year", 365)]
        default: []
        }
    }
    private var requestRoute: DataRoute {
        var result = route
        if !lookbackOptions.isEmpty { result.items["days"] = String(lookback) }
        if route.path == "wire/search" { result.items["limit"] = "50" }
        if route.path == "sec/filings" || route.path == "sec/insiders" { result.items["limit"] = String(resultLimit) }
        if route.path == "sec/institutions" {
            result.items["manager"] = institutionalManager
            result.items["offset"] = String(institutionalOffset)
        }
        if route.path == "sec/institution-search" { result.items["q"] = submittedSearch }
        if route.path == "congress/ptrs" { result.items["member"] = submittedSearch.isEmpty ? nil : submittedSearch }
        if route.path == "ships" { result.items["area"] = shipArea }
        if route.path == "finviz/institutional-flow" { result.items["side"] = institutionalFlowSide }
        return result
    }
    private var awaitingSearch: Bool { route.path == "sec/institution-search" && submittedSearch.isEmpty }
    private var designed: Bool { Self.designedPaths.contains(route.path) }

    private var presentation: SeriesPresentation? { payload.flatMap { SeriesPresentation(route: route, payload: $0, observations: historyPoints) } }
    private var visiblePoints: [DataPayload.Point] { EconomicHistory.visible(historyPoints ?? payload?.chart?.points ?? [], window: window) }

    private var live: Bool { route.path.hasPrefix("board") || route.path == "fed/odds" || route.path == "ships" }

    private var title: String {
        switch route.path {
        case "sec/institutions": "13F Holdings"
        case "sec/institution-search": "13F Filers"
        case "finviz/institutional-flow": "Institutional Flow"
        case "congress/ptrs": "House Trades"
        case "ships": "Ship Map"
        default: presentation?.title ?? payload?.title ?? "Loading"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: designed ? 22 : 12) {
                if awaitingSearch {
                    institutionSearchHome
                } else if let payload {
                    if let error { Text("Could not refresh: \(error)").font(.footnote).foregroundStyle(.secondary) }
                    if let presentation {
                        seriesOverview(presentation)
                    } else if !designed, let explanation = DataExplanation.page(route) {
                        explanationCard(explanation)
                    }
                    if !lookbackOptions.isEmpty {
                        Picker("Look back", selection: $lookback) {
                            ForEach(lookbackOptions, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if route.path == "calendar" || route.path == "releases" {
                        NavigationLink {
                            DataScreen(route: DataRoute("economic/history", ["days": "90"]))
                        } label: {
                            Label("Browse past economic reports", systemImage: "clock.arrow.circlepath").font(.subheadline.weight(.semibold))
                        }
                    }
                    if !designed, let chart = payload.chart, chart.points.count > 1 {
                        QuoteSection(presentation?.chartLabel ?? chart.label) {
                            VStack(alignment: .leading, spacing: 12) {
                                if presentation != nil {
                                    Picker("History range", selection: $window) {
                                        ForEach(EconomicHistory.Window.allCases) { Text($0.rawValue).tag($0) }
                                    }
                                    .pickerStyle(.segmented)
                                }
                                Text(presentation?.unitLabel ?? chart.unit ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                                DataChart(series: presentation == nil ? chart : DataPayload.Series(label: presentation?.chartLabel ?? chart.label, unit: chart.unit, points: EconomicHistory.chart(visiblePoints))).frame(height: 190)
                                if presentation != nil, let first = visiblePoints.first, let last = visiblePoints.last {
                                    Text("\(presentation?.period(first.x) ?? first.x) – \(presentation?.period(last.x) ?? last.x)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    switch route.path {
                    case "sec/institutions": institutionalReport(payload)
                    case "sec/institution-search": institutionSearchReport(payload)
                    case "finviz/institutional-flow": finvizInstitutionalReport(payload)
                    case "congress/ptrs": congressionalPTRReport(payload)
                    case "ships": shipReport(payload)
                    default:
                        if let presentation {
                            seriesComparisons(presentation)
                            explanationCard(presentation.explanation)
                            seriesHistory(presentation)
                        } else {
                            ForEach(payload.sections, id: \.title) { section in
                                QuoteSection(section.title) {
                                    VStack(spacing: 0) {
                                        if section.rows.isEmpty {
                                            Text("Nothing to show.").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                                            link(row)
                                            if index < section.rows.count - 1 { Divider() }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if route.path == "sec/filings" || route.path == "sec/insiders" {
                        let maximum = route.path == "sec/filings" ? 50 : 20
                        if resultLimit < maximum {
                            Button("Load older \(route.path == "sec/filings" ? "filings" : "transactions")") { resultLimit = maximum }
                                .font(.subheadline.weight(.semibold))
                        } else {
                            Text("Showing up to \(maximum) recent filings available through this source. Open the source below for its full archive.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if designed { sourceFooter(payload) } else { footer(payload) }
                } else if let error {
                    ContentUnavailableView("Data unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                        .padding(.top, 60)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: payload)
        }
        .defaultScrollAnchor(preview && CommandLine.arguments.contains("-historyListPreview") ? .bottom : .top)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .modifier(DataSearch(enabled: route.path == "sec/institution-search" || route.path == "congress/ptrs",
                             text: $searchText,
                             prompt: route.path == "congress/ptrs" ? "Member name" : "Manager, fund, or company",
                             submit: submitSearch))
        .onChange(of: searchText) { _, value in
            if value.trimmingCharacters(in: .whitespaces).isEmpty, !submittedSearch.isEmpty { submittedSearch = "" }
        }
        .toolbar { toolbarContent }
        .navigationDestination(item: $institutionSearchRoute) { DataScreen(route: $0) }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(); await loadHistory() }
        .onChange(of: window) { _, value in
            historyLimit = 24
            UserDefaults.standard.set(value.rawValue, forKey: "economicHistoryWindow")
        }
        .task(id: payload?.title) { await loadHistory() }
        .task(id: phase == .active ? requestRoute : nil) {
            guard phase == .active, !preview, !awaitingSearch else { return }
            if payload == nil, let cached = await DataCache.load(requestRoute) {
                payload = cached.payload
                if route.path == "sec/institutions" { institutionalOffset = cached.payload.page?.offset ?? 0 }
                if !live && cached.age < 300 { return }
            }
            await load()
            while live, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await load()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if route.path == "sec/institutions", let payload {
            let cik = route.items["manager"] ?? institutionalManager
            let name = DataText.name(payload.title.replacingOccurrences(of: " institutional positions", with: ""))
            let followed = followedInstitutions.contains(cik)
            ToolbarItem(placement: .topBarTrailing) {
                Button { institutionSearchRoute = DataRoute("sec/institution-search") } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search 13F filers")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { followedInstitutions.toggle(FollowedInstitution(cik: cik, name: name)) } label: {
                    Image(systemName: followed ? "star.fill" : "star")
                }
                .tint(followed ? .yellow : nil)
                .accessibilityLabel(followed ? "Unfollow \(name)" : "Follow \(name)")
            }
        }
    }

    private func submitSearch() {
        submittedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        guard !preview, !awaitingSearch else { return }
        guard let url = NewswireAPI.validatedURL(FeedStore.shared.serverURL) else { error = WireError.configuration.localizedDescription; return }
        do {
            payload = try await NewswireAPI(baseURL: url).data(requestRoute)
            if route.path == "sec/institutions" { institutionalOffset = payload?.page?.offset ?? institutionalOffset }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMoreInstitutionalHoldings() async {
        guard route.path == "sec/institutions", let page = payload?.page,
              (payload?.sections.first(where: { $0.title == "All reported positions" })?.rows.count ?? 0) < page.total,
              let url = NewswireAPI.validatedURL(FeedStore.shared.serverURL) else { return }
        institutionalLoadingMore = true
        defer { institutionalLoadingMore = false }
        let loaded = payload?.sections.first(where: { $0.title == "All reported positions" })?.rows.count ?? 0
        var nextRoute = requestRoute
        nextRoute.items["offset"] = String(loaded)
        do {
            let next = try await NewswireAPI(baseURL: url).data(nextRoute)
            guard let nextRows = next.sections.first(where: { $0.title == "All reported positions" })?.rows, var updated = payload else { return }
            updated.sections = updated.sections.map { section in
                guard section.title == "All reported positions" else { return section }
                var appended = section
                appended.rows.append(contentsOf: nextRows)
                return appended
            }
            let loadedTotal = (updated.sections.first(where: { $0.title == "All reported positions" })?.rows.count ?? loaded + nextRows.count)
            updated.page = DataPayload.Page(total: next.page?.total ?? page.total, offset: loadedTotal, limit: next.page?.limit ?? page.limit)
            payload = updated
            institutionalOffset = loadedTotal
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadHistory() async {
        guard let payload, let series = SeriesPresentation(route: route, payload: payload) else { return }
        do {
            let snapshot = try await EconomicHistory.load(series.id)
            let points = await EconomicHistory.prepare(snapshot.observations, transform: series.transform)
            guard !Task.isCancelled else { return }
            history = snapshot
            historyPoints = points
            historyError = nil
        } catch is CancellationError {} catch {
            historyError = "Full history could not be fetched. Showing the available server chart; try refreshing."
        }
    }

    // MARK: 13F filer search

    private static let popularManagers: [(String, String)] = [
        ("BlackRock", "BlackRock"), ("Vanguard Group", "Vanguard Group"), ("Berkshire Hathaway", "Berkshire Hathaway"), ("Fidelity (FMR)", "FMR"),
        ("Citadel Advisors", "Citadel Advisors"), ("Bridgewater Associates", "Bridgewater"), ("Renaissance Technologies", "Renaissance Technologies"), ("Jane Street", "Jane Street"),
    ]

    private var institutionSearchHome: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !followedInstitutions.institutions.isEmpty {
                DataCard(title: "Following") {
                    ForEach(Array(followedInstitutions.institutions.enumerated()), id: \.element.id) { index, institution in
                        NavigationLink { DataScreen(route: institution.route) } label: {
                            managerRow(institution.name, subtitle: "CIK \(Int(institution.cik).map(String.init) ?? institution.cik)")
                        }
                        .buttonStyle(.plain)
                        if index < followedInstitutions.institutions.count - 1 { RowDivider() }
                    }
                }
            }
            DataCard(title: "Popular managers",
                     footer: "Form 13F reports are quarter-end holdings filed up to 45 days later. They show what a manager owned, not what it is trading today.") {
                ForEach(Array(Self.popularManagers.enumerated()), id: \.offset) { index, manager in
                    Button {
                        searchText = manager.1
                        submittedSearch = manager.1
                    } label: { managerRow(manager.0, subtitle: nil) }
                    .buttonStyle(.plain)
                    if index < Self.popularManagers.count - 1 { RowDivider() }
                }
            }
        }
    }

    private func managerRow(_ name: String, subtitle: String?) -> some View {
        let display = DataText.name(name)
        return HStack(spacing: 12) {
            Monogram(text: Monogram.initials(display), tint: .indigo, circle: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(display).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func institutionSearchReport(_ payload: DataPayload) -> some View {
        let rows = payload.sections.first?.rows ?? []
        if rows.isEmpty {
            ContentUnavailableView.search(text: submittedSearch).padding(.top, 40)
        } else {
            DataCard(title: rows.count == 1 ? "1 filer" : "\(rows.count) filers", footer: "Parent companies and affiliates that report separately appear as separate filers.") {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let quarter = DataText.quarter(row.value.replacingOccurrences(of: "As of ", with: ""))
                    let subtitle = [quarter, row.date.map { "filed " + DataText.day($0) }].compactMap(\.self).joined(separator: " · ")
                    if let raw = row.destination, let destination = DataRoute(token: raw) {
                        NavigationLink { DataScreen(route: destination) } label: { managerRow(row.label, subtitle: subtitle) }.buttonStyle(.plain)
                    } else {
                        managerRow(row.label, subtitle: subtitle)
                    }
                    if index < rows.count - 1 { RowDivider() }
                }
            }
        }
    }

    // MARK: 13F portfolio

    private func institutionalReport(_ payload: DataPayload) -> some View {
        let overview = payload.sections.first(where: { $0.title == "Quarter overview" })?.rows ?? []
        func metric(_ label: String) -> String { overview.first(where: { $0.label == label })?.value ?? "—" }
        let period = overview.first(where: { $0.label == "Reporting period" })
        let portfolio = overview.first(where: { $0.label == "Reported 13F value" })
        let filed = period?.detail.flatMap { $0.hasPrefix("Filed ") ? String($0.dropFirst(6)) : nil }
        let priorPeriod = payload.sections.first(where: { $0.title == "Recent filings" })?.rows.dropFirst().first?.label.components(separatedBy: "as of ").last
        let valueChange = portfolio?.detail?.firstMatch(of: /change ([+−-]\$[\d.]+[KMBT]?)/).map { String($0.1) }
        let holdings = payload.sections.first(where: { $0.title == "All reported positions" })
        let history = payload.sections.first(where: { $0.title == "Historical quarters" })?.rows ?? []
        let managerName = DataText.name(payload.title.replacingOccurrences(of: " institutional positions", with: ""))
        let groups: [(String, String)] = institutionalFilter == "Buying"
            ? [("New positions", "New positions"), ("Increased positions", "Added to")]
            : [("Reduced positions", "Trimmed"), ("Exited positions", "Sold out")]

        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(managerName).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                Text([period.map { DataText.quarter($0.value) + " holdings" }, filed.map { "filed " + DataText.day($0) }].compactMap(\.self).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            DataCard {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reported value").font(.subheadline).foregroundStyle(.secondary)
                    Text(portfolio?.value ?? "—").font(.system(.largeTitle, weight: .bold)).monospacedDigit()
                    if let valueChange {
                        Text("\(valueChange) since \(priorPeriod.map(DataText.quarter) ?? "last quarter")")
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                            .foregroundStyle(valueChange.hasPrefix("+") ? Color.green : .orange)
                    }
                }
                .padding(.vertical, 14)
                Divider()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 140 : 68), alignment: .leading)], alignment: .leading, spacing: 12) {
                    activityStat("New", metric("New positions"), .green)
                    activityStat("Added", metric("Increased positions"), .green)
                    activityStat("Trimmed", metric("Reduced positions"), .orange)
                    activityStat("Sold out", metric("Exited positions"), .red)
                }
                .padding(.vertical, 14)
            }

            Picker("Portfolio view", selection: $institutionalFilter) {
                Text("Buying").tag("Buying")
                Text("Selling").tag("Selling")
                Text("All holdings").tag("All")
            }
            .pickerStyle(.segmented)

            if institutionalFilter == "All", let holdings {
                DataCard(title: "Largest positions", trailing: "\((payload.page?.total ?? holdings.rows.count).formatted()) total") {
                    ForEach(Array(holdings.rows.enumerated()), id: \.offset) { index, row in
                        positionRow(row)
                        if index < holdings.rows.count - 1 { RowDivider() }
                    }
                    if let page = payload.page, holdings.rows.count < page.total {
                        Divider()
                        Button {
                            Task { await loadMoreInstitutionalHoldings() }
                        } label: {
                            HStack(spacing: 8) {
                                if institutionalLoadingMore { ProgressView().controlSize(.small) }
                                Text(institutionalLoadingMore ? "Loading" : "Show \(min(page.limit, page.total - holdings.rows.count)) more")
                            }
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .disabled(institutionalLoadingMore)
                    }
                }
            } else {
                ForEach(groups, id: \.0) { key, title in
                    let rows = payload.sections.first(where: { $0.title == key })?.rows ?? []
                    DataCard(title: title, trailing: rows.isEmpty ? nil : "Largest \(rows.count) by value") {
                        if rows.isEmpty {
                            Text("None this quarter").font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 48)
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            positionRow(row)
                            if index < rows.count - 1 { RowDivider() }
                        }
                    }
                }
            }

            if !history.isEmpty {
                let shown = showAllQuarters ? history : Array(history.prefix(4))
                DataCard(title: "Past quarters") {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                        let quarter = DataText.quarter(row.label.replacingOccurrences(of: "As of ", with: ""))
                        let filedLabel = row.date.map { "Filed " + DataText.day($0) } ?? row.value
                        let label = HStack {
                            Text(quarter).font(.body.weight(.medium))
                            Spacer()
                            Text(filedLabel).font(.subheadline).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 48).contentShape(.rect)
                        if let raw = row.destination, let destination = DataRoute(token: raw) {
                            NavigationLink { DataScreen(route: destination) } label: { label }.buttonStyle(.plain)
                        } else {
                            label
                        }
                        if index < shown.count - 1 { Divider() }
                    }
                    if history.count > 4 {
                        Divider()
                        Button(showAllQuarters ? "Show fewer" : "Show all \(history.count) quarters") {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showAllQuarters.toggle() }
                        }
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
            }

            if let explanation = DataExplanation.page(route) {
                aboutCard("About 13F data", [explanation.meaning, explanation.reading] + [explanation.methodology].compactMap(\.self))
            }
        }
    }

    private func activityStat(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Int(value).map { $0.formatted() } ?? value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func positionRow(_ row: DataPayload.Row) -> some View {
        let name = DataText.name(row.label)
        let change = DataText.positionChange(row.changeLabel)
        let content = HStack(spacing: 12) {
            Monogram(text: row.symbol ?? Monogram.initials(name))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                if let detail = DataText.holdingDetail(row.detail) {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.value).font(.body.weight(.semibold)).monospacedDigit()
                if let change {
                    Text(change.text).font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(change.tint)
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)

        if let symbol = row.symbol {
            NavigationLink { QuoteDetail(symbol: symbol) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    // MARK: Institutional flow

    private func flowRank(_ title: String) -> Int {
        if title.hasPrefix("Top holders") { return 3 }
        if title.hasPrefix("Top performers") { return 4 }
        if title.hasPrefix("Recently listed") { return 1 }
        if title.hasPrefix("Listing history") { return 2 }
        return 0
    }

    private func flowTitle(_ title: String) -> String {
        if title.hasPrefix("Top holders") { return "Largest holders of these stocks" }
        if title.hasPrefix("Top performers") { return "How they're trading today" }
        if title.hasPrefix("Recently listed") { return "Recent listings" }
        if title.hasPrefix("Listing history") { return "Listing date unknown" }
        return "Established companies"
    }

    private func flowFooter(_ title: String) -> String? {
        if title.hasPrefix("Recently listed") { return "Listed in the last 18 months. IPO and spinoff allocations can exaggerate these changes." }
        if title.hasPrefix("Top holders") { return "Combined reported value across the first 8 screened stocks." }
        return nil
    }

    private func finvizInstitutionalReport(_ payload: DataPayload) -> some View {
        let sections = payload.sections.filter { !$0.rows.isEmpty }.sorted { flowRank($0.title) < flowRank($1.title) }
        return VStack(alignment: .leading, spacing: 22) {
            Text("Large US stocks where total institutional ownership changed most in the latest quarterly filings.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            Picker("Institutional ownership direction", selection: $institutionalFlowSide) {
                Text("Ownership rising").tag("buying")
                Text("Ownership falling").tag("selling")
            }
            .pickerStyle(.segmented)
            ForEach(sections, id: \.title) { section in
                DataCard(title: flowTitle(section.title), footer: flowFooter(section.title)) {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                        if section.title.hasPrefix("Top holders") {
                            flowHolderRow(row)
                        } else {
                            flowStockRow(row)
                        }
                        if index < section.rows.count - 1 { RowDivider() }
                    }
                }
            }
            if sections.isEmpty {
                ContentUnavailableView("No matching stocks", systemImage: "chart.bar.xaxis", description: Text("No large-cap stocks moved in this direction."))
            }
            if let note = payload.note { aboutCard("About this data", [note]) }
        }
    }

    @ViewBuilder
    private func flowStockRow(_ row: DataPayload.Row) -> some View {
        let parts = (row.detail ?? "").components(separatedBy: " · ")
        let today = row.changeLabel == "TODAY"
        let company = parts.first.map(DataText.name) ?? row.label
        let facts = parts.dropFirst().compactMap { part -> String? in
            if let match = part.wholeMatch(of: /Institutional ownership ([\d.]+)%/), let value = Double(match.1) { return "\(value.formatted(.number.precision(.fractionLength(0))))% held" }
            if let match = part.wholeMatch(of: /Market cap ([\d.]+)([KMBT])/), let value = Double(match.1) { return "$\(value.formatted(.number.precision(.fractionLength(0...1))))\(match.2)" }
            if let match = part.wholeMatch(of: /Institutional ownership change (.+)/) { return "ownership \(match.1)" }
            if part.hasPrefix("Price ") { return today ? String(part.dropFirst(6)) : nil }
            return nil
        }
        let positive = (row.change ?? 0) >= 0 && !row.value.hasPrefix("−") && !row.value.hasPrefix("-")
        let content = HStack(spacing: 12) {
            Monogram(text: row.symbol ?? row.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(company).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.value).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(positive ? Color.green : .orange)
                Text(today ? "today" : "ownership").font(.footnote).foregroundStyle(.secondary)
            }
            .fixedSize()
        }
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)

        if let symbol = row.symbol {
            NavigationLink { QuoteDetail(symbol: symbol) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    @ViewBuilder
    private func flowHolderRow(_ row: DataPayload.Row) -> some View {
        let name = DataText.name(row.label)
        let stocks = row.detail?.firstMatch(of: /in (\d+) of the top (\d+)/).map { "Holds \($0.1) of \($0.2) stocks" }
        let reported = row.detail?.firstMatch(of: /latest report (\d{4}-\d{2}-\d{2})/).map { DataText.quarter(String($0.1)) }
        let content = HStack(spacing: 12) {
            Monogram(text: Monogram.initials(name), tint: .indigo, circle: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text([stocks, reported].compactMap(\.self).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.value).font(.body.weight(.semibold)).monospacedDigit().fixedSize()
            if row.destination != nil {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)

        if let raw = row.destination, let route = DataRoute(token: raw) {
            NavigationLink { DataScreen(route: route) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    // MARK: House disclosures

    private func congressionalPTRReport(_ payload: DataPayload) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let rows = (payload.sections.first?.rows ?? []).filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }
        let days = Dictionary(grouping: rows) { $0.date ?? "" }.sorted { $0.key > $1.key }
        return VStack(alignment: .leading, spacing: 22) {
            Text("Stock trades that House members, spouses and dependents reported to the Clerk. Reports can be filed up to 45 days after a trade.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            ForEach(days, id: \.key) { day, items in
                DataCard(title: DataFormat.date(day).map { Calendar.current.isDateInToday($0) ? "Today" : Calendar.current.isDateInYesterday($0) ? "Yesterday" : $0.formatted(.dateTime.weekday(.wide).month(.wide).day()) } ?? "Filed") {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, row in
                        ptrRow(row)
                        if index < items.count - 1 { RowDivider() }
                    }
                }
            }
            if rows.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No reports", systemImage: "doc.text.magnifyingglass", description: Text("No reports were filed in this period. Try a longer range."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    @ViewBuilder
    private func ptrRow(_ row: DataPayload.Row) -> some View {
        let first = (row.detail ?? "").components(separatedBy: " · ").first ?? ""
        let district = first.wholeMatch(of: /([A-Z]{2})(\d{1,2})/).map { match in Int(match.2) == 0 ? "\(match.1) at large" : "\(match.1)-\(Int(match.2) ?? 0)" }
        let content = HStack(spacing: 12) {
            Monogram(text: Monogram.initials(row.label), tint: .indigo, circle: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text([district, "Periodic transaction report"].compactMap(\.self).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)

        if let id = row.ptrId, let year = row.ptrYear, let source = row.url.flatMap(URL.init(string:)) {
            NavigationLink { HousePTRDetailView(member: row.label, filed: row.date ?? "", filingID: id, year: year, source: source) } label: { content }.buttonStyle(.plain)
        } else {
            link(row)
        }
    }

    // MARK: Ship map

    private static let shipAreas: [(id: String, name: String, center: [Double], span: Double)] = [
        ("hormuz", "Hormuz", [26.4, 56.4], 2.4), ("bab-el-mandeb", "Bab el-Mandeb", [12.7, 43.4], 2.4), ("suez", "Suez", [30.4, 32.4], 2.2),
        ("malacca", "Malacca", [2.5, 101.5], 4.5), ("panama", "Panama", [9.1, -79.7], 1.2), ("bosporus", "Bosporus", [41.1, 29.05], 0.6),
        ("taiwan", "Taiwan Strait", [24.4, 119.6], 3.5), ("gibraltar", "Gibraltar", [36.0, -5.6], 1.2),
    ]

    private func shipReport(_ payload: DataPayload) -> some View {
        let area = Self.shipAreas.first { $0.id == shipArea } ?? Self.shipAreas[0]
        let region = payload.map.flatMap { map in abs((map.center.first ?? 0) - area.center[0]) < 0.01 ? map : nil }
            ?? DataPayload.Region(center: area.center, span: area.span, pins: [])
        let pins = region.pins
        let kinds = Dictionary(grouping: pins) { $0.kind ?? "Other" }.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        let transits = payload.sections.first(where: { $0.title == "Daily transits" })?.rows.first
        return VStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.shipAreas, id: \.id) { option in
                        let selected = option.id == shipArea
                        Button(option.name) { shipArea = option.id }
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.white : .primary)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .background(selected ? AnyShapeStyle(Color.teal) : AnyShapeStyle(.clear), in: .capsule)
                            .glassEffect(selected ? .identity : .regular.interactive(), in: .capsule)
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -16)

            ShipMap(region: region)
                .id("\(area.id)-\(pins.count)")
                .frame(height: 340)
                .clipShape(.rect(cornerRadius: 22, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Label(pins.isEmpty ? "No live positions" : "\(pins.count) vessels · last 6 hours",
                          systemImage: pins.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "dot.radiowaves.left.and.right")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).frame(minHeight: 32)
                        .glassEffect(.regular, in: .capsule)
                        .padding(12)
                }

            if !kinds.isEmpty {
                HStack(spacing: 14) {
                    ForEach(kinds.prefix(5), id: \.0) { kind, count in
                        HStack(spacing: 5) {
                            Circle().fill(ShipMap.tint(kind)).frame(width: 8, height: 8)
                            Text("\(kind) \(count)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 4)
            } else {
                Text("Live vessel positions aren't coming in for this strait right now. Daily traffic below is measured from satellite AIS.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }

            if let transits {
                DataCard(title: "Daily transits") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(transits.value).font(.title2.weight(.bold)).monospacedDigit()
                            Spacer()
                            if let change = transits.change {
                                Text("\(change >= 0 ? "+" : "−")\(abs(change).formatted(.number.precision(.fractionLength(0...1))))% vs 30-day avg")
                                    .font(.subheadline.weight(.medium)).monospacedDigit()
                                    .foregroundStyle(change >= 0 ? Color.green : .orange)
                            }
                        }
                        Text(["7-day average", transits.detail].compactMap(\.self).joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let chart = payload.chart, chart.points.count > 1 {
                            DataChart(series: chart).frame(height: 150).padding(.top, 10)
                        }
                        if let date = transits.date {
                            Text("Through \(DataText.day(date))").font(.footnote).foregroundStyle(.tertiary).padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 14)
                }
            }

            ForEach(payload.sections.filter { $0.title != "Daily transits" && !$0.rows.isEmpty }, id: \.title) { section in
                DataCard(title: section.title) {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 12) {
                            Circle().fill(ShipMap.tint(section.title == "By type" ? row.label : row.detail?.components(separatedBy: " · ").first)).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DataText.name(row.label)).font(.body.weight(.medium)).lineLimit(1)
                                if let detail = row.detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.value).font(.body.weight(.semibold)).monospacedDigit()
                        }
                        .frame(minHeight: 52)
                        if index < section.rows.count - 1 { RowDivider(inset: 22) }
                    }
                }
            }
        }
    }

    // MARK: Shared

    private func aboutCard(_ title: String, _ paragraphs: [String]) -> some View {
        DataCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(paragraphs, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.top, 8)
            } label: {
                Label(title, systemImage: "info.circle").font(.body.weight(.medium)).foregroundStyle(.primary)
            }
            .tint(.secondary)
            .padding(.vertical, 14)
        }
    }

    private func sourceFooter(_ payload: DataPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = URL(string: payload.url) {
                Link(destination: source) {
                    Label("View on \(payload.source.components(separatedBy: " (").first ?? payload.source)", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                }
            }
            Text("Updated \(DataFormat.stamp(payload.asOf))").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    private func footer(_ payload: DataPayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = payload.note, !note.isEmpty {
                DisclosureGroup("Source notes") {
                    Text(note).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                .font(.subheadline).padding(.horizontal, 4)
            }
            if let source = URL(string: payload.url) {
                Link(destination: source) {
                    HStack {
                        Label(payload.source, systemImage: "arrow.up.right").font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 52)
                    .contentShape(.rect(cornerRadius: 24))
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
                }
                .buttonStyle(.plain)
            }
            Text("Retrieved \(DataFormat.stamp(payload.asOf)). Reporting periods appear with each reading.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private func explanationCard(_ explanation: DataExplanation) -> some View {
        QuoteSection("What this tells you") {
            VStack(alignment: .leading, spacing: 12) {
                Text(explanation.meaning).font(.subheadline)
                Text(explanation.reading).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seriesOverview(_ series: SeriesPresentation) -> some View {
        QuoteSection(series.period(series.latest.x)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(series.value(series.latest.value)).font(.title.weight(.semibold)).monospacedDigit()
                Text(series.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let comparison = series.comparisonText {
                    Text(comparison).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(series.transform == "yoy" ? "Compared with the same period last year" : series.transform == "diff" ? "Change from the preceding reporting period" : "Reported level")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func seriesComparisons(_ series: SeriesPresentation) -> some View {
        QuoteSection("Compare readings") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(series.comparisons.enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).font(.subheadline.weight(.semibold))
                            Spacer(minLength: 12)
                            Text(series.value(row.value)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                        Text(series.period(row.date)).font(.caption).foregroundStyle(.secondary)
                        let difference = series.latest.value - row.value
                        Text(difference == 0 ? "Same as the latest reading" : "Latest is \(series.value(abs(difference), difference: true)) \(difference > 0 ? "higher" : "lower")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    if index < series.comparisons.count - 1 { Divider() }
                }
                if let low = visiblePoints.map(\.value).min(), let high = visiblePoints.map(\.value).max() {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Range shown in chart").font(.subheadline.weight(.semibold))
                        Text("\(series.value(low)) to \(series.value(high))").font(.subheadline).monospacedDigit()
                        if let first = visiblePoints.first { Text("\(series.period(first.x)) through \(series.period(series.latest.x))").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private func seriesHistory(_ series: SeriesPresentation) -> some View {
        QuoteSection("Historical readings") {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let historyError { Text(historyError).font(.caption).foregroundStyle(.secondary) }
                if let history {
                    Text("\(visiblePoints.count.formatted()) readings in this range. Full source history begins \(series.period(history.observations.first?.date ?? "")).")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Chart points are reduced for readability. The list keeps every available reading.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Loading full source history. The server chart may contain fewer points than the original series.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(visiblePoints.reversed().prefix(historyLimit)), id: \.x) { point in
                    HStack(alignment: .firstTextBaseline) {
                        Text(series.period(point.x)).font(.subheadline)
                        Spacer(minLength: 12)
                        Text(series.value(point.value)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    Divider()
                }
                if visiblePoints.count > historyLimit {
                    Button("Show \(min(100, visiblePoints.count - historyLimit)) older readings") { historyLimit += 100 }
                        .font(.subheadline.weight(.semibold)).padding(.vertical, 4)
                }
                if let history { Text("History retrieved \(history.fetched.formatted(date: .abbreviated, time: .shortened)) from FRED.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private func link(_ row: DataPayload.Row) -> some View {
        if let raw = row.destination, let destination = DataRoute(token: raw) {
            NavigationLink { DataScreen(route: destination) } label: { DataRowView(row: row, chevron: true) }.buttonStyle(.plain)
        } else if let id = row.ptrId, let year = row.ptrYear, let source = row.url.flatMap(URL.init(string:)) {
            NavigationLink { HousePTRDetailView(member: row.label, filed: row.date ?? "", filingID: id, year: year, source: source) }
                label: { DataRowView(row: row, chevron: true) }.buttonStyle(.plain)
        } else if let symbol = row.symbol {
            NavigationLink { QuoteDetail(symbol: symbol) } label: { DataRowView(row: row, chevron: true) }.buttonStyle(.plain)
        } else if let series = row.series, row.forecast == nil {
            NavigationLink { DataScreen(route: DataRoute("series/\(series)")).dockClearance() } label: { DataRowView(row: row, chevron: true) }.buttonStyle(.plain)
        } else if let story = row.story {
            Button {
                var components = URLComponents(string: "newswire://story/\(story)")
                components?.queryItems = row.url.map { [URLQueryItem(name: "url", value: $0)] }
                if let url = components?.url { openURL(url) }
            } label: { DataRowView(row: row, chevron: true) }.buttonStyle(.plain)
        } else if let link = row.url.flatMap(URL.init(string:)) {
            Button { openURL(link) } label: { DataRowView(row: row, chevron: true) }.buttonStyle(.plain)
        } else {
            DataRowView(row: row, chevron: false)
        }
    }
}

private struct DataRowView: View {
    let row: DataPayload.Row
    let chevron: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.forecast != nil || row.actual != nil ? MacroText.title(row.label).text : row.label)
                        .font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if let symbol = row.symbol, symbol != row.label, symbol != row.value, row.points == nil {
                        Text(symbol).font(.caption2.weight(.medium).monospaced()).foregroundStyle(.tertiary)
                    }
                }
                if row.change == nil, let label = row.changeLabel {
                    Text(readableChange(label)).font(.caption)
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if row.actual != nil { Text(MacroText.surprise(row)).font(.caption).foregroundStyle(.secondary) }
                if row.forecast != nil || row.previous != nil {
                    Text(MacroText.expectation(row)).font(.caption).foregroundStyle(.secondary)
                } else if let detail = row.detail, !detail.isEmpty, !detail.contains("collector snapshot") {
                    Text(detail.contains("of a 25 bp") || detail.contains("no change") ? MacroText.fedOdds(detail) : detail.replacingOccurrences(of: " · ", with: "\n"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let date = row.date {
                    Text("Reported for \(reportingPeriod(date))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            VStack(alignment: .trailing, spacing: 3) {
                if row.value == "Actual unavailable" {
                    Text("Released").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(displayValue).font(.subheadline.weight(.semibold)).monospacedDigit().multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }
                if let change = row.change {
                    ChangeBadge(percent: change)
                }
            }
            .frame(minWidth: 64, maxWidth: 150, alignment: .trailing)
            .layoutPriority(2)
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
          }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var displayValue: String {
        guard let value = SeriesPresentation.number(row.value) else { return row.value }
        if ["PAYEMS", "JTSJOL"].contains(row.series ?? ""), !row.value.contains("%") {
            return "\((value * 1000).formatted(.number.precision(.fractionLength(0)))) jobs"
        }
        if row.value.contains("$M") { return (value * 1_000_000).formatted(.currency(code: "USD").notation(.compactName).precision(.fractionLength(0...2))) }
        if row.value.hasSuffix("%") { return value.formatted(.number.precision(.fractionLength(0...2))) + "%" }
        return row.value
    }
    private func readableChange(_ text: String) -> String {
        guard row.series != nil, text.contains("vs prior"), let change = SeriesPresentation.number(text) else { return text }
        let amount: String
        if ["PAYEMS", "JTSJOL"].contains(row.series ?? ""), !row.value.contains("%") {
            amount = "\((abs(change) * 1000).formatted(.number.precision(.fractionLength(0)))) jobs"
        } else if row.value.contains("$M") {
            amount = (abs(change) * 1_000_000).formatted(.currency(code: "USD").notation(.compactName).precision(.fractionLength(0...2)))
        } else {
            amount = abs(change).formatted(.number.precision(.fractionLength(0...2))) + (row.value.contains("%") ? " percentage points" : "")
        }
        return change == 0 ? "Unchanged from prior reading" : "\(amount) \(change > 0 ? "higher" : "lower") than the prior reading"
    }
    private func reportingPeriod(_ text: String) -> String {
        if let series = row.series, SeriesPresentation.isMonthly(series), let date = DataFormat.date(text) {
            return date.formatted(.dateTime.month(.wide).year())
        }
        return DataFormat.day(text)
    }
}

struct ShipMap: View {
    let region: DataPayload.Region
    @State private var position: MapCameraPosition

    init(region: DataPayload.Region) {
        self.region = region
        let center = CLLocationCoordinate2D(latitude: region.center.first ?? 0, longitude: region.center.last ?? 0)
        _position = State(initialValue: .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: region.span, longitudeDelta: region.span))))
    }

    var body: some View {
        Map(position: $position) {
            ForEach(Array(region.pins.enumerated()), id: \.offset) { _, pin in
                Annotation(pin.label, coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon), anchor: .center) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ShipMap.tint(pin.kind))
                        .shadow(color: .black.opacity(0.35), radius: 1)
                        .rotationEffect(.degrees(pin.heading ?? 0))
                        .accessibilityLabel("\(pin.label), \(pin.detail ?? "")")
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
    }

    static func tint(_ kind: String?) -> Color {
        switch kind {
        case "Tanker": .orange
        case "Cargo": .green
        case "Passenger": .blue
        case "Military": .red
        case "Fishing": .yellow
        case "Tug", "Service": .purple
        default: .gray
        }
    }
}

private struct DataChart: View {
    let series: DataPayload.Series

    private var dated: [(Date, Double)]? {
        let parsed = series.points.compactMap { point in DataFormat.date(point.x).map { ($0, point.value) } }
        return parsed.count == series.points.count ? parsed : nil
    }

    var body: some View {
        let values = series.points.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let pad = max((high - low) * 0.1, 0.01)
        Group {
            if let dated {
                Chart {
                    ForEach(dated, id: \.0) { point in
                        LineMark(x: .value("Date", point.0), y: .value(series.label, point.1)).interpolationMethod(.monotone)
                    }
                    if low < 0 && high > 0 { RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.4)) }
                }
            } else {
                let step = max(1, Int((Double(series.points.count) / 8).rounded(.up)))
                let shown = series.points.enumerated().filter { $0.offset % step == 0 || $0.offset == series.points.count - 1 }.map(\.element.x)
                Chart(series.points, id: \.x) { point in
                    LineMark(x: .value("Tenor", point.x), y: .value(series.label, point.value)).interpolationMethod(.monotone)
                    PointMark(x: .value("Tenor", point.x), y: .value(series.label, point.value)).symbolSize(18)
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        if let label = value.as(String.self), shown.contains(label) { AxisValueLabel(label) }
                    }
                }
            }
        }
        .foregroundStyle(Color.wireAccent)
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartYAxis { AxisMarks(position: .trailing) }
        .chartYAxisLabel(series.unit ?? "")
        .accessibilityLabel("\(series.label) chart")
    }
}

nonisolated enum DataFormat {
    static func date(_ text: String) -> Date? {
        guard text.count == 10 else { return nil }
        return try? Date(text + "T12:00:00Z", strategy: .iso8601)
    }

    static func day(_ text: String) -> String {
        if let date = date(String(text.prefix(10))), text.count <= 10 { return date.formatted(.dateTime.month(.abbreviated).day().year()) }
        if let date = (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601)) {
            return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month(.abbreviated).day())
        }
        return text
    }

    static func stamp(_ text: String) -> String {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))?.formatted(date: .abbreviated, time: .shortened) ?? text
    }
}

@Observable final class TerminalFavorites {
    static let shared = TerminalFavorites()
    private let key = "favoriteTerminalFunctions"
    private(set) var codes: Set<String>

    private init() { codes = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    func contains(_ code: String) -> Bool { codes.contains(code) }

    func toggle(_ code: String) {
        if !codes.insert(code).inserted { codes.remove(code) }
        UserDefaults.standard.set(codes.sorted(), forKey: key)
    }
}

@Observable final class TerminalExploreVisibility {
    static let shared = TerminalExploreVisibility()
    var isVisible = false
}

struct TerminalExploreView: View {
    /// Sent through the dock's selection callback to open this screen in the main navigation stack.
    static let token = "explore:"
    let onSelect: (String) -> Void
    var onVisibilityChange: (Bool) -> Void = { _ in }
    @State private var favorites = TerminalFavorites.shared
    @State private var visibility = TerminalExploreVisibility.shared
    @State private var query = ""

    private let categories = ["Markets", "Rates", "Economy", "Institutions", "Shipping"]
    private var matches: [TerminalFunction] {
        TerminalFunction.all.filter { function in
            query.isEmpty || "\(function.title) \(function.code) \(function.category) \(function.summary)".localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            let starred = matches.filter { favorites.contains($0.code) }
            if !starred.isEmpty {
                Section("Favorites") { ForEach(starred) { row($0) } }
            }
            ForEach(categories, id: \.self) { category in
                let tools = matches.filter { $0.category == category }
                if !tools.isEmpty {
                    Section(category) { ForEach(tools) { row($0) } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if matches.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .animation(.easeOut(duration: 0.2), value: favorites.codes)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search data tools")
        .navigationTitle("Data Tools")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { visibility.isVisible = true; onVisibilityChange(true) }
        .onDisappear { visibility.isVisible = false; onVisibilityChange(false) }
    }

    private func row(_ function: TerminalFunction) -> some View {
        let starred = favorites.contains(function.code)
        return Button { onSelect(function.route.token) } label: {
            HStack(spacing: 12) {
                ToolIcon(symbol: function.symbol, tint: function.tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(function.title).font(.body).foregroundStyle(.primary)
                        Text(function.code).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                    Text(function.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button { favorites.toggle(function.code) } label: {
                Label(starred ? "Unfavorite" : "Favorite", systemImage: starred ? "star.slash" : "star.fill")
            }
            .tint(.yellow)
        }
        .contextMenu {
            Button { favorites.toggle(function.code) } label: {
                Label(starred ? "Remove from Favorites" : "Add to Favorites", systemImage: starred ? "star.slash" : "star")
            }
        }
        .accessibilityAction(named: starred ? "Remove from favorites" : "Add to favorites") { favorites.toggle(function.code) }
    }
}

struct TerminalFunctionsRow: View {
    let onSelect: (String) -> Void
    var codes: Set<String>? = nil
    var excluding: Set<String> = []

    private var functions: [TerminalFunction] {
        TerminalFunction.all.filter { (codes == nil || codes!.contains($0.code)) && !excluding.contains($0.code) }
    }

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(functions) { function in
                        Button { onSelect(function.route.token) } label: { TerminalCard(function: function) }
                            .buttonStyle(PressSpringStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

struct TerminalCard: View {
    let function: TerminalFunction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolIcon(symbol: function.symbol, tint: function.tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(function.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(function.code).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 124, alignment: .leading)
        .contentShape(.rect(cornerRadius: 18))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(function.title), \(function.code)")
    }
}

private struct DataSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    let prompt: String
    let submit: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
                .onSubmit(of: .search, submit)
        } else {
            content
        }
    }
}
