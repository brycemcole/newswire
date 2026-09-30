#if DEBUG
import SwiftUI
import WidgetKit

struct WidgetGallery: View {
    let page: String
    private let sample = WidgetPortfolio.sample

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                switch page {
                case "lock":
                    lock(.accessoryInline, width: 250, height: 22)
                    lock(.accessoryCircular, width: 76, height: 76)
                    lock(.accessoryRectangular, width: 172, height: 76)
                    lock(.accessoryRectangular, width: 172, height: 76, empty: true)
                case "large":
                    tile(.systemLarge, width: 364, height: 382)
                    tile(.systemSmall, width: 170, height: 170, empty: true)
                case "xl":
                    tile(.systemExtraLarge, width: 715, height: 330)
                        .scaleEffect(0.5).frame(width: 358, height: 165)
                case "news":
                    news(.systemSmall, width: 170, height: 170)
                    news(.systemMedium, width: 364, height: 170)
                    news(.systemLarge, width: 364, height: 382)
                case "newslock":
                    news(.accessoryInline, width: 250, height: 22, lock: true)
                    news(.accessoryCircular, width: 76, height: 76, lock: true)
                    news(.accessoryRectangular, width: 172, height: 76, lock: true)
                    news(.accessoryRectangular, width: 172, height: 76, lock: true, step: 1)
                    news(.systemExtraLarge, width: 715, height: 330)
                        .scaleEffect(0.5).frame(width: 358, height: 165)
                default:
                    tile(.systemSmall, width: 170, height: 170)
                    tile(.systemMedium, width: 364, height: 170)
                }
            }
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }
        .background(page.contains("lock") ? Color.indigo.gradient : Color(uiColor: .systemGroupedBackground).gradient)
    }

    private func tile(_ family: WidgetFamily, width: CGFloat, height: CGFloat, empty: Bool = false) -> some View {
        PortfolioWidgetView(portfolio: empty ? nil : sample, family: family)
            .padding(16)
            .frame(width: width, height: height)
            .background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func news(_ family: WidgetFamily, width: CGFloat, height: CGFloat, lock: Bool = false, step: Int = 0) -> some View {
        let view = NewsWidgetView(news: .sample, date: .now, step: step, family: family).frame(width: width - (lock ? 0 : 32), height: height - (lock ? 0 : 32))
        if lock {
            view.foregroundStyle(.white).environment(\.colorScheme, .dark)
        } else {
            view.padding(16).background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 22, style: .continuous))
        }
    }

    private func lock(_ family: WidgetFamily, width: CGFloat, height: CGFloat, empty: Bool = false) -> some View {
        PortfolioWidgetView(portfolio: empty ? nil : sample, family: family)
            .frame(width: width, height: height)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }
}
#endif
