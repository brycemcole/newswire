import Testing
import UIKit
@testable import Newswire

struct DockBackgroundInteractionTests {
    @Test func dismissesAtTouchStartWithoutRecognizingAGesture() {
        let recognizer = DockBackgroundTouchRecognizer()
        var interactions = 0
        recognizer.onInteraction = { interactions += 1 }

        recognizer.touchesBegan([], with: UIEvent())

        #expect(interactions == 1)
        #expect(recognizer.state != .recognized)
    }
}
