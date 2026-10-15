import ActivityKit
import SwiftUI
import WidgetKit

struct PriceWatchActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PriceWatchAttributes.self) { context in
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(context.attributes.symbol).font(.headline)
                    if let target = context.state.target {
                        Text("\(context.state.direction == "above" ? "At or above" : "At or below") \(target.formatted(.currency(code: context.state.currency)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(context.isStale ? "Quote delayed" : "Quoted \(context.state.quotedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(context.state.price, format: .currency(code: context.state.currency))
                        .font(.title2.bold()).monospacedDigit()
                    if context.state.reached { Label("Target met", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                }
            }
            .padding(16)
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .widgetURL(URL(string: "newswire://quote/\(context.attributes.symbol)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(context.attributes.symbol).font(.headline).lineLimit(1) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.price, format: .currency(code: context.state.currency)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if context.state.reached { Label("Target met", systemImage: "checkmark.circle.fill") }
                        Spacer()
                        Text(context.isStale ? "Quote delayed" : "Quoted \(context.state.quotedAt.formatted(date: .omitted, time: .shortened))")
                    }.font(.caption)
                }
            } compactLeading: {
                Text(context.attributes.symbol).font(.caption2).lineLimit(1)
            } compactTrailing: {
                Text(context.state.price, format: .number.precision(.fractionLength(2))).font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: context.state.reached ? "checkmark.circle" : "chart.line.uptrend.xyaxis")
            }
            .widgetURL(URL(string: "newswire://quote/\(context.attributes.symbol)"))
        }
    }
}
