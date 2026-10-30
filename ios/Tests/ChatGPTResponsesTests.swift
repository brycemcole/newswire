import Foundation
import Testing
@testable import Newswire

@MainActor struct ChatGPTResponsesTests {
    @Test func planErrorsMapToTheirRecovery() {
        func error(_ code: String, status: Int = 403, param: String? = nil) -> ChatGPTError {
            var body: [String: Any] = ["code": code, "message": "m"]
            if let param { body["param"] = param }
            return ChatGPTError.from(status: status, body: try! JSONSerialization.data(withJSONObject: ["error": body]))
        }
        #expect(error("subscription_sharing_user_not_eligible") == .notEligible)
        #expect(error("subscription_sharing_usage_limit_exceeded", status: 429) == .usageLimit)
        #expect(error("subscription_sharing_usage_unavailable", status: 503) == .unavailable)
        #expect(error("subscription_sharing_unsupported_capability", status: 400, param: "tools[2]") == .unsupported("tools[2]"))
        #expect(ChatGPTError.from(status: 401, body: Data(#"{"detail":"no"}"#.utf8)) == .sessionExpired)
        #expect(ChatGPTError.from(status: 500, body: Data(), requestID: "req_1") == .rejected(500, "request req_1"))
    }

    @Test func webLinksBecomeNumberedSources() async {
        let research = StockResearchTools(symbol: "", name: "Markets") { _ in }
        let text = "Stocks fell 2% ([Reuters](https://reuters.com/a?utm_source=openai)). Bonds rallied, per [AP](https://apnews.com/b). Again ([Reuters](https://reuters.com/a?utm_source=openai))."
        let cited = await ChatGPTResponses.cite(text, titles: ["https://reuters.com/a?utm_source=openai": "Markets slide"], research: research)
        #expect(cited == "Stocks fell 2% [1]. Bonds rallied, per AP [2]. Again [1].")
        let sources = await research.sources
        #expect(sources.map(\.url.absoluteString) == ["https://reuters.com/a", "https://apnews.com/b"])
        #expect(sources.first?.title == "Markets slide")
    }

    @Test func extractsTextAndCitationTitles() {
        let output: [[String: Any]] = [
            ["type": "web_search_call", "id": "ws_1"],
            ["type": "message", "content": [["type": "output_text", "text": "Hi",
                "annotations": [["type": "url_citation", "url": "https://a.example", "title": "A"]]]]]
        ]
        let message = ChatGPTResponses.message(output)
        #expect(message.text == "Hi")
        #expect(message.titles == ["https://a.example": "A"])
    }

    @Test func formEncodingEscapesReservedCharacters() {
        let body = String(decoding: ChatGPTAccount.form(["redirect_uri": "http://127.0.0.1:1455/auth/callback", "code": "a+b"]), as: UTF8.self)
        #expect(body == "code=a%2Bb&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback")
    }
}
