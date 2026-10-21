import Foundation
import Testing
@testable import Newswire

struct MarketStreamTests {
    @Test func decodesStreamerTick() throws {
        let data = try #require(Data(base64Encoded: "CgJNVRWzdoREGJDF8r6eaCoDTk1TMAg4AkX/zQG/ZQDSrMDYAQT1AgDcq8D9AigWAb8="))
        let tick = try #require(MarketTick(data))
        #expect(tick.symbol == "MU")
        #expect(abs(tick.price - 1059.709) < 0.01)
        #expect(tick.date == Date(timeIntervalSince1970: 1_790_798_877))
    }

    @Test func rejectsGarbage() {
        #expect(MarketTick(Data([0xff, 0xff])) == nil)
    }

    @Test func tickUpdatesLastBarOrAppends() throws {
        let start = Date(timeIntervalSince1970: 1_790_776_800)
        let chart = MarketChart(symbol: "MU", name: "Micron", exchange: "", currency: "USD", instrument: "EQUITY", price: 100,
                                previousClose: 99, dayHigh: 101, dayLow: 98, volume: nil, yearHigh: nil, yearLow: nil, decimals: 2,
                                timeZone: .current, points: [PricePoint(id: 0, date: start, open: 100, close: 100, extended: false, run: 0)],
                                slots: 10, pre: nil, regular: MarketSession(start: start, end: start + 23_400), post: nil)
        let same = try #require(chart.applying(tick(102, at: start + 30)))
        #expect(same.points.count == 1 && same.points[0].close == 102 && same.price == 102 && same.dayHigh == 102)
        let next = try #require(same.applying(tick(97, at: start + 125)))
        #expect(next.points.count == 2 && next.points[1].close == 97 && next.dayLow == 97)
        #expect(chart.applying(tick(105, at: start - 60)) == nil)
    }

    @Test func afterHoursQuoteSurvivesTradingPeriodRollover() {
        let open = Date(timeIntervalSince1970: 1_790_776_800)
        let close = open + 23_400
        let next = open + 86_400
        func chart(post: MarketSession?, extended: Bool = true) -> MarketChart {
            MarketChart(symbol: "TKNO", name: "Alpha", exchange: "", currency: "USD", instrument: "EQUITY", price: 7.39,
                        previousClose: 6.8, dayHigh: nil, dayLow: nil, volume: nil, yearHigh: nil, yearLow: nil, decimals: 2,
                        timeZone: .current,
                        points: [PricePoint(id: 0, date: close - 300, open: 7.4, close: 7.39, extended: false, run: 0)]
                            + (extended ? [PricePoint(id: 1, date: close + 600, open: 6.9, close: 6.82, extended: true, run: 1)] : []),
                        slots: 10, pre: MarketSession(start: next - 18_000, end: next), regular: MarketSession(start: next, end: next + 23_400), post: post)
        }
        let current = MarketSession(start: close, end: close + 14_400)
        #expect(chart(post: current).extendedQuote?.price == 6.82)
        // currentTradingPeriod already points at the next session: post no longer contains the returned bars.
        let rolled = chart(post: MarketSession(start: next + 23_400, end: next + 37_800))
        #expect(rolled.extendedQuote?.label == "After hours" && rolled.extendedQuote?.price == 6.82)
        #expect(chart(post: current, extended: false).extendedQuote == nil)
    }

    private func tick(_ price: Float, at date: Date) -> MarketTick {
        var bytes: [UInt8] = [0x0a, 2] + Array("MU".utf8) + [0x15]
        withUnsafeBytes(of: price.bitPattern.littleEndian) { bytes += $0 }
        var zigzag = UInt64(date.timeIntervalSince1970 * 1000) << 1
        bytes.append(0x18)
        while zigzag >= 0x80 { bytes.append(UInt8(zigzag & 0x7f) | 0x80); zigzag >>= 7 }
        bytes.append(UInt8(zigzag))
        return MarketTick(Data(bytes))!
    }
}
