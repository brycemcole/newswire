import Charts
import SwiftUI

struct MarketSymbol: Hashable, Identifiable {
    let id: String
}

enum MarketRecents {
    static let popular = ["SPY", "QQQ", "ES=F", "NQ=F", "CL=F", "GC=F", "BTC-USD", "^VIX"]
    static var all: [String] { UserDefaults.standard.stringArray(forKey: "marketRecents") ?? [] }

    static func add(_ symbol: String) {
        UserDefaults.standard.set(Array(([symbol] + all.filter { $0 != symbol }).prefix(8)), forKey: "marketRecents")
    }

    static func remove(_ symbol: String) {
        UserDefaults.standard.set(all.filter { $0 != symbol }, forKey: "marketRecents")
    }
}

@Observable final class Watchlist {
    static let shared = Watchlist()
    private(set) var symbols: [String]

    private init() {
        symbols = UserDefaults.standard.stringArray(forKey: "watchlist") ?? MarketRecents.all
    }

    func contains(_ symbol: String) -> Bool { symbols.contains(symbol) }

    func toggle(_ symbol: String) {
        contains(symbol) ? remove(symbol) : save(symbols + [symbol])
    }

    func remove(_ symbol: String) { save(symbols.filter { $0 != symbol }) }

    private func save(_ next: [String]) {
        symbols = next
        UserDefaults.standard.set(next, forKey: "watchlist")
    }
}

@Observable final class QuoteModel {
    let symbol: String
    var range = ChartRange(rawValue: UserDefaults.standard.string(forKey: "marketRange") ?? "") ?? .day {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "marketRange") }
    }
    var live: MarketChart?
    var charts: [ChartRange: MarketChart] = [:]
    var summary: QuoteSummary?
    var error: String?

    init(symbol: String) { self.symbol = symbol }

    var chart: MarketChart? { range == .day ? live : charts[range] }

    func refreshLive() async {
        do {
            live = try await MarketClient.chart(symbol, range: .day)
            error = nil
        } catch is CancellationError {
        } catch {
            if live == nil { self.error = error.localizedDescription }
        }
    }

    func refreshRange() async {
        let range = range
        guard range != .day else { return }
        do {
            charts[range] = try await MarketClient.chart(symbol, range: range)
        } catch is CancellationError {
        } catch {
            if charts[range] == nil { self.error = error.localizedDescription }
        }
    }

    func refreshSummary() async {
        if let found = try? await MarketClient.summary(symbol) { summary = found }
    }
}

@Observable final class Scrub {
    var index: Int?
}

struct QuoteDetail: View {
    @State private var model: QuoteModel
    @State private var scrub = Scrub()
    @State private var holding: MarketSymbol?
    @State private var aboutExpanded = false
    @State private var watchlist = Watchlist.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var rangeNamespace

    init(symbol: String) {
        _model = State(initialValue: QuoteModel(symbol: symbol.uppercased()))
    }

    private var summary: QuoteSummary? { model.summary }
    private var symbol: String { model.symbol }
    private var dayMove: Double? {
        guard let live = model.live, let reference = live.previousClose, reference != 0 else { return nil }
        return live.price / reference - 1
    }
    private var name: String {
        summary?.text("price", "longName") ?? summary?.text("price", "shortName") ?? model.live?.name ?? symbol
    }
    private var yahooURL: URL {
        URL(string: "https://finance.yahoo.com/quote/\(symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol)")!
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    tagLine
                    if let chart = model.chart {
                        QuoteHeader(chart: chart, live: model.live, range: model.range, scrub: scrub)
                    }
                    if let byline {
                        Text(byline).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                hero
                rangePicker
                HoldingSection(symbol: symbol, chart: model.live)
                Divider()
                QuoteNewsSection(symbol: symbol, name: name, instrument: summary?.text("price", "quoteType") ?? model.live?.instrument,
                                 move: dayMove, price: model.live.map { $0.money($0.price) })
                sections
                Link(destination: yahooURL) {
                    Label("Data from Yahoo Finance", systemImage: "arrow.up.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDisabled(scrub.index != nil)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .animation(.easeOut(duration: 0.2), value: summary != nil)
        .navigationTitle(name)
        .navigationSubtitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $holding) { QuoteDetail(symbol: $0.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let watching = watchlist.contains(symbol)
                Button { watchlist.toggle(symbol) } label: {
                    Image(systemName: watching ? "star.fill" : "star")
                        .contentTransition(.symbolEffect(.replace))
                }
                .sensoryFeedback(.selection, trigger: watching)
                .accessibilityLabel(watching ? "Remove from watchlist" : "Add to watchlist")
            }
            ToolbarItem(placement: .topBarTrailing) { ShareLink(item: yahooURL) }
        }
        .onAppear { MarketRecents.add(symbol) }
        .task { await model.refreshSummary() }
        .task(id: phase == .active) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await model.refreshLive()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .task(id: "\(model.range.rawValue)|\(phase == .active)") {
            guard model.range != .day, phase == .active else { return }
            while !Task.isCancelled {
                await model.refreshRange()
                guard model.range == .week else { return }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private var hero: some View {
        Group {
            if let chart = model.chart {
                PriceChart(chart: chart, range: model.range, scrub: scrub)
                    .id(model.range)
                    .transition(.opacity)
            } else if let error = model.error {
                ContentUnavailableView(error, systemImage: "chart.line.downtrend.xyaxis")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 230)
        .padding(.top, 18)
        .animation(.easeOut(duration: 0.2), value: model.chart == nil)
    }

    private var rangePicker: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(ChartRange.allCases) { range in
                    let selected = model.range == range
                    Button {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.34, bounce: 0.2)) { model.range = range }
                    } label: {
                        Text(range.rawValue)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(selected ? Theme.shared.accent.onColor : .primary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background {
                                if selected {
                                    Capsule().fill(Color.wireAccent).matchedGeometryEffect(id: "range", in: rangeNamespace)
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(PressSpringStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
        }
        .sensoryFeedback(.selection, trigger: model.range)
    }

    private var tagLine: some View {
        let exchange = summary?.text("price", "exchangeName") ?? model.live?.exchange
        let kind: String? = switch summary?.text("price", "quoteType") ?? model.live?.instrument {
        case "EQUITY": "Stock"
        case "ETF": "ETF"
        case "FUTURE": "Future"
        case "CRYPTOCURRENCY": "Crypto"
        case "INDEX": "Index"
        case "CURRENCY": "Currency"
        case "MUTUALFUND": "Fund"
        case let other: other?.capitalized
        }
        return Text([exchange, kind, model.live?.currency].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ").uppercased())
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var byline: String? {
        guard let summary else { return nil }
        let parts = [summary.text("assetProfile", "sectorDisp") ?? summary.text("assetProfile", "sector"),
                     summary.text("assetProfile", "industryDisp") ?? summary.text("assetProfile", "industry"),
                     summary.text("defaultKeyStatistics", "category")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var sections: some View {
        let summary = summary
        let day = model.live
        let trading = stats([
            ("Open", summary?.text("summaryDetail", "open") ?? day?.open.map { day!.money($0) }),
            ("Prev close", summary?.text("summaryDetail", "previousClose") ?? day?.previousClose.map { day!.money($0) }),
            ("Day range", span(summary?.text("summaryDetail", "dayLow"), summary?.text("summaryDetail", "dayHigh"))
                ?? span(day?.dayLow.map { day!.money($0) }, day?.dayHigh.map { day!.money($0) })),
            ("Volume", summary?.text("summaryDetail", "volume") ?? day?.volume.map { $0.formatted(.number.notation(.compactName)) }),
            ("Avg volume", summary?.text("summaryDetail", "averageVolume")),
            ("Market cap", summary?.text("summaryDetail", "marketCap") ?? summary?.text("price", "marketCap")),
            ("Bid", quote("bid", "bidSize")),
            ("Ask", quote("ask", "askSize")),
            ("Beta", summary?.text("summaryDetail", "beta")),
            ("52W change", summary?.text("defaultKeyStatistics", "52WeekChange")),
            ("50-day avg", summary?.text("summaryDetail", "fiftyDayAverage")),
            ("200-day avg", summary?.text("summaryDetail", "twoHundredDayAverage")),
            ("Open interest", summary?.text("summaryDetail", "openInterest")),
            ("Expires", summary?.day("summaryDetail", "expireDate")),
            ("Circulating", summary?.text("summaryDetail", "circulatingSupply")),
            ("Max supply", summary?.text("summaryDetail", "maxSupply")),
            ("24h volume", summary?.text("summaryDetail", "volume24Hr")),
            ("All-time high", summary?.text("summaryDetail", "allTimeHigh")),
        ])
        let low = summary?.raw("summaryDetail", "fiftyTwoWeekLow") ?? day?.yearLow
        let high = summary?.raw("summaryDetail", "fiftyTwoWeekHigh") ?? day?.yearHigh
        QuoteSection("Trading") {
            if let low, let high, let price = day?.price, let day {
                RangeBar(title: "52-week range", low: low, high: high, value: price, format: day.money)
            }
            StatGrid(stats: trading)
        }
        if let summary {
            analysts(summary)
            earnings(summary)
            let valuation = stats([
                ("P/E (TTM)", summary.text("summaryDetail", "trailingPE")),
                ("Forward P/E", summary.text("summaryDetail", "forwardPE") ?? summary.text("defaultKeyStatistics", "forwardPE")),
                ("PEG ratio", summary.text("defaultKeyStatistics", "pegRatio")),
                ("Price/sales", summary.text("summaryDetail", "priceToSalesTrailing12Months")),
                ("Price/book", summary.text("defaultKeyStatistics", "priceToBook")),
                ("EPS (TTM)", summary.text("defaultKeyStatistics", "trailingEps")),
                ("Forward EPS", summary.text("defaultKeyStatistics", "forwardEps")),
                ("Book value", summary.text("defaultKeyStatistics", "bookValue")),
                ("Enterprise value", summary.text("defaultKeyStatistics", "enterpriseValue")),
                ("EV/revenue", summary.text("defaultKeyStatistics", "enterpriseToRevenue")),
                ("EV/EBITDA", summary.text("defaultKeyStatistics", "enterpriseToEbitda")),
            ])
            if !valuation.isEmpty { QuoteSection("Valuation") { StatGrid(stats: valuation) } }
            let financials = stats([
                ("Revenue (TTM)", summary.text("financialData", "totalRevenue")),
                ("Revenue growth", summary.text("financialData", "revenueGrowth")),
                ("Earnings growth", summary.text("financialData", "earningsGrowth")),
                ("Gross margin", summary.text("financialData", "grossMargins")),
                ("Operating margin", summary.text("financialData", "operatingMargins")),
                ("Profit margin", summary.text("financialData", "profitMargins")),
                ("EBITDA", summary.text("financialData", "ebitda")),
                ("Net income", summary.text("defaultKeyStatistics", "netIncomeToCommon")),
                ("Free cash flow", summary.text("financialData", "freeCashflow")),
                ("Operating cash", summary.text("financialData", "operatingCashflow")),
                ("Cash", summary.text("financialData", "totalCash")),
                ("Debt", summary.text("financialData", "totalDebt")),
                ("Debt/equity", summary.text("financialData", "debtToEquity")),
                ("Current ratio", summary.text("financialData", "currentRatio")),
                ("Return on equity", summary.text("financialData", "returnOnEquity")),
                ("Return on assets", summary.text("financialData", "returnOnAssets")),
            ])
            if !financials.isEmpty { QuoteSection("Financials") { StatGrid(stats: financials) } }
            fund(summary)
            let dividends = stats([
                ("Dividend", summary.text("summaryDetail", "dividendRate")),
                ("Yield", summary.text("summaryDetail", "dividendYield")),
                ("Ex-dividend", summary.day("summaryDetail", "exDividendDate")),
                ("Pay date", summary.day("calendarEvents", "dividendDate")),
                ("Payout ratio", summary.text("summaryDetail", "payoutRatio")),
                ("5Y avg yield", summary.text("summaryDetail", "fiveYearAvgDividendYield").map { $0 + "%" }),
                ("Last split", summary.text("defaultKeyStatistics", "lastSplitFactor").map { factor in
                    [factor, summary.day("defaultKeyStatistics", "lastSplitDate")].compactMap { $0 }.joined(separator: ", ")
                }),
            ])
            if summary.raw("summaryDetail", "dividendRate") != nil || summary.text("defaultKeyStatistics", "lastSplitFactor") != nil {
                QuoteSection("Dividends & splits") { StatGrid(stats: dividends) }
            }
            let ownership = stats([
                ("Shares out", summary.text("defaultKeyStatistics", "sharesOutstanding")),
                ("Float", summary.text("defaultKeyStatistics", "floatShares")),
                ("Insiders", summary.text("defaultKeyStatistics", "heldPercentInsiders")),
                ("Institutions", summary.text("defaultKeyStatistics", "heldPercentInstitutions")),
                ("Short % float", summary.text("defaultKeyStatistics", "shortPercentOfFloat")),
                ("Short ratio", summary.text("defaultKeyStatistics", "shortRatio")),
                ("Shares short", summary.text("defaultKeyStatistics", "sharesShort")),
                ("Short as of", summary.day("defaultKeyStatistics", "dateShortInterest")),
            ])
            if !ownership.isEmpty { QuoteSection("Ownership & short interest") { StatGrid(stats: ownership) } }
            about(summary)
        }
    }

    @ViewBuilder
    private func analysts(_ summary: QuoteSummary) -> some View {
        let key = summary.text("financialData", "recommendationKey")
        let trend = summary.value("recommendationTrend", "trend")?.array.first
        let low = summary.raw("financialData", "targetLowPrice")
        let high = summary.raw("financialData", "targetHighPrice")
        if key != nil && key != "none" || trend != nil {
            QuoteSection("Analysts") {
                if let key, key != "none" {
                    HStack(alignment: .firstTextBaseline) {
                        Text(key.replacingOccurrences(of: "_", with: " ").capitalized).font(.title2.weight(.bold))
                        if let mean = summary.text("financialData", "recommendationMean") {
                            Text("\(mean) / 5").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        if let count = summary.text("financialData", "numberOfAnalystOpinions") {
                            Text("\(count) analysts").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if let trend { RecommendationBar(trend: trend) }
                if let low, let high, let price = model.live?.price, let day = model.live {
                    RangeBar(title: "Price target", low: low, high: high, value: price, mark: summary.raw("financialData", "targetMeanPrice"), format: day.money)
                }
            }
        }
    }

    @ViewBuilder
    private func earnings(_ summary: QuoteSummary) -> some View {
        let calendar = summary.value("calendarEvents", "earnings")
        let next = calendar?["earningsDate"]?.array.first?.date
        let financials = Dictionary((summary.value("earnings", "financialsChart")?["quarterly"]?.array ?? []).compactMap { item in
            item["date"]?.text.map { ($0, item) }
        }, uniquingKeysWith: { first, _ in first })
        let quarters = (summary.value("earnings", "earningsChart")?["quarterly"]?.array ?? []).compactMap { item in
            EarningsQuarter(item, financials: item["date"]?.text.flatMap { financials[$0] })
        }
        let years = (summary.value("earnings", "financialsChart")?["yearly"]?.array ?? []).compactMap(FiscalYear.init)
        let currency = summary.text("earnings", "financialCurrency") ?? "USD"
        if next != nil || !quarters.isEmpty || !years.isEmpty {
            QuoteSection("Earnings") {
                let upcoming = stats([
                    ("Next report", next.map { date in
                        date.formatted(date: .abbreviated, time: .omitted) + (calendar?["isEarningsDateEstimate"].map { if case .bool(true) = $0 { " (est.)" } else { "" } } ?? "")
                    }),
                    ("EPS estimate", calendar?["earningsAverage"]?.text),
                    ("EPS range", span(calendar?["earningsLow"]?.text, calendar?["earningsHigh"]?.text)),
                    ("Revenue estimate", calendar?["revenueAverage"]?.text),
                ])
                if !upcoming.isEmpty { StatGrid(stats: upcoming) }
                if !quarters.isEmpty { EarningsChart(quarters: quarters, currency: currency) }
                if !years.isEmpty { AnnualChart(years: years, currency: currency) }
            }
        }
    }

    @ViewBuilder
    private func fund(_ summary: QuoteSummary) -> some View {
        let details = stats([
            ("Category", summary.text("fundProfile", "categoryName")),
            ("Family", summary.text("fundProfile", "family") ?? summary.text("defaultKeyStatistics", "fundFamily")),
            ("Net assets", summary.text("defaultKeyStatistics", "totalAssets") ?? summary.text("summaryDetail", "totalAssets")),
            ("Yield", summary.text("defaultKeyStatistics", "yield") ?? summary.text("summaryDetail", "yield")),
            ("Expense ratio", summary.value("fundProfile", "feesExpensesInvestment")?["annualReportExpenseRatio"]?.text
                ?? summary.text("defaultKeyStatistics", "annualReportExpenseRatio")),
            ("YTD return", summary.text("defaultKeyStatistics", "ytdReturn")),
            ("3Y avg return", summary.text("defaultKeyStatistics", "threeYearAverageReturn")),
            ("5Y avg return", summary.text("defaultKeyStatistics", "fiveYearAverageReturn")),
            ("Beta (3Y)", summary.text("defaultKeyStatistics", "beta3Year")),
            ("Inception", summary.day("defaultKeyStatistics", "fundInceptionDate")),
        ])
        let holdings = summary.value("topHoldings", "holdings")?.array ?? []
        if summary.value("fundProfile", "family") != nil || !holdings.isEmpty {
            QuoteSection("Fund") { StatGrid(stats: details) }
        }
        if !holdings.isEmpty {
            QuoteSection("Top holdings") {
                let allocation = stats([
                    ("Stocks", summary.text("topHoldings", "stockPosition")),
                    ("Bonds", summary.text("topHoldings", "bondPosition")),
                    ("Cash", summary.text("topHoldings", "cashPosition")),
                    ("Other", summary.text("topHoldings", "otherPosition")),
                ])
                let top = holdings.compactMap { item -> (String, String, Double)? in
                    guard let symbol = item["symbol"]?.text, let weight = item["holdingPercent"]?.raw else { return nil }
                    return (symbol, item["holdingName"]?.text ?? symbol, weight)
                }
                let largest = top.map(\.2).max() ?? 1
                VStack(spacing: 0) {
                    ForEach(top, id: \.0) { symbol, title, weight in
                        Button { holding = MarketSymbol(id: symbol) } label: {
                            HStack(spacing: 12) {
                                Text(symbol).font(.subheadline.weight(.semibold).monospaced()).frame(width: 64, alignment: .leading)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(title).font(.subheadline).lineLimit(1)
                                    Capsule().fill(Color.wireAccent.opacity(0.7))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .frame(height: 4)
                                        .scaleEffect(x: weight / largest, anchor: .leading)
                                }
                                Text(weight.formatted(.percent.precision(.fractionLength(2))))
                                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 48)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !allocation.isEmpty { StatGrid(stats: allocation) }
            }
        }
    }

    @ViewBuilder
    private func about(_ summary: QuoteSummary) -> some View {
        let text = summary.text("assetProfile", "longBusinessSummary") ?? summary.text("assetProfile", "description")
        let place = [summary.text("assetProfile", "city"), summary.text("assetProfile", "state"), summary.text("assetProfile", "country")]
            .compactMap { $0 }.joined(separator: ", ")
        let officers = summary.value("assetProfile", "companyOfficers")?.array ?? []
        let ceo = officers.first { $0["title"]?.text?.contains("CEO") == true }?["name"]?.text?
            .split(separator: " ").joined(separator: " ")
        let facts = stats([
            ("Sector", summary.text("assetProfile", "sectorDisp") ?? summary.text("assetProfile", "sector")),
            ("Industry", summary.text("assetProfile", "industryDisp") ?? summary.text("assetProfile", "industry")),
            ("Employees", summary.raw("assetProfile", "fullTimeEmployees").map { $0.formatted(.number) }),
            ("CEO", ceo),
            ("Headquarters", place.isEmpty ? nil : place),
        ])
        let website = summary.text("assetProfile", "website").flatMap(URL.init(string:))
        if text != nil || !facts.isEmpty {
            QuoteSection("About") {
                if let text {
                    Text(text)
                        .font(.subheadline)
                        .lineLimit(aboutExpanded ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { aboutExpanded.toggle() } }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(aboutExpanded ? "Collapses the description" : "Expands the description")
                }
                StatGrid(stats: facts)
                if let website {
                    Link(destination: website) {
                        Label(website.host() ?? website.absoluteString, systemImage: "safari").font(.subheadline.weight(.semibold))
                    }
                    .tint(Color.wireAccent)
                }
            }
        }
    }

    private func stats(_ list: [(String, String?)]) -> [(String, String)] {
        list.compactMap { label, value in value.map { (label, $0) } }
    }

    private func span(_ low: String?, _ high: String?) -> String? {
        guard let low, let high else { return nil }
        return "\(low) – \(high)"
    }

    private func quote(_ price: String, _ size: String) -> String? {
        guard let value = summary?.raw("summaryDetail", price), value > 0, let text = summary?.text("summaryDetail", price) else { return nil }
        guard let count = summary?.raw("summaryDetail", size), count > 0 else { return text }
        return "\(text) × \(Int(count))"
    }
}

struct QuoteSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

private struct StatGrid: View {
    let stats: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .topLeading), GridItem(.flexible(), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 14) {
            ForEach(stats, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(2).minimumScaleFactor(0.85)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct RangeBar: View {
    let title: String
    let low: Double
    let high: Double
    let value: Double
    var mark: Double?
    let format: (Double) -> String

    var body: some View {
        let spread = max(high - low, .ulpOfOne)
        let position = min(max((value - low) / spread, 0), 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let mark { Text("Avg \(format(mark))").font(.caption.weight(.semibold)).monospacedDigit() }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 4)
                    if let mark {
                        Capsule().fill(.secondary).frame(width: 2, height: 12)
                            .offset(x: min(max((mark - low) / spread, 0), 1) * (geometry.size.width - 2))
                    }
                    Circle().fill(Color.wireAccent).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .offset(x: position * (geometry.size.width - 12))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            HStack {
                Text(format(low))
                Spacer()
                Text(format(high))
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) from \(format(low)) to \(format(high)), currently \(format(value))")
    }
}

private struct RecommendationBar: View {
    let trend: YValue
    private let kinds: [(key: String, title: String, color: Color)] = [
        ("strongBuy", "Strong buy", .green), ("buy", "Buy", .mint), ("hold", "Hold", .gray), ("sell", "Sell", .orange), ("strongSell", "Strong sell", .red),
    ]

    var body: some View {
        let counts = kinds.map { Int(trend[$0.key]?.raw ?? 0) }
        let total = max(counts.reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(kinds.indices.filter { counts[$0] > 0 }, id: \.self) { index in
                        kinds[index].color.frame(width: max(geometry.size.width * Double(counts[index]) / Double(total) - 2, 2))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 10)
            FlowLayout(spacing: 10) {
                ForEach(kinds.indices.filter { counts[$0] > 0 }, id: \.self) { index in
                    HStack(spacing: 4) {
                        Circle().fill(kinds[index].color).frame(width: 7, height: 7)
                        Text("\(counts[index]) \(kinds[index].title)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EarningsQuarter: Identifiable {
    let id: String
    let actual: Double
    let estimate: Double?
    let surprise: String?
    let fiscalQuarter: String?
    let reported: Date?
    let revenue: Double?
    let earnings: Double?

    init?(_ value: YValue, financials: YValue?) {
        guard let label = value["date"]?.text, let actual = value["actual"]?.raw else { return nil }
        id = label
        self.actual = actual
        estimate = value["estimate"]?.raw
        surprise = value["surprisePct"]?.text
        fiscalQuarter = value["fiscalQuarter"]?.text
        reported = value["reportedDate"]?.date
        revenue = financials?["revenue"]?.raw
        earnings = financials?["earnings"]?.raw
    }
}

private struct FiscalYear: Identifiable {
    let id: String
    let revenue: Double
    let earnings: Double

    init?(_ value: YValue) {
        guard let year = value["date"]?.raw, let revenue = value["revenue"]?.raw, let earnings = value["earnings"]?.raw else { return nil }
        id = String(Int(year))
        self.revenue = revenue
        self.earnings = earnings
    }
}

private struct EarningsChart: View {
    let quarters: [EarningsQuarter]
    let currency: String
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EPS actual vs estimate").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(quarters) { quarter in
                    let dim = selected != nil && selected != quarter.id
                    if let estimate = quarter.estimate {
                        PointMark(x: .value("Quarter", quarter.id), y: .value("EPS", estimate))
                            .symbol(.circle)
                            .symbolSize(110)
                            .foregroundStyle(.gray.opacity(dim ? 0.15 : 0.35))
                    }
                    PointMark(x: .value("Quarter", quarter.id), y: .value("EPS", quarter.actual))
                        .symbolSize(110)
                        .foregroundStyle(quarter.actual >= (quarter.estimate ?? quarter.actual) ? Color.green : Color.red)
                        .opacity(dim ? 0.3 : 1)
                        .annotation(position: .top, spacing: 4) {
                            if let surprise = quarter.surprise, let value = Double(surprise) {
                                Text((value >= 0 ? "+" : "") + surprise + "%").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                }
            }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .chartOverlay { proxy in
                CategoryScrub(proxy: proxy, ids: quarters.map(\.id), selection: $selected) { id in
                    if let quarter = quarters.first(where: { $0.id == id }) { readout(quarter) }
                }
            }
            .frame(height: 140)
            HStack(spacing: 12) {
                Label { Text("Actual") } icon: { Circle().fill(.green).frame(width: 7, height: 7) }
                Label { Text("Estimate") } icon: { Circle().fill(.gray.opacity(0.35)).frame(width: 7, height: 7) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func readout(_ quarter: EarningsQuarter) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(quarter.fiscalQuarter.map { "FY " + $0 } ?? quarter.id).fontWeight(.semibold)
                if let reported = quarter.reported {
                    Text("Reported " + reported.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!)))
                        .foregroundStyle(.secondary)
                }
            }
            ReadoutRow(label: "EPS actual", value: eps(quarter.actual))
            if let estimate = quarter.estimate {
                ReadoutRow(label: "EPS estimate", value: eps(estimate))
                let difference = quarter.actual - estimate
                ReadoutRow(label: difference >= 0 ? "Beat" : "Missed",
                           value: eps(abs(difference)) + (quarter.surprise.map { " (\($0)%)" } ?? ""),
                           tint: difference >= 0 ? .green : .red)
            }
            if let revenue = quarter.revenue {
                ReadoutRow(label: "Revenue", value: compact(revenue, currency: currency))
            }
            if let earnings = quarter.earnings {
                ReadoutRow(label: "Net income", value: compact(earnings, currency: currency))
                if let revenue = quarter.revenue, revenue != 0 {
                    ReadoutRow(label: "Margin", value: (earnings / revenue).formatted(.percent.precision(.fractionLength(1))))
                }
            }
        }
    }

    private func eps(_ value: Double) -> String {
        value.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }
}

private struct AnnualChart: View {
    let years: [FiscalYear]
    let currency: String
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Annual revenue & earnings").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(years) { year in
                    let opacity = selected == nil || selected == year.id ? 1.0 : 0.3
                    BarMark(x: .value("Year", year.id), y: .value("Amount", year.revenue))
                        .foregroundStyle(by: .value("Metric", "Revenue"))
                        .position(by: .value("Metric", "Revenue"))
                        .opacity(opacity)
                    BarMark(x: .value("Year", year.id), y: .value("Amount", year.earnings))
                        .foregroundStyle(by: .value("Metric", "Earnings"))
                        .position(by: .value("Metric", "Earnings"))
                        .opacity(opacity)
                }
            }
            .chartForegroundStyleScale(["Revenue": Color.wireAccent, "Earnings": Color.green])
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(amount.formatted(.number.notation(.compactName))) } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .chartOverlay { proxy in
                CategoryScrub(proxy: proxy, ids: years.map(\.id), selection: $selected) { id in
                    if let year = years.first(where: { $0.id == id }) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("FY " + year.id).fontWeight(.semibold)
                            ReadoutRow(label: "Revenue", value: compact(year.revenue, currency: currency), tint: .wireAccent)
                            ReadoutRow(label: "Earnings", value: compact(year.earnings, currency: currency), tint: .green)
                            if year.revenue != 0 {
                                ReadoutRow(label: "Margin", value: (year.earnings / year.revenue).formatted(.percent.precision(.fractionLength(1))))
                            }
                        }
                    }
                }
            }
            .frame(height: 170)
        }
    }
}

private func compact(_ value: Double, currency: String) -> String {
    value.formatted(.currency(code: currency).notation(.compactName).precision(.fractionLength(2)))
}

private struct ReadoutRow: View {
    let label: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).fontWeight(.semibold).foregroundStyle(tint ?? .primary)
        }
    }
}

private struct CategoryScrub<Readout: View>: View {
    let proxy: ChartProxy
    let ids: [String]
    @Binding var selection: String?
    @ViewBuilder let readout: (String) -> Readout
    @State private var size = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] } ?? geometry.frame(in: .local)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(.rect)
                if let selection, let x = proxy.position(forX: selection) {
                    Rectangle()
                        .fill(.secondary.opacity(0.5))
                        .frame(width: 1, height: plot.height)
                        .position(x: plot.minX + x, y: plot.midY)
                    readout(selection)
                        .font(.caption)
                        .monospacedDigit()
                        .frame(minWidth: 170)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                        .position(
                            x: min(max(plot.minX + x, size.width / 2), geometry.size.width - size.width / 2),
                            y: plot.minY - size.height / 2 - 6
                        )
                        .allowsHitTesting(false)
                }
            }
            .gesture(ScrubGesture { location in update(location?.x, plot: plot) })
        }
        .sensoryFeedback(.selection, trigger: selection) { _, new in new != nil }
    }

    private func update(_ location: CGFloat?, plot: CGRect) {
        guard let location, !ids.isEmpty else {
            selection = nil
            return
        }
        let x = min(max(location - plot.minX, 0), plot.width)
        let nearest = ids.min { lhs, rhs in
            abs((proxy.position(forX: lhs) ?? .infinity) - x) < abs((proxy.position(forX: rhs) ?? .infinity) - x)
        }
        if selection != nearest { selection = nearest }
    }
}

extension MarketChart {
    func money(_ value: Double) -> String {
        value.formatted(.currency(code: currency).precision(.fractionLength(decimals)))
    }

    func reference(for range: ChartRange) -> Double? {
        guard range == .day else { return points.first?.close }
        return awaitingOpen ? price : previousClose ?? points.first?.close
    }
}

private struct QuoteHeader: View {
    let chart: MarketChart
    let live: MarketChart?
    let range: ChartRange
    let scrub: Scrub

    var body: some View {
        let point = scrub.index.flatMap { chart.points.indices.contains($0) ? chart.points[$0] : nil }
        let current = live?.price ?? chart.price
        let extended = point == nil ? live?.extendedQuote : nil
        let price = point?.close ?? extended?.price ?? current
        let prior = point == nil && range == .day && chart.awaitingOpen
        let reference = prior ? chart.previousClose : chart.reference(for: range)
        VStack(alignment: .leading, spacing: 4) {
            Text(chart.money(price))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: price))
                .animation(point == nil ? .smooth(duration: 0.3) : nil, value: price)
            if let reference {
                let value = point?.close ?? current
                change(value - reference, reference, label: point.map { stamp($0.date) } ?? (prior ? "Prior close" : range.caption))
            }
            if let extended {
                change(extended.price - current, current, label: extended.label)
            }
            if extended == nil {
                Text(point == nil ? (live ?? chart).status : (point!.extended ? "Extended hours" : "Regular session"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func change(_ delta: Double, _ base: Double, label: String) -> some View {
        let percent = base == 0 ? 0 : delta / base
        return HStack(spacing: 6) {
            Text((delta >= 0 ? "+" : "") + delta.formatted(.number.precision(.fractionLength(chart.decimals))))
            Text("(" + percent.formatted(.percent.precision(.fractionLength(2)).sign(strategy: .always())) + ")")
            Text(label).foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(delta >= 0 ? Color.green : Color.red)
        .lineLimit(1)
    }

    private func stamp(_ date: Date) -> String {
        date.formatted(range.stampStyle(chart.timeZone))
    }
}

private extension ChartRange {
    func stampStyle(_ zone: TimeZone) -> Date.FormatStyle {
        switch self {
        case .day: Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
        case .week, .month: Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone)
        default: Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: zone)
        }
    }
}

private struct PriceChart: View {
    let chart: MarketChart
    let range: ChartRange
    let scrub: Scrub

    var body: some View {
        let points = chart.points
        let reference = chart.reference(for: range)
        let up = (points.last?.close ?? 0) >= (reference ?? points.first?.close ?? 0)
        let tint = up ? Color.green : Color.red
        let closes = points.map(\.close) + (range == .day ? [reference].compactMap { $0 } : [])
        let low = closes.min() ?? 0, high = closes.max() ?? 1
        let pad = max((high - low) * 0.08, high * 0.0005)
        let floor = low - pad
        let split = range.query.prePost && points.contains(where: \.extended)
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.id), yStart: .value("Floor", floor), yEnd: .value("Price", point.close))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
            }
            ForEach(points) { point in
                LineMark(x: .value("Time", point.id), y: .value("Price", point.close), series: .value("Session", "all"))
                    .foregroundStyle(tint.opacity(split ? 0.4 : 1))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if split {
                ForEach(points.filter { !$0.extended }) { point in
                    LineMark(x: .value("Time", point.id), y: .value("Price", point.close), series: .value("Session", "regular\(point.run)"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            if range == .day, let reference {
                RuleMark(y: .value("Previous close", reference))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
        .chartXScale(domain: 0...(max(chart.slots, points.count) - 1))
        .chartYScale(domain: floor...(high + pad))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            ScrubOverlay(proxy: proxy, chart: chart, range: range, tint: tint, scrub: scrub)
        }
        .accessibilityLabel("\(chart.symbol) price chart, \(range.caption)")
    }
}

private struct ScrubGesture: UIGestureRecognizerRepresentable {
    let changed: (CGPoint?) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.18
        recognizer.allowableMovement = 12
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: changed(context.converter.localLocation)
        default: changed(nil)
        }
    }
}

private struct ScrubOverlay: View {
    let proxy: ChartProxy
    let chart: MarketChart
    let range: ChartRange
    let tint: Color
    let scrub: Scrub

    var body: some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] } ?? geometry.frame(in: .local)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(.rect)
                if let index = scrub.index, chart.points.indices.contains(index),
                   let x = proxy.position(forX: index), let y = proxy.position(forY: chart.points[index].close) {
                    let point = chart.points[index]
                    Rectangle()
                        .fill(.secondary.opacity(0.6))
                        .frame(width: 1, height: plot.height)
                        .position(x: plot.minX + x, y: plot.midY)
                    Circle()
                        .fill(tint)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .position(x: plot.minX + x, y: plot.minY + y)
                    Text(chart.money(point.close) + "  " + point.date.formatted(range.stampStyle(chart.timeZone)))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        .position(x: min(max(plot.minX + x, plot.minX + 80), plot.maxX - 80), y: plot.minY - 6)
                }
            }
            .gesture(ScrubGesture { location in update(location?.x, plot: plot) })
        }
        .sensoryFeedback(.impact(weight: .light), trigger: scrub.index != nil) { _, active in active }
    }

    private func update(_ location: CGFloat?, plot: CGRect) {
        guard let location, !chart.points.isEmpty else {
            scrub.index = nil
            return
        }
        let raw = proxy.value(atX: location - plot.minX, as: Int.self) ?? 0
        let index = min(max(raw, 0), chart.points.count - 1)
        if scrub.index != index { scrub.index = index }
    }
}
