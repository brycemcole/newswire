import Testing
@testable import Newswire

@MainActor struct AskComposerTests {
    @Test func typedReturnAtTheEndSends() {
        #expect(ComposerReturn.stripped(old: "Why is QQQ up", new: "Why is QQQ up\n") == "Why is QQQ up")
        #expect(ComposerReturn.stripped(old: "", new: "\n") == "")
    }

    @Test func otherEditsAreLeftAlone() {
        #expect(ComposerReturn.stripped(old: "a", new: "ab") == nil)
        #expect(ComposerReturn.stripped(old: "a", new: "a\nb\n") == nil)
        #expect(ComposerReturn.stripped(old: "ab", new: "a\nb") == nil)
        #expect(ComposerReturn.stripped(old: "a\n", new: "a") == nil)
    }

    @Test func generatedQuestionsMustBeFourDistinctShortLines() {
        #expect(AskSuggestions.valid(AskSuggestions.fallback))
        #expect(!AskSuggestions.valid(Array(AskSuggestions.fallback.prefix(3))))
        #expect(!AskSuggestions.valid(["A?", "B?", "C?", "c?"]))
        #expect(!AskSuggestions.valid(["A?", "B?", "C?", ""]))
        #expect(!AskSuggestions.valid(["A?", "B?", "C?", String(repeating: "x", count: 91)]))
    }
}
