import SwiftUI
import UIKit

enum DockDetent { case peek, medium, large }

/// The dock's on-screen frame, read only when a touch lands. It is deliberately not observable: the frame changes on every
/// frame of a drag or detent animation, and publishing that as view state re-rendered the whole feed underneath each frame.
final class DockFrame {
    var value = CGRect.zero
}

struct DockBackgroundInteraction: UIGestureRecognizerRepresentable {
    var excludedFrame: DockFrame
    var onInteraction: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(excludedFrame: excludedFrame)
    }

    func makeUIGestureRecognizer(context: Context) -> DockBackgroundTouchRecognizer {
        let recognizer = DockBackgroundTouchRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        recognizer.onInteraction = onInteraction
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: DockBackgroundTouchRecognizer, context: Context) {
        context.coordinator.excludedFrame = excludedFrame
        recognizer.onInteraction = onInteraction
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var excludedFrame: DockFrame

        init(excludedFrame: DockFrame) { self.excludedFrame = excludedFrame }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !excludedFrame.value.contains(touch.location(in: touch.view?.window))
        }
    }
}

final class DockBackgroundTouchRecognizer: UIGestureRecognizer {
    var onInteraction: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onInteraction?()
        state = .failed
    }
}

/// A persistent bottom sheet over the whole app. At rest only the search bar shows; drag it up
/// (or tap the search field) to reach indices, movers and earnings from any screen.
/// It is an overlay, not a system sheet, so alerts, sheets and Safari covers can still present from the screens under it.
struct MarketDock: View {
    /// Collapsed, the dock is only the search bar with equal space above and below it, about the height of a tab bar.
    static let peekHeight: CGFloat = 72
    static let storySuggestionHeight: CGFloat = 42
    /// Space above the search bar when collapsed, matching the search sheet's space below it.
    static let barInset: CGFloat = 12
    /// Space under the floating dock, measured from the bottom edge of the screen.
    static let floatGap: CGFloat = 24
    /// Side margin of the floating dock, matching the content margin of the screens under it.
    static let sideInset: CGFloat = 16
    /// How much room screens under the dock reserve at the bottom (dock top edge, less the home-indicator inset it already sits above).
    static let clearance: CGFloat = peekHeight + floatGap - 34

    @Binding var detent: DockDetent
    let onSelect: (String) -> Void
    var onAsk: (String) -> Void = { _ in }
    var onSuggestionSelect: ((String) -> Void)?
    var suggestedSymbols: [String] = []
    var onFrameChange: (CGRect) -> Void = { _ in }
    @State private var drag: CGFloat = 0
    @State private var keyboard: CGFloat = 0
    @State private var quoteStore = QuoteStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let radius: CGFloat = 34
    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.05) }

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
            VStack(spacing: suggestedSymbols.isEmpty ? 0 : 8) {
                if !suggestedSymbols.isEmpty { storySuggestions.padding(.horizontal, 22) }
                MarketSearchSheet(detent: $detent, onSelect: onSelect, onAsk: onAsk)
                    .equatable()
                    .padding(.top, Self.barInset + 8 * docked)
                    .overlay(alignment: .top) { handle(stops) }
                    .padding(.bottom, max(inset, keyboard))
                    .frame(height: height + Self.floatGap * docked, alignment: .top)
                    .clipShape(shape)
                    .glassEffect(.regular, in: shape)
                    .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
                    .padding(.horizontal, Self.sideInset * (1 - docked))
                    .padding(.bottom, Self.floatGap * (1 - docked))
            }
            .animation(animation, value: detent)
            .animation(.easeOut(duration: 0.18), value: suggestedSymbols)
            .simultaneousGesture(dragGesture(stops), including: detent == .peek ? .all : .subviews)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrameChange($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // The keyboard must not resize the dock: the frame would change under the drag and while it dismisses, which is what made collapsing judder.
        // Instead the frame ignores it and the content is padded up by the keyboard's height.
        .ignoresSafeArea(.all, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let hidden = frame.minY >= UIScreen.main.bounds.height
            withAnimation(.easeOut(duration: 0.25)) { keyboard = hidden ? 0 : frame.height }
        }
    }

    private func handle(_ stops: Stops) -> some View {
        Capsule().fill(.tertiary)
            .frame(width: 36, height: 5)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .top)
            .contentShape(.rect)
            .onTapGesture { detent = detent == .peek ? .medium : .peek }
            .gesture(dragGesture(stops), including: detent == .peek ? .none : .all)
            .accessibilityElement()
            .accessibilityLabel("Markets")
            .accessibilityIdentifier("market-dock-handle")
            .accessibilityValue(detent == .peek ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { detent = detent == .peek ? .medium : .peek }
    }

    private func dragGesture(_ stops: Stops) -> some Gesture {
        // Global space: the dock resizes under the finger, so a local translation would feed back into itself and jitter.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { drag = $0.translation.height }
            .onEnded { value in
                let target = stops.height(detent) - value.predictedEndTranslation.height
                // The drag offset is released in the same animation as the detent change, so the two never play as separate motions.
                withAnimation(animation) {
                    detent = stops.nearest(to: target)
                    drag = 0
                }
            }
    }

    private struct Stops {
        let available: CGFloat

        func height(_ detent: DockDetent) -> CGFloat {
            switch detent {
            case .peek: MarketDock.peekHeight
            case .medium: max(available * 0.52, MarketDock.peekHeight + 240)
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

    private var storySuggestions: some View {
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(suggestedSymbols.prefix(6), id: \.self) { symbol in
                    Button {
                        if let onSuggestionSelect { onSuggestionSelect(symbol) }
                        else { onSelect(symbol) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(symbol)
                            if let quote = quoteStore.quotes[symbol] {
                                Text(QuoteFormat.percent(quote.changePercent))
                                    .foregroundStyle(QuoteFormat.color(quote.changePercent))
                            }
                        }
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(symbol), mentioned in this story")
                    .accessibilityHint("Shows quote details")
                }
            }
            .frame(height: 34, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

extension View {
    /// Keeps content clear of the dock's resting search bar.
    func dockClearance(suggestions: Bool = false) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: MarketDock.clearance + (suggestions ? MarketDock.storySuggestionHeight : 0))
        }
    }
}
