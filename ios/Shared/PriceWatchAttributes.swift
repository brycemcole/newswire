import ActivityKit
import Foundation

public nonisolated struct PriceWatchAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var price: Double
        var currency: String
        var quotedAt: Date
        var target: Double?
        var direction: String
        var reached: Bool
    }

    var watchID: String
    var expiresAt: Date
    var symbol: String
}
