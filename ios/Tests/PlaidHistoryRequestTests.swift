import Foundation
import Testing
@testable import Newswire

struct PlaidHistoryRequestTests {
    private func client(_ scenario: String) -> PlaidClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaidHistoryProtocol.self]
        return PlaidClient(credentials: .init(clientID: scenario, secret: "test-only", environment: .sandbox), session: URLSession(configuration: configuration))
    }

    @Test func paginatedHistoryIncludesFullySoldSecuritiesAndSoFiCash() async throws {
        let client = client("pages")
        defer { client.session.invalidateAndCancel() }
        let item = PlaidItem(id: "item", accessToken: "test-only", institution: "SoFi", environment: .sandbox)
        let history = try await client.transactions(item)
        #expect(history.transactions.count == 2)
        #expect(history.transactions.last?.type == "sell")
        #expect(history.transactions.last?.securityId == "closed")
        #expect(history.securities?.contains { $0.securityId == "closed" && $0.tickerSymbol == "SOLD" } == true)
        #expect(history.cashSecurityIDs == ["usd"])
    }

    @Test func emptyPageCannotBeMistakenForCompleteHistory() async throws {
        let client = client("incomplete")
        defer { client.session.invalidateAndCancel() }
        let item = PlaidItem(id: "item", accessToken: "test-only", institution: "SoFi", environment: .sandbox)
        do {
            _ = try await client.transactions(item)
            Issue.record("An incomplete response was accepted as full history")
        } catch let error as PlaidError {
            #expect(error.code == "INCOMPLETE_HISTORY")
        }
    }
}

nonisolated private final class PlaidHistoryProtocol: URLProtocol, @unchecked Sendable {
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
        guard request.httpMethod == "POST", request.url?.path == "/investments/transactions/get",
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let options = json["options"] as? [String: Any], options["count"] as? Int == 500,
              Set(options.keys) == ["count", "offset"],
              let offset = options["offset"] as? Int, [0, 1].contains(offset),
              let start = json["start_date"] as? String, let end = json["end_date"] as? String,
              let startYear = Int(start.prefix(4)), let endYear = Int(end.prefix(4)), endYear - startYear == 2 else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response: String
        if offset == 0 {
            response = #"{"investment_transactions":[{"account_id":"a","security_id":"current","type":"buy","quantity":1,"amount":100,"date":"2026-01-03"}],"total_investment_transactions":2,"securities":[{"security_id":"current","ticker_symbol":"AAA","type":"equity"},{"security_id":"usd","ticker_symbol":"CUR:USD","type":"cash"}]}"#
        } else if json["client_id"] as? String == "incomplete" {
            response = #"{"investment_transactions":[],"total_investment_transactions":2,"securities":[]}"#
        } else {
            response = #"{"investment_transactions":[{"account_id":"a","security_id":"closed","type":"sell","quantity":-10,"amount":-1200,"date":"2026-01-02"}],"total_investment_transactions":2,"securities":[{"security_id":"closed","ticker_symbol":"SOLD","type":"equity"}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
