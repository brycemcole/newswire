import SwiftUI

enum DockDetent { case peek, medium, large }

/// A persistent bottom sheet over the whole app. At rest only the search bar shows; drag it up
/// (or tap the search field) to reach indices, movers and earnings from any screen.
/// It is an overlay, not a system sheet, so alerts, sheets and Safari covers can still present from the screens under it.
struct MarketDock: View {
    /// Height of the handle, search bar and the top edge of the index cards. Screens under the dock reserve this much space.
    static let peekHeight: CGFloat = 144

    @Binding var detent: DockDetent
    let onSelect: (String) -> Void
    @GestureState private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 28, style: .continuous)
    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.35) }

    var body: some View {
        GeometryReader { proxy in
            // The glass runs under the home indicator, so the frame includes the bottom inset and the content is padded back up out of it.
            let inset = min(proxy.safeAreaInsets.bottom, 34)
            let stops = Stops(available: proxy.size.height, inset: inset)
            let height = min(max(stops.height(detent) - drag, stops.height(.peek)), stops.height(.large))
            VStack(spacing: 0) {
                handle(stops)
                MarketSearchSheet(detent: $detent, onSelect: onSelect)
            }
            .padding(.bottom, inset)
            .frame(height: height, alignment: .top)
            .glassEffect(.regular, in: shape)
            .animation(animation, value: detent)
            .simultaneousGesture(dragGesture(stops), including: detent == .peek ? .all : .subviews)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea(.container, edges: .bottom)
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
        // Global space: the dock resizes under the finger, so a local translation would feed back into itself and jitter.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($drag) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                let target = stops.height(detent) - value.predictedEndTranslation.height
                withAnimation(animation) { detent = stops.nearest(to: target) }
            }
    }

    private struct Stops {
        let available: CGFloat
        let inset: CGFloat

        func height(_ detent: DockDetent) -> CGFloat {
            let peek = MarketDock.peekHeight + inset
            switch detent {
            case .peek: return peek
            case .medium: return max(available * 0.52, peek + 160)
            case .large: return max(available - 8, peek)
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
