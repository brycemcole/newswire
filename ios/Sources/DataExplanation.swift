import Foundation

nonisolated struct DataExplanation {
    let meaning: String
    let reading: String
    let methodology: String?

    init(meaning: String, reading: String, methodology: String? = nil) {
        self.meaning = meaning
        self.reading = reading
        self.methodology = methodology
    }

    static func page(_ route: DataRoute) -> Self? {
        switch route.path {
        case "macro": Self(meaning: "A snapshot of employment, prices, growth and borrowing costs. Each figure covers its own reporting period; these are not all today's readings.", reading: "Year-over-year compares with the same period last year. Rate changes use percentage points. Tap an indicator for its history and definition.")
        case "calendar": Self(meaning: "Scheduled economic reports and central-bank events that markets are watching.", reading: "Expected is the published consensus forecast; previous is the last report. Times are US Eastern. A missing actual means the result has not been matched, not that the event did not happen.")
        case "releases", "economic/history", "economic_history", "calendar/history": Self(meaning: "Recently released economic reports, compared with what economists expected.", reading: "Above or below expected describes the numerical surprise, not whether the result is good or bad. Forecasts and actuals must refer to the same period and units.")
        case "fed/odds": Self(meaning: "What fed-funds futures imply about interest rates at upcoming Fed meetings.", reading: "A quarter-point move is 0.25 percentage points, or 25 basis points. These are simplified market estimates that change with prices, not a Fed promise.")
        case let path where path.hasPrefix("yield") || path.hasPrefix("curve"):
            Self(meaning: "The interest rates governments pay to borrow for different lengths of time.", reading: "Each point is a bond maturity. A curve that slopes down means shorter-term debt yields more than longer-term debt. Yields and bond prices generally move in opposite directions.")
        case "board/world": Self(meaning: "Major stock-market indices across countries. An index tracks a basket of stocks, rather than a single company.", reading: "The percentage compares with that market's previous close. Exchanges close at different times, so rows may cover different trading sessions.")
        case "board/rates": Self(meaning: "Market measures of interest rates and borrowing conditions.", reading: "Read each instrument's units: a yield is a rate, while a futures quote is a price. A price change is not necessarily the same as a change in yield.")
        case "board/fx": Self(meaning: "The value of one currency in another currency.", reading: "USD/JPY is the number of yen per US dollar. A higher USD/JPY means a stronger dollar relative to the yen; reversing a pair reverses that interpretation.")
        case "board/commodities": Self(meaning: "Prices of energy, metals and agricultural commodities, usually through futures contracts.", reading: "Each commodity has its own currency and contract unit. The daily change compares with the prior close; futures prices can differ from spot prices.")
        case "screener": Self(meaning: "Companies that match your selected region, industry and financial filters.", reading: "P/E compares price with earnings; dividend yield compares annual dividends with price. A low ratio alone does not establish that a stock is cheap.")
        case "sec/filings": Self(meaning: "Documents the company filed with the US Securities and Exchange Commission.", reading: "10-K is the annual report, 10-Q is the quarterly report, and 8-K reports a significant event. Tap a filing to read what the company disclosed.")
        case "sec/insiders": Self(meaning: "Reported share transactions by company executives, directors and other insiders.", reading: "An open-market purchase or sale differs from a grant, option exercise or shares withheld for taxes. A reported sale does not, by itself, explain the seller's outlook.")
        case "sec/holders": Self(meaning: "Reported ownership by major investors and institutions.", reading: "These are filing snapshots that can lag current holdings. Ownership percentages and portfolio weights answer different questions.")
        case "sec/institutions": Self(meaning: "A manager’s SEC Form 13F holdings compared with its previous quarterly report.", reading: "Position changes compare reported share counts. This is a delayed quarterly snapshot, not current trading.", methodology: "New, increased, reduced and exited positions reflect quarter-over-quarter share counts. Reported values are the SEC filing’s dollar values; total value also changes with market prices. 13F filings can arrive up to 45 days after quarter end, so they do not show what the manager is buying today. A reported increase can also reflect transfers or reporting changes.")
        case "finviz/institutional-flow": Self(meaning: "Finviz screens stocks by the change in total institutional ownership.", reading: "The percentage combines reported institutional ownership and does not name the firms or date their trades. Use INST with a manager name to compare that manager’s quarterly Form 13F holdings.")
        case "contracts": Self(meaning: "Reported federal contract awards or spending obligations matching the company name.", reading: "An obligation is money the government commits, not necessarily money already paid or company revenue. Name matching can include subsidiaries or similarly named companies.")
        case "chokepoints": Self(meaning: "How many vessels are passing through major shipping routes each day.", reading: "The percentage compares the last seven days with the preceding 30-day average. Fewer ships can signal a traffic disruption, but this data alone does not establish its cause.")
        case "ships": Self(meaning: "Recent vessel positions reported by the maritime AIS tracking system.", reading: "Positions are observations, not a complete live count. Coverage varies, and a vessel can disappear from the map because its signal is missing.")
        case "world": Self(meaning: "Economic indicators by country from the IMF's World Economic Outlook.", reading: "Check the year and units before comparing countries. Current and next-year values can be estimates or forecasts, rather than final reported figures.")
        case "wire/search", "sources/search": Self(meaning: "Reporting related to your search, with links to the original publisher.", reading: "Headlines and excerpts help find coverage. Open the source for its evidence, reporting date and full context.")
        case "series/search": Self(meaning: "Economic data series matching your search.", reading: "Similar names can represent different frequencies, units or adjustments. Open a result to check what it measures before comparing values.")
        default: nil
        }
    }

    static func series(_ id: String) -> Self? {
        switch id {
        case "PAYEMS": Self(meaning: "US payroll employment excludes farm workers and the self-employed. This view normally shows the change in jobs from one month to the next.", reading: "Above zero means employers added jobs; below zero means they shed jobs. A smaller positive number means hiring slowed, not that employment fell. Earlier estimates can be revised.")
        case "UNRATE": Self(meaning: "The share of the US labor force who are unemployed and actively looking for work.", reading: "A rise means a larger share of people in the labor force are unemployed. It does not count everyone without a job. A move from 4.1% to 4.2% is 0.1 percentage points.")
        case "ICSA", "CCSA": Self(meaning: id == "ICSA" ? "The number of people filing a new claim for unemployment benefits each week." : "The number of people continuing to receive unemployment benefits.", reading: "Higher claims indicate more people seeking benefits. Weekly readings can be volatile and may be revised.")
        case "JTSJOL": Self(meaning: "The number of unfilled jobs employers report in the US Job Openings and Labor Turnover Survey.", reading: "More openings indicate stronger demand for workers; openings are not the same as new hires.")
        case "CES0500000003": Self(meaning: "Average hourly pay for private-sector employees. The default view shows growth compared with a year earlier.", reading: "Faster wage growth raises nominal pay. To assess purchasing power, compare wage growth with inflation.")
        case "CPIAUCSL", "CPIAUCNS", "CPILFESL", "CPILFENS", "PCEPILFE": Self(meaning: "An index tracking consumer prices. Core measures exclude food and energy; CPI and PCE use different spending baskets.", reading: "Year-over-year is price growth over 12 months, not the price level. Slower positive inflation means prices are rising more slowly, not falling.")
        case "GDPC1", "GDP", "A191RL1Q225SBEA": Self(meaning: "Gross domestic product measures the value of goods and services produced. Real GDP removes the effect of price changes.", reading: "Check whether this view shows the level, year-over-year growth or annualized quarterly growth. They describe different comparisons.")
        case "RSAFS", "PCE": Self(meaning: "Spending by consumers, reported in dollars before adjusting for inflation.", reading: "A rise can reflect higher prices as well as more purchases. Year-over-year compares with the same month last year.")
        case "INDPRO": Self(meaning: "An index of output from factories, mines and utilities.", reading: "Growth indicates more industrial output; it does not measure the whole economy. An index level is relative to a base period, not a dollar amount.")
        case "UMCSENT": Self(meaning: "The University of Michigan survey of how consumers feel about the economy and their finances.", reading: "Higher index readings indicate stronger confidence. Sentiment is a survey measure, not a direct measure of spending.")
        case "DFEDTARU", "DFEDTARL", "EFFR", "SOFR": Self(meaning: "An overnight US interest rate. The Fed target is a range; effective fed funds and SOFR measure rates on actual transactions.", reading: "Higher rates mean more expensive short-term borrowing. Changes between rates are measured in percentage points or basis points, not percent growth.")
        case "WALCL", "M2SL": Self(meaning: id == "WALCL" ? "Total assets held by the Federal Reserve." : "A broad measure of money, including cash and several kinds of bank deposits.", reading: "Check whether the chart shows dollars or growth. A change in this measure alone does not establish what inflation or asset prices will do.")
        case "T10Y2Y", "T10Y3M": Self(meaning: "The 10-year Treasury yield minus a shorter-term Treasury yield.", reading: "Below zero means the yield curve is inverted: shorter-term borrowing yields more than the 10-year bond. The difference is measured in percentage points.")
        case let code where code.hasPrefix("DGS") || code.hasPrefix("IRLTLT") || code == "MORTGAGE30US":
            Self(meaning: code == "MORTGAGE30US" ? "The average quoted interest rate on a 30-year fixed-rate US mortgage." : "The interest rate on government debt at the stated maturity.", reading: "A higher yield means a higher borrowing rate. Bond yields generally rise when bond prices fall. One basis point is 0.01 percentage points.")
        case let code where code.hasPrefix("BAML"):
            Self(meaning: "The extra yield investors demand on corporate bonds above comparable Treasuries, adjusted for embedded options.", reading: "A wider spread means a larger risk premium. High-yield and lower-rated borrowers generally pay more; a spread of 3% equals 300 basis points.")
        case "T5YIE": Self(meaning: "The difference between nominal and inflation-protected five-year Treasury yields.", reading: "This is a market-based inflation compensation measure. It includes risk and liquidity effects, so it is not a pure inflation forecast.")
        case "WPU101", "PPIACO", "PPIFIS": Self(meaning: "An index of prices received by producers, for the industry or basket shown.", reading: "This measures producer prices rather than household prices. Year-over-year compares with the same month last year.")
        case "HOUST", "PERMIT": Self(meaning: "Housing construction activity: starts count projects begun, while permits count authorized construction.", reading: "Reported annual rates scale a month's pace to a year. Permits are not a guarantee that the homes will be built.")
        case "VIXCLS": Self(meaning: "The options market's measure of expected S&P 500 volatility over roughly the next 30 days.", reading: "Higher readings mean larger expected swings, not a prediction that stocks will fall.")
        case "NFCI", "STLFSI4": Self(meaning: "An index combining indicators of financial conditions or financial stress.", reading: "Read the source's baseline and methodology. Index points are not percentages, and one reading does not explain what caused conditions to change.")
        default: nil
        }
    }
}

nonisolated struct SeriesPresentation {
    let id: String
    let payload: DataPayload
    let transform: String
    let latest: DataPayload.Point
    let unit: String
    let observations: [DataPayload.Point]?

    init?(route: DataRoute, payload: DataPayload, observations: [DataPayload.Point]? = nil) {
        guard route.path.hasPrefix("series/"), route.path != "series/search", let chart = payload.chart, let latest = observations?.last ?? chart.points.last else { return nil }
        id = String(route.path.dropFirst(7))
        self.payload = payload
        self.latest = latest
        self.observations = observations
        transform = payload.note?.contains("Transform: yoy") == true ? "yoy" : payload.note?.contains("Transform: diff") == true ? "diff" : "level"
        unit = transform == "yoy" ? "%" : chart.unit ?? ""
    }

    var title: String {
        if id == "PAYEMS", transform == "diff" { return "US jobs added or lost" }
        return payload.title.replacingOccurrences(of: " (\(id))", with: "")
    }
    var explanation: DataExplanation {
        DataExplanation.series(id) ?? DataExplanation(meaning: "This is \(title), reported by \(payload.source).", reading: "Check the units and reporting period before comparing values. The chart shows \(transform == "yoy" ? "growth from a year earlier" : transform == "diff" ? "change from the preceding observation" : "reported levels").")
    }
    var chartLabel: String { id == "PAYEMS" && transform == "diff" ? "Monthly jobs added or lost" : transform == "yoy" ? "Growth from a year earlier" : transform == "diff" ? "Change from prior reading" : title }
    var unitLabel: String {
        if id == "PAYEMS" || id == "JTSJOL", transform != "yoy" { return "Thousands of jobs" }
        if unit == "%" || unit.contains("%") { return transform == "yoy" ? "Percent change over 12 months" : "Percent" }
        if unit == "pp" { return "Percentage points" }
        if unit == "$M" { return "Millions of US dollars" }
        return unit.isEmpty ? "Reported units" : unit
    }
    var monthly: Bool {
        Self.isMonthly(id)
    }
    static func isMonthly(_ id: String) -> Bool {
        ["PAYEMS", "UNRATE", "JTSJOL", "CES0500000003", "CPIAUCSL", "CPIAUCNS", "CPILFESL", "CPILFENS", "PCEPILFE", "RSAFS", "PCE", "INDPRO", "UMCSENT", "M2SL", "WPU101", "PPIACO", "HOUST", "PERMIT"].contains(id) || id.hasPrefix("IRLTLT")
    }
    func period(_ text: String) -> String {
        guard let date = DataFormat.date(text) else { return DataFormat.day(text) }
        if ["GDP", "GDPC1", "A191RL1Q225SBEA"].contains(id) {
            let calendar = Calendar(identifier: .gregorian)
            return "Q\((calendar.component(.month, from: date) - 1) / 3 + 1) \(calendar.component(.year, from: date))"
        }
        return date.formatted(monthly ? .dateTime.month(.wide).year() : .dateTime.month(.abbreviated).day().year())
    }
    func value(_ number: Double, difference: Bool = false) -> String {
        if id == "PAYEMS" || id == "JTSJOL", transform != "yoy" {
            return "\((number * 1000).formatted(.number.precision(.fractionLength(0)))) jobs"
        }
        if unit.contains("%") || unit == "pp" {
            let places = id == "UNRATE" || transform == "yoy" ? 1 : 2
            return number.formatted(.number.precision(.fractionLength(places))) + (difference ? " pp" : unit == "pp" ? " pp" : "%")
        }
        if unit == "$M" { return (number * 1_000_000).formatted(.currency(code: "USD").notation(.compactName).precision(.fractionLength(0...2))) }
        let formatted = number.formatted(.number.precision(.fractionLength(0...2)))
        return formatted + (unit.isEmpty ? "" : " \(unit)")
    }
    var headline: String {
        if id == "PAYEMS", transform == "diff" {
            return latest.value == 0 ? "Payroll employment was unchanged in \(period(latest.x))." : "Employers \(latest.value > 0 ? "added" : "shed") \(value(abs(latest.value))) in \(period(latest.x))."
        }
        if transform == "yoy" { return "\(title) \(latest.value >= 0 ? "rose" : "fell") \(value(abs(latest.value))) from a year earlier." }
        return "\(title) was \(value(latest.value)) in the latest reading."
    }
    var comparisons: [(label: String, value: Double, date: String)] {
        if let observations, let date = DataFormat.date(latest.x) {
            var result: [(String, Double, String)] = []
            if observations.count > 1 {
                let previous = observations[observations.count - 2]
                result.append(("Previous reading", previous.value, previous.x))
            }
            if let target = Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: date) {
                let key = target.formatted(.iso8601.year().month().day().dateSeparator(.dash))
                if let prior = observations.last(where: { $0.x <= key }), prior.x != result.first?.2 {
                    result.append(("One year earlier", prior.value, prior.x))
                }
            }
            return result
        }
        var dates: Set<String> = [latest.x]
        return payload.sections.flatMap(\.rows).compactMap { row in
            guard let date = row.date, dates.insert(date).inserted, let number = Self.number(row.value) else { return nil }
            return (row.label == "Prior observation" ? "Previous reading" : row.label, number, date)
        }
    }
    var comparisonText: String? {
        guard let prior = comparisons.first else { return nil }
        let delta = latest.value - prior.value
        if id == "PAYEMS", transform == "diff" {
            return "\(value(abs(prior.value))) were \(prior.value >= 0 ? "added" : "lost") in \(period(prior.date)). \(delta == 0 ? "The monthly change was the same." : "That is \(value(abs(delta))) \(delta < 0 ? "fewer" : "more") than the previous month.")"
        }
        return "\(delta == 0 ? "Unchanged" : "\(value(abs(delta), difference: true)) \(delta > 0 ? "higher" : "lower")") than \(value(prior.value)) in \(period(prior.date))."
    }
    static func number(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "−", with: "-")
        guard let match = normalized.firstMatch(of: /^[-+]?\d+(?:\.\d+)?/) else { return nil }
        return Double(match.0)
    }
}
