import Foundation
import Testing
@testable import Newswire

@MainActor struct StockResearchTests {
    @Test func optionBudgetUsesAskAndContractMultiplier() throws {
        let values = #"[{"contractSymbol":"XYZ261002C00100000","strike":100,"bid":8,"ask":11,"lastPrice":2},{"contractSymbol":"XYZ261002C00105000","strike":105,"bid":4,"ask":5,"lastPrice":20},{"contractSymbol":"XYZ261002C00110000","strike":110,"bid":0,"ask":0,"lastPrice":1},{"contractSymbol":"XYZ261002C00115000","strike":115,"bid":6,"ask":5,"lastPrice":5}]"#
        let contracts = try JSONDecoder().decode(YValue.self, from: Data(values.utf8)).array.compactMap(OptionContract.init)
        let args = StockToolArguments(kind: "options", expiration: "", side: "calls", budget: 1000, minStrike: 0, maxStrike: 0)
        let matches = StockResearchTools.filter(contracts, arguments: args, spot: 100)
        #expect(matches.map(\.strike) == [105])
        var narrowed = args
        narrowed.minStrike = 106
        #expect(StockResearchTools.filter(contracts, arguments: narrowed, spot: 100).isEmpty)
    }

    @Test func deepSeekReturnsToolResultsBeforeAnswering() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StockMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let tools = StockResearchTools(symbol: "AAPL", name: "Apple") { _ in }
        let result = try await StockChat().deepSeek(key: "test-only", instructions: "test", history: "", question: "tool loop", research: tools, session: session)
        #expect(result == "Tool result received")
    }

    @Test func deepSeekRejectsTruncatedAnswer() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StockMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let tools = StockResearchTools(symbol: "AAPL", name: "Apple") { _ in }
        await #expect(throws: StockAIError.self) {
            _ = try await StockChat().deepSeek(key: "test-only", instructions: "test", history: "", question: "truncate", research: tools, session: session)
        }
    }

    @Test func retryReusesQuestionAndOriginalContextWithoutDuplicateMessage() async throws {
        var attempts = 0
        var captured: [(String, String, String, String?, String)] = []
        let chat = StockChat { question, symbol, name, price, history in
            attempts += 1
            captured.append((question, symbol, name, price, history))
            if attempts == 1 { throw StockAIError.incomplete }
            return "Recovered answer"
        }
        chat.messages = [StockChatMessage(user: true, text: "Earlier question"), StockChatMessage(user: false, text: "Earlier answer")]
        chat.send("Why did AAPL move?", symbol: "AAPL", name: "Apple", price: "$200")
        try await waitUntil { chat.canRetry }
        #expect(chat.messages.filter(\.user).map(\.text) == ["Earlier question", "Why did AAPL move?"])
        chat.retry()
        try await waitUntil { !chat.busy }
        #expect(attempts == 2)
        #expect(captured.map(\.0) == ["Why did AAPL move?", "Why did AAPL move?"])
        #expect(captured.allSatisfy { $0.1 == "AAPL" && $0.2 == "Apple" && $0.3 == "$200" })
        #expect(captured[0].4 == "User: Earlier question\nAssistant: Earlier answer")
        #expect(captured[1].4 == captured[0].4)
        #expect(chat.messages.filter(\.user).count == 2)
        #expect(chat.messages.last?.text == "Recovered answer")
        #expect(!chat.canRetry)
    }

    @Test func cancelledRequestCannotAppendAfterNewRequest() async throws {
        let chat = StockChat { question, _, _, _, _ in
            if question == "Old request" {
                try await Task.sleep(for: .milliseconds(100))
                return "Stale answer"
            }
            return "Current answer"
        }
        chat.send("Old request", symbol: "", name: "Markets", price: nil)
        chat.cancel()
        chat.send("New request", symbol: "", name: "Markets", price: nil)
        try await waitUntil { !chat.busy }
        #expect(chat.messages.filter { !$0.user }.map(\.text) == ["Current answer"])
        #expect(chat.messages.filter(\.user).map(\.text) == ["Old request", "New request"])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for chat state")
    }

}

nonisolated private final class StockMockProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let messages = json?["messages"] as? [[String: Any]] ?? []
        let last = messages.last ?? [:]
        let content = last["content"] as? String ?? ""
        let response: String
        if content.contains("truncate") {
            response = #"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"Incomplete"}}]}"#
        } else if last["role"] as? String == "tool", last["tool_call_id"] as? String == "call-1", content.contains("Unknown tool") {
            response = #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Tool result received"}}]}"#
        } else {
            response = #"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-1","type":"function","function":{"name":"stock_data","arguments":"{\"kind\":\"unknown\",\"expiration\":\"\",\"side\":\"both\",\"budget\":0,\"minStrike\":0,\"maxStrike\":0}"}}]}}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
