import SwiftUI

enum DockDetent { case peek, medium, large }

/// A persistent bottom sheet over the whole app. At rest only the search bar shows; drag it up
/// (or tap the search field) to reach indices, movers and earnings from any screen.
/// It is an overlay, not a system sheet, so alerts, sheets and Safari covers can still present from the screens under it.
struct MarketDock: View {
    /// Height of the handle and search bar. Screens under the dock reserve this much space.
    static let peekHeight: CGFloat = 84

    @Binding var detent: DockDetent
    let onSelect: (String) -> Void
    @GestureState private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 28, style: .continuous)
    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.35) }

    var body: some View {
        GeometryReader { proxy in
            let stops = Stops(available: proxy.size.height)
            let height = min(max(stops.height(detent) - drag, Self.peekHeight), stops.height(.large))
            VStack(spacing: 0) {
                handle(stops)
                MarketSearchSheet(detent: $detent, onSelect: onSelect)
            }
            .frame(height: height, alignment: .top)
            .clipShape(shape)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 16, y: -2)
            .animation(animation, value: detent)
            .simultaneousGesture(dragGesture(stops), including: detent == .peek ? .all : .subviews)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func handle(_ stops: Stops) -> some View {
        Capsule().fill(.tertiary)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(.rect)
            .onTapGesture { detent = detent == .peek ? .medium : .peek }
            .gesture(dragGesture(stops), including: detent == .peek ? .none : .all)
            .accessibilityElement()
            .accessibilityLabel("Markets")
            .accessibilityValue(detent == .peek ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { detent = detent == .peek ? .medium : .peek }
    }

    private func dragGesture(_ stops: Stops) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($drag) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                let target = stops.height(detent) - value.predictedEndTranslation.height
                withAnimation(animation) { detent = stops.nearest(to: target) }
            }
    }

    private struct Stops {
        let available: CGFloat

        func height(_ detent: DockDetent) -> CGFloat {
            switch detent {
            case .peek: MarketDock.peekHeight
            case .medium: max(available * 0.52, MarketDock.peekHeight + 160)
            case .large: max(available - 8, MarketDock.peekHeight)
            }
        }

        func nearest(to target: CGFloat) -> DockDetent {
            [DockDetent.peek, .medium, .large].min { abs(height($0) - target) < abs(height($1) - target) } ?? .peek
        }
    }
}

extension View {
    /// Keeps content clear of the dock's resting search bar.
    func dockClearance() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: MarketDock.peekHeight) }
    }
}
