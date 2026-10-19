import SwiftUI

private struct NumericText<Value: Equatable>: ViewModifier {
    let value: Value
    let number: Double?
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(reduceMotion || !animated ? .identity : number.map { .numericText(value: $0) } ?? .numericText())
            .animation(reduceMotion || !animated ? nil : .easeOut(duration: 0.2), value: value)
    }
}

extension View {
    func numericTextTransition(value: Double?, animated: Bool = true) -> some View {
        modifier(NumericText(value: value, number: value, animated: animated))
    }

    func numericTextTransition(text: String, animated: Bool = true) -> some View {
        modifier(NumericText(value: text, number: nil, animated: animated))
    }
}
