import SwiftUI
import UIKit

enum AppTab: Hashable { case today, portfolio, ask }

/// The tab selection and what the reader was last looking at, so Ask can answer questions about it.
@Observable final class AppNavigator {
    static let shared = AppNavigator()
    var tab = AppTab.today
    private(set) var screens: [AppTab: AskContext] = [:]
    private(set) var lastBrowsed = AppTab.today
    private(set) var askReselections = 0

    /// The context Ask opens with: whatever was on screen in the tab the reader left.
    var askContext: AskContext { screens[lastBrowsed] ?? .markets }

    func setScreen(_ context: AskContext, for tab: AppTab) {
        screens[tab] = context
    }

    func select(_ next: AppTab) {
        if tab != .ask { lastBrowsed = tab } else if next == .ask { askReselections += 1 }
        tab = next
    }
}

struct AppTabs: View {
    @State private var navigator = AppNavigator.shared
    private var selection: Binding<AppTab> { Binding(get: { navigator.tab }, set: { navigator.select($0) }) }

    var body: some View {
        // The system tab bar is a compact pill that can't be widened, so it is hidden and replaced by a full-width bar
        // with the same side margin as the market dock above it.
        TabView(selection: selection) {
            Tab("Today", systemImage: "sun.max", value: AppTab.today) {
                FeedView().environment(\.askTab, .today).fullWidthTabBar()
            }
            Tab("Portfolio", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.portfolio) {
                PortfolioHome().environment(\.askTab, .portfolio).fullWidthTabBar()
            }
            Tab("Ask", systemImage: "questionmark.bubble", value: AppTab.ask) {
                AskSheet(context: navigator.askContext, embedded: true).fullWidthTabBar()
            }
        }
        .overlay {
            FullWidthTabBar(selection: selection)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .background(alignment: .bottom) {
                    // Content scrolls under the floating bar, so fade it out behind the bar instead of letting rows collide with its labels.
                    LinearGradient(colors: [.clear, Color(.systemBackground).opacity(0.92)], startPoint: .top, endPoint: .bottom)
                        .frame(height: FullWidthTabBar.height + 28)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
        }
        .environment(navigator)
        .environment(\.dockAboveTabBar, true)
        .task {
            // Load today's portfolio graph and option prices at launch so the Portfolio tab opens on real values.
            let snapshot = PortfolioStore.shared.snapshot
            guard !snapshot.positions.isEmpty else { return }
            async let options: Void = HeldOptionQuotes.shared.refresh(snapshot.positions)
            await PortfolioPerformance.shared.refresh(snapshot)
            await options
        }
    }
}

private extension View {
    func fullWidthTabBar() -> some View {
        toolbarVisibility(.hidden, for: .tabBar).background(TabBarInset().allowsHitTesting(false))
    }
}

/// A SwiftUI safe area inset does not reach a NavigationStack's own bottom bars (Ask's composer), so the room for the
/// custom tab bar is reserved on the tab bar controller, which every screen under it inherits.
private struct TabBarInset: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.apply() }

    final class Controller: UIViewController {
        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            apply()
        }

        func apply() {
            guard let tabs = tabBarController, tabs.additionalSafeAreaInsets.bottom != FullWidthTabBar.height else { return }
            tabs.additionalSafeAreaInsets.bottom = FullWidthTabBar.height
        }
    }
}

private struct FullWidthTabBar: View {
    @Binding var selection: AppTab
    /// The 52 point buttons, 4 points of padding around them and 4 below the bar.
    static let height: CGFloat = 64
    private let items: [(tab: AppTab, title: String, icon: String)] = [
        (.today, "Today", "sun.max"), (.portfolio, "Portfolio", "chart.line.uptrend.xyaxis"), (.ask, "Ask", "questionmark.bubble"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.tab) { item in
                Button { selection = item.tab } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.icon).font(.system(size: 20, weight: .medium)).frame(height: 24)
                        Text(item.title).font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selection == item.tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background { if selection == item.tab { Capsule().fill(.quaternary) } }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selection == item.tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, MarketDock.sideInset)
        .padding(.bottom, 4)
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
