import SwiftUI

enum AppTab: Hashable { case today, portfolio, ask }

/// The tab selection and what the reader was last looking at, so Ask can answer questions about it.
@Observable final class AppNavigator {
    static let shared = AppNavigator()
    var tab = AppTab.today
    private(set) var screens: [AppTab: AskContext] = [:]
    private(set) var lastBrowsed = AppTab.today

    /// The context Ask opens with: whatever was on screen in the tab the reader left.
    var askContext: AskContext { screens[lastBrowsed] ?? .markets }

    func setScreen(_ context: AskContext, for tab: AppTab) {
        screens[tab] = context
    }

    func select(_ next: AppTab) {
        if tab != .ask { lastBrowsed = tab }
        tab = next
    }
}

struct AppTabs: View {
    @State private var navigator = AppNavigator.shared

    var body: some View {
        TabView(selection: Binding(get: { navigator.tab }, set: { navigator.select($0) })) {
            Tab("Today", systemImage: "newspaper", value: AppTab.today) { FeedView().environment(\.askTab, .today) }
            Tab("Portfolio", systemImage: "briefcase", value: AppTab.portfolio) { PortfolioView(embedded: true).environment(\.askTab, .portfolio) }
            Tab("Ask", systemImage: "message", value: AppTab.ask) {
                AskSheet(context: navigator.askContext, embedded: true)
            }
        }
        .environment(navigator)
    }
}

private struct AskTabKey: EnvironmentKey { static let defaultValue = AppTab.today }

extension EnvironmentValues {
    var askTab: AppTab {
        get { self[AskTabKey.self] }
        set { self[AskTabKey.self] = newValue }
    }
}

private struct AsksAbout: ViewModifier {
    let context: AskContext
    @Environment(\.askTab) private var tab
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; AppNavigator.shared.setScreen(context, for: tab) }
            .onDisappear { visible = false }
            .onChange(of: context) { _, new in if visible { AppNavigator.shared.setScreen(new, for: tab) } }
    }
}

extension View {
    /// Tells Ask what this screen shows, so it can answer questions about it when the reader switches tabs.
    func asksAbout(_ context: AskContext) -> some View { modifier(AsksAbout(context: context)) }
}
