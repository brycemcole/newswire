import WidgetKit

enum WidgetFeed {
    static func publish(_ snapshot: PortfolioSnapshot, day: PerformanceSeries?) {
        guard !snapshot.positions.isEmpty || snapshot.cash != 0 else {
            if WidgetPortfolio.load() != nil {
                WidgetPortfolio.clear()
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetPortfolio.kind)
            }
            return
        }
        let previous = WidgetPortfolio.load()
        let earlier = Dictionary((previous?.holdings ?? []).map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        let shares = snapshot.positions.filter { $0.option == nil && $0.quantity != 0 }
        let holdings = Dictionary(grouping: shares, by: \.symbol).map { symbol, lots in
            let quantity = lots.reduce(0) { $0 + $1.quantity }
            let value = lots.compactMap(\.value).reduce(0, +)
            let costs = lots.compactMap(\.costBasis)
            let known = earlier[symbol]
            return WidgetHolding(symbol: symbol, name: lots.first?.name, quantity: quantity,
                                 cost: costs.count == lots.count ? costs.reduce(0, +) : nil,
                                 price: known?.quantity == quantity ? known!.price : value / quantity,
                                 previousClose: known?.previousClose, spark: known?.spark ?? [])
        }
        let options = snapshot.positions.filter { $0.option != nil }
        let gains = options.compactMap(\.gain)
        var portfolio = WidgetPortfolio(
            holdings: holdings, cash: snapshot.cash, other: options.compactMap(\.value).reduce(0, +),
            otherGain: gains.isEmpty ? nil : gains.reduce(0, +),
            value: day?.last ?? snapshot.totalValue, dayBaseline: day?.baseline,
            day: WidgetPortfolio.thin((day?.points ?? []).map { WidgetPoint(date: $0.date, value: $0.value) }, to: 120),
            updated: snapshot.updated ?? .now, fetched: day == nil ? nil : .now)
        if let previous, Set(previous.holdings.map(\.symbol)) == Set(holdings.map(\.symbol)) {
            portfolio.month = previous.month
            portfolio.monthFetched = previous.monthFetched
            if day == nil {
                portfolio.day = previous.day
                portfolio.dayBaseline = previous.dayBaseline
                portfolio.fetched = previous.fetched
            }
        }
        portfolio.save()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetPortfolio.kind)
    }
}
