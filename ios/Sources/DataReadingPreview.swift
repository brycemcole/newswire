#if DEBUG
import SwiftUI

struct DataReadingPreview: View {
    let path: String

    var body: some View {
        let route = DataRoute(token: "data:" + path) ?? DataRoute(path)
        let file = URL.documentsDirectory.appending(path: "data-\(route.path.replacingOccurrences(of: "/", with: "-" )).json")
        if let data = try? Data(contentsOf: file), let payload = try? NewswireAPI.decoder().decode(DataPayload.self, from: data) {
            NavigationStack { DataScreen(route: route, previewPayload: payload) }
        } else {
            ContentUnavailableView("Missing preview data", systemImage: "doc", description: Text(file.lastPathComponent))
        }
    }
}

struct InstitutionalPreview: View {
    private let payload: DataPayload? = {
        let json = #"""
        {
          "title":"The International Consortium for Strategic Asset Management institutional positions",
          "source":"SEC EDGAR",
          "url":"https://www.sec.gov/edgar/search/",
          "as_of":"2026-10-07T14:30:00.000Z",
          "note":"Form 13F reports are filed up to 45 days after quarter end. These holdings are a historical snapshot, not current trading. Position changes compare reported share counts and may reflect transfers or reporting changes.",
          "sections":[
            {"title":"Quarter overview","rows":[
              {"label":"Reporting period","value":"2026-06-30","detail":"Filed 2026-08-14"},
              {"label":"Reported 13F value","value":"$128.4B","detail":"SEC-reported value across 2,416 reportable positions"},
              {"label":"New positions","value":"42"},{"label":"Increased positions","value":"318"},
              {"label":"Reduced positions","value":"271"},{"label":"Exited positions","value":"36"}]},
            {"title":"New positions","rows":[
              {"label":"International Business Machines Corporation","value":"$3.84B","detail":"12,400,000 shares · 3.0% of portfolio","change_label":"NEW","symbol":"IBM"},
              {"label":"Berkshire Hathaway Inc. Class B","value":"$2.16B","detail":"8,150,000 shares · 1.7% of portfolio","change_label":"NEW","symbol":"BRK-B"}]},
            {"title":"Increased positions","rows":[
              {"label":"Taiwan Semiconductor Manufacturing Company Limited","value":"$6.72B","detail":"34,200,000 shares · 5.2% of portfolio","change_label":"+18.4% shares","symbol":"TSM"}]},
            {"title":"Reduced positions","rows":[
              {"label":"The Coca-Cola Company","value":"$1.94B","detail":"28,100,000 shares · 1.5% of portfolio","change_label":"−7.2% shares","symbol":"KO"}]},
            {"title":"Exited positions","rows":[]},
            {"title":"All reported positions","rows":[
              {"label":"International Business Machines Corporation","value":"$3.84B","detail":"12,400,000 shares","change_label":"NEW","symbol":"IBM"},
              {"label":"Taiwan Semiconductor Manufacturing Company Limited","value":"$6.72B","detail":"34,200,000 shares","change_label":"+18.4% shares","symbol":"TSM"}]},
            {"title":"Historical quarters","rows":[
              {"label":"March 31, 2026","value":"$121.7B","detail":"Filed May 15, 2026"},
              {"label":"December 31, 2025","value":"$117.2B","detail":"Filed February 13, 2026"}]}
          ],
          "page":{"total":2416,"offset":0,"limit":100},
          "text":"Institutional portfolio preview"
        }
        """#
        return try? NewswireAPI.decoder().decode(DataPayload.self, from: Data(json.utf8))
    }()

    var body: some View {
        if let payload {
            NavigationStack { DataScreen(route: DataRoute("sec/institutions", ["manager": "0001067983"]), previewPayload: payload) }
                .environment(\.dynamicTypeSize, CommandLine.arguments.contains("-institutionalPreviewAccessibility") ? .accessibility5 : .large)
        } else {
            ContentUnavailableView("Institutional preview unavailable", systemImage: "doc", description: Text("The built-in 13F fixture could not be decoded."))
        }
    }
}

struct MarketStatsPreview: View {
    private let symbols = ["EROC", "CEG"]
    private var quotes: [String: Quote] {
        Dictionary(uniqueKeysWithValues: symbols.enumerated().map { index, symbol in
            let quote = Quote(symbol: symbol, name: index == 0 ? "ERock" : "Constellation Energy", match: nil, currency: "USD", exchange: "NASDAQ", state: "post",
                              price: 120, change: 10, changePercent: index == 0 ? 10.09 : 12.25, previousClose: 110, time: .now,
                              extended: Quote.Extended(session: "post", price: 121, change: 1, changePercent: index == 0 ? 1.17 : -1.21, time: .now),
                              points: [], extendedPoints: [], url: URL(string: "https://finance.yahoo.com")!)
            return (symbol, quote)
        })
    }
    private func market(_ symbol: String, _ name: String) -> MarketQuote? {
        let value = #"{"symbol":"\#(symbol)","longName":"\#(name)","regularMarketPrice":120,"regularMarketChange":2,"regularMarketChangePercent":1.5,"currency":"USD"}"#
        return (try? JSONDecoder().decode(YValue.self, from: Data(value.utf8))).flatMap(MarketQuote.init)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    QuoteSection("Watchlist") {
                        HStack(alignment: .top) {
                            VStack(spacing: 0) {
                                CompactWatchlistQuote(symbol: "NVDA", quote: market("NVDA", "NVIDIA"))
                                Divider()
                                CompactWatchlistQuote(symbol: "AAPL", quote: market("AAPL", "Apple"))
                                Divider()
                                CompactWatchlistQuote(symbol: "MSFT", quote: market("MSFT", "Microsoft"))
                            }
                            .frame(maxWidth: .infinity)
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    Text("ERock Stock Jumps 10% on AI Power Surge").font(.title3.weight(.semibold))
                    Text("Two stocks mentioned in this story").font(.subheadline).foregroundStyle(.secondary)
                    StoryQuoteStats(symbols: symbols, quotes: quotes).frame(width: 240, alignment: .leading)
                    Divider()
                    Text("SpaceX looks to raise $40bn to buy Nvidia chips").font(.title3.weight(.semibold))
                    StoryQuoteStats(symbols: [symbols[0]], quotes: quotes)
                }
                .padding(16)
            }
            .navigationTitle("Watchlist and story stats")
        }
    }
}
#endif
