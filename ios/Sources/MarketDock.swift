import SwiftUI

enum DockDetent { case peek, medium, large }

/// A persistent bottom sheet over the whole app. At rest only the search bar shows; drag it up
/// (or tap the search field) to reach indices, movers and earnings from any screen.
/// It is an overlay, not a system sheet, so alerts, sheets and Safari covers can still present from the screens under it.
struct MarketDock: View {
    /// Height of the handle, search bar and the top edge of the index cards.
    static let peekHeight: CGFloat = 160
    /// Space under the floating dock, measured from the bottom edge of the screen.
    static let floatGap: CGFloat = 14
    /// How much room screens under the dock reserve at the bottom (dock top edge, less the home-indicator inset it already sits above).
    static let clearance: CGFloat = peekHeight + floatGap - 34

    @Binding var detent: DockDetent
    let onSelect: (String) -> Void
    @GestureState private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let radius: CGFloat = 34
    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.45, bounce: 0.22) }

    var body: some View {
        GeometryReader { proxy in
            let stops = Stops(available: proxy.size.height)
            let height = stops.rubberBanded(stops.height(detent) - drag)
            // 0 while resting (a floating card), 1 once expanded (docked to the bottom and sides, filling the home-indicator area).
            let docked = min(max((height - stops.height(.peek)) / (stops.height(.medium) - stops.height(.peek)), 0), 1)
            let inset = min(proxy.safeAreaInsets.bottom, 34) * docked
            // Bottom corners follow the display's own curve (concentric with it, whatever the inset), so they match the device.
            let shape = ConcentricRectangle(topLeadingCorner: .fixed(radius), topTrailingCorner: .fixed(radius),
                                            bottomLeadingCorner: .concentric(minimum: 20), bottomTrailingCorner: .concentric(minimum: 20))
            VStack(spacing: 0) {
                handle(stops)
                MarketSearchSheet(detent: $detent, onSelect: onSelect)
            }
            .padding(.bottom, inset)
            .frame(height: height + Self.floatGap * docked, alignment: .top)
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
            .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
            .animation(animation, value: detent)
            .simultaneousGesture(dragGesture(stops), including: detent == .peek ? .all : .subviews)
            .padding(.horizontal, 8 * (1 - docked))
            .padding(.bottom, Self.floatGap * (1 - docked))
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

        func height(_ detent: DockDetent) -> CGFloat {
            switch detent {
            case .peek: MarketDock.peekHeight
            case .medium: max(available * 0.52, MarketDock.peekHeight + 160)
            case .large: max(available - MarketDock.floatGap - 8, MarketDock.peekHeight)
            }
        }

        /// Past either end the dock keeps following the finger, but with resistance, so it feels elastic rather than hitting a wall.
        func rubberBanded(_ raw: CGFloat) -> CGFloat {
            let low = height(.peek), high = height(.large)
            if raw > high { return high + (raw - high) * 0.2 }
            if raw < low { return low - (low - raw) * 0.2 }
            return raw
        }

        func nearest(to target: CGFloat) -> DockDetent {
            [DockDetent.peek, .medium, .large].min { abs(height($0) - target) < abs(height($1) - target) } ?? .peek
        }
    }
}

extension View {
    /// Keeps content clear of the dock's resting search bar.
    func dockClearance() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: MarketDock.clearance) }
    }
}
