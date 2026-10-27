import SwiftUI

nonisolated struct ReportedEarnings: Identifiable, Sendable {
    let end: String
    let annual: Bool
    let currency: String
    var revenue: Double?
    var netIncome: Double?
    var dilutedEPS: Double?
    var id: String { "\(annual)-\(end)-\(currency)" }

    static let metrics = ["TotalRevenue", "NetIncome", "DilutedEPS"]
    static let types = ["quarterly", "annual"].flatMap { period in metrics.map { period + $0 } }

    static func parse(_ root: YValue, now: Date = .now) -> [Self] {
        var rows: [String: Self] = [:]
        let today = now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        for series in root["timeseries"]?["result"]?.array ?? [] {
            guard let type = series["meta"]?["type"]?.array.first?.text, types.contains(type) else { continue }
            let annual = type.hasPrefix("annual")
            for item in series[type]?.array ?? [] {
                guard let end = item["asOfDate"]?.text, end <= today,
                      item["periodType"]?.text == (annual ? "12M" : "3M"),
                      let currency = item["currencyCode"]?.text,
                      let value = item["reportedValue"]?.raw, value.isFinite else { continue }
                let key = "\(annual)-\(end)-\(currency)"
                var row = rows[key] ?? Self(end: end, annual: annual, currency: currency)
                if type.hasSuffix("TotalRevenue") { row.revenue = value }
                if type.hasSuffix("NetIncome") { row.netIncome = value }
                if type.hasSuffix("DilutedEPS") { row.dilutedEPS = value }
                rows[key] = row
            }
        }
        return rows.values.sorted { $0.end > $1.end }
    }
}

nonisolated struct EarningsForecast: Identifiable, Sendable {
    let id: String
    let end: String
    let value: YValue
    let validThrough: String
    func isValid(now: Date = .now) -> Bool {
        validThrough >= now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }
    var title: String {
        switch id {
        case "0q": "Current quarter"
        case "+1q": "Next quarter"
        case "0y": "Current fiscal year"
        default: "Next fiscal year"
        }
    }

    static func parse(_ summary: QuoteSummary, now: Date = .now) -> [Self] {
        let nextReport = summary.value("calendarEvents", "earnings")?["earningsDate"]?.array.compactMap(\.date).min()
        return (summary.value("earningsTrend", "trend")?.array ?? []).compactMap { item in
            guard let period = item["period"]?.text, ["0q", "+1q", "0y", "+1y"].contains(period),
                  let end = item["endDate"]?.text,
                  ["earningsEstimate", "revenueEstimate"].contains(where: { item[$0]?["avg"]?.raw?.isFinite == true }) else { return nil }
            let periodEnd = ISO8601DateFormatter().date(from: end + "T00:00:00Z")
            let pendingReport = nextReport.flatMap { report -> Date? in
                guard let periodEnd, report >= periodEnd, report.timeIntervalSince(periodEnd) <= 184 * 86_400 else { return nil }
                return report
            }
            let reportDay = pendingReport?.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            let validThrough = ["0q", "0y"].contains(period) ? max(end, reportDay ?? end) : end
            let forecast = Self(id: period, end: end, value: item, validThrough: validThrough)
            return forecast.isValid(now: now) ? forecast : nil
        }
    }
}

extension MarketClient {
    @concurrent static func earningsHistory(_ symbol: String) async throws -> [ReportedEarnings] {
        let root = try await authed("/ws/fundamentals-timeseries/v1/finance/timeseries/\(symbol)", [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "type", value: ReportedEarnings.types.joined(separator: ",")),
            URLQueryItem(name: "period1", value: "0"),
            URLQueryItem(name: "period2", value: String(Int(Date.now.timeIntervalSince1970))),
        ])
        guard root["timeseries"]?["result"] != nil else { throw MarketError.notFound(symbol) }
        return ReportedEarnings.parse(root)
    }

    @concurrent static func earningsForecasts(_ symbol: String) async throws -> QuoteSummary {
        let root = try await authed("/v10/finance/quoteSummary/\(symbol)", [URLQueryItem(name: "modules", value: "earningsTrend,calendarEvents,financialData")])
        guard let result = root["quoteSummary"]?["result"]?.array.first else { throw MarketError.notFound(symbol) }
        return QuoteSummary(root: result)
    }
}

struct EarningsHistoryView: View {
    let symbol: String
    let currency: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Quarterly"
    @State private var history: [ReportedEarnings] = []
    @State private var forecasts: [EarningsForecast] = []
    @State private var forecastCurrency: String?
    @State private var historyFailure: String?
    @State private var forecastFailure: String?
    @State private var historyFetched: Date?
    @State private var forecastsFetched: Date?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Picker("Earnings period", selection: $tab) {
                        ForEach(["Quarterly", "Annual", "Estimates"], id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    if loading { ProgressView("Loading earnings…").frame(maxWidth: .infinity) }
                    if tab == "Estimates" {
                        estimates
                    } else {
                        reported
                    }
                }
                .padding(20)
            }
            .navigationTitle("\(symbol) earnings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            .task { await load() }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    @ViewBuilder private var reported: some View {
        let rows = history.filter { $0.annual == (tab == "Annual") }
        Text("Every period returned by Yahoo Finance, newest first. Coverage varies by company; this is not a complete lifetime archive. Missing metrics are unavailable, not zero.")
            .font(.caption).foregroundStyle(.secondary)
        if let historyFailure { failure(historyFailure) }
        if !loading && rows.isEmpty {
            ContentUnavailableView("No reported history available", systemImage: "calendar.badge.exclamationmark")
        }
        ForEach(rows) { row in
            QuoteSection("\(row.annual ? "Year" : "Quarter") ended \(row.end)") {
                metric("Revenue", row.revenue, currency: row.currency)
                metric("Net income", row.netIncome, currency: row.currency)
                metric("Reported diluted EPS", row.dilutedEPS, currency: row.currency, perShare: true)
                if let revenue = row.revenue, revenue != 0, let income = row.netIncome {
                    line("Net margin", (income / revenue).formatted(.percent.precision(.fractionLength(1))))
                }
            }
        }
        Text("Reported diluted EPS may differ from the adjusted EPS used for analyst beat/miss comparisons. Historical revenue consensus is not supplied by this feed.")
            .font(.caption).foregroundStyle(.secondary)
        fetched(historyFetched)
    }

    @ViewBuilder private var estimates: some View {
        Text("Analyst consensus, not company guidance or reported results. Forecasts can change. The provider does not supply a consensus observation timestamp; the retrieval time below does not establish freshness.")
            .font(.caption).foregroundStyle(.secondary)
        if let forecastFailure { failure(forecastFailure) }
        if !loading && forecasts.filter({ $0.isValid() }).isEmpty {
            ContentUnavailableView("No current estimates available", systemImage: "chart.bar.doc.horizontal")
        }
        ForEach(forecasts.filter { $0.isValid() }) { forecast in
            QuoteSection(forecast.title) {
                Text("Period ending \(forecast.end)").font(.subheadline.weight(.semibold))
                estimate("Revenue", forecast.value["revenueEstimate"], perShare: false)
                Divider()
                estimate("EPS", forecast.value["earningsEstimate"], perShare: true)
            }
        }
        fetched(forecastsFetched)
    }

    private func estimate(_ title: String, _ value: YValue?, perShare: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            metric("\(title) estimate", value?["avg"]?.raw, currency: forecastCurrency ?? currency, perShare: perShare)
            metric("Low", value?["low"]?.raw, currency: forecastCurrency ?? currency, perShare: perShare)
            metric("High", value?["high"]?.raw, currency: forecastCurrency ?? currency, perShare: perShare)
            line("Analysts", value?["numberOfAnalysts"]?.raw.map { String(Int($0)) } ?? "Unavailable")
            if let growth = value?["growth"]?.raw, growth.isFinite {
                line("Expected y/y growth", growth.formatted(.percent.precision(.fractionLength(1))))
            }
        }
    }

    private func metric(_ title: String, _ value: Double?, currency: String, perShare: Bool = false) -> some View {
        line(title, value.map {
            perShare ? $0.formatted(.currency(code: currency).precision(.fractionLength(2)))
                : $0.formatted(.currency(code: currency).notation(.compactName).precision(.fractionLength(2)))
        } ?? "Unavailable")
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.subheadline).monospacedDigit().accessibilityElement(children: .combine)
    }

    private func failure(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func fetched(_ date: Date?) -> some View {
        if let date {
            Text("Yahoo Finance · retrieved \(date.formatted(date: .abbreviated, time: .shortened)). Pull to refresh.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        loading = true
        async let reported: () = loadHistory()
        async let estimated: () = loadForecasts()
        _ = await (reported, estimated)
        loading = false
    }

    private func loadHistory() async {
        do {
            history = try await MarketClient.earningsHistory(symbol)
            historyFetched = .now
            historyFailure = nil
        } catch {
            historyFailure = history.isEmpty ? "Reported history could not be loaded. Pull to retry." : "Refresh failed. Showing previously retrieved history."
        }
    }

    private func loadForecasts() async {
        do {
            let summary = try await MarketClient.earningsForecasts(symbol)
            forecasts = EarningsForecast.parse(summary)
            forecastCurrency = summary.text("financialData", "financialCurrency")
            forecastsFetched = .now
            forecastFailure = nil
        } catch {
            forecastFailure = forecasts.isEmpty ? "Estimates could not be loaded. Pull to retry." : "Refresh failed. Showing previously retrieved estimates."
        }
    }
}
