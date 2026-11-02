import Testing
@testable import Newswire

@MainActor struct AskComposerTests {
    @Test func generatedQuestionsMustBeFourDistinctShortLines() {
        #expect(AskSuggestions.valid(AskSuggestions.fallback))
        #expect(!AskSuggestions.valid(Array(AskSuggestions.fallback.prefix(3))))
        #expect(!AskSuggestions.valid(["A?", "B?", "C?", "c?"]))
        #expect(!AskSuggestions.valid(["A?", "B?", "C?", ""]))
        #expect(!AskSuggestions.valid(["A?", "B?", "C?", String(repeating: "x", count: 91)]))
    }
}
