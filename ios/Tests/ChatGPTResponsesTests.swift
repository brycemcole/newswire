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

    @Test func researchContinuesBeyondSixteenToolRounds() async throws {
        let research = StockResearchTools(symbol: "", name: "Markets") { _ in }
        var requests = 0
        let answer = try await StockChat().chatGPT(instructions: "test", history: "", question: "Find ten stocks", research: research, data: [], modelOverride: "test") { body, _ in
            requests += 1
            if requests <= 16 {
                #expect(body["tool_choice"] as? String == "auto")
                return [["type": "function_call", "call_id": "call-\(requests)", "name": "unknown", "arguments": "{}"]]
            }
            #expect(body["tool_choice"] as? String == "auto")
            let input = body["input"] as? [[String: Any]] ?? []
            #expect(input.filter { $0["type"] as? String == "function_call_output" }.count == 16)
            return [["type": "message", "content": [["type": "output_text", "text": "Insufficient evidence to identify ten stocks."]]]]
        }
        #expect(requests == 17)
        #expect(answer == "Insufficient evidence to identify ten stocks.")
    }

    @Test func toolContinuationPreservesReasoningAndMessagePhase() async throws {
        let research = StockResearchTools(symbol: "", name: "Markets") { _ in }
        var requests = 0
        let output: [[String: Any]] = [
            ["type": "reasoning", "id": "rs_test", "summary": [], "encrypted_content": "test-only"],
            ["type": "message", "id": "msg_test", "role": "assistant", "phase": "commentary",
             "content": [["type": "output_text", "text": "Checking the evidence."]]],
            ["type": "function_call", "id": "fc_test", "call_id": "call_test", "name": "unknown", "arguments": "{}"]
        ]
        _ = try await StockChat().chatGPT(instructions: "test", history: "", question: "Why did Lumentum sink today?", research: research, data: [], modelOverride: "test") { body, _ in
            requests += 1
            if requests == 1 { return output }
            let input = try #require(body["input"] as? [[String: Any]])
            #expect(input.compactMap { $0["type"] as? String } == ["reasoning", "message", "function_call", "function_call_output"])
            #expect(input[1]["encrypted_content"] as? String == "test-only")
            #expect(input[2]["phase"] as? String == "commentary")
            #expect(input[3]["id"] as? String == "fc_test")
            return [["type": "message", "content": [["type": "output_text", "text": "Answer"]]]]
        }
        #expect(requests == 2)
    }

    @Test func incompleteResponsePreservesReasonAndRequestID() throws {
        for reason in ["max_output_tokens", "content_filter", "unknown"] {
            let response: [String: Any] = ["type": "response.incomplete", "response": [
                "status": "incomplete", "incomplete_details": ["reason": reason],
                "output": [["type": "message", "content": [["type": "output_text", "text": "Partial answer"]]]]
            ]]
            #expect(throws: ChatGPTError.responseIncomplete(reason, "req_test")) {
                _ = try ChatGPTResponses.terminalResponse(response, requestID: "req_test")
            }
        }
        #expect(!(ChatGPTError.responseIncomplete("max_output_tokens", nil).localizedDescription.contains("focused")))
    }

    @Test func completedResponseKeepsOutputIntact() throws {
        let response: [String: Any] = ["status": "completed", "output": [["type": "reasoning", "summary": []]]]
        let data = try ChatGPTResponses.terminalResponse(["type": "response.completed", "response": response], requestID: nil)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((decoded["output"] as? [[String: Any]])?.first?["type"] as? String == "reasoning")
    }

    @Test func missingAndRefusedAnswersAreNotMisreportedAsTruncation() {
        #expect(throws: ChatGPTError.missingAnswer) { _ = try ChatGPTResponses.answer([]) }
        #expect(throws: ChatGPTError.missingAnswer) {
            _ = try ChatGPTResponses.answer([["type": "reasoning", "summary": []]])
        }
        #expect(throws: ChatGPTError.refused) {
            _ = try ChatGPTResponses.answer([["type": "message", "content": [["type": "refusal", "refusal": "Declined"]]]])
        }
    }

    @Test func formEncodingEscapesReservedCharacters() {
        let body = String(decoding: ChatGPTAccount.form(["redirect_uri": "http://127.0.0.1:1455/auth/callback", "code": "a+b"]), as: UTF8.self)
        #expect(body == "code=a%2Bb&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback")
    }
}
