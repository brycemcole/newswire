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
