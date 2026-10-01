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
