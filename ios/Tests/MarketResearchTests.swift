import Foundation
import Testing
@testable import Newswire

@MainActor
struct MarketResearchTests {
    @Test func researchErrorsDistinguishAuthorizationTimeoutAndFormat() {
        #expect(researchFailureMessage(WireError.status(403)).contains("authorize"))
        #expect(researchFailureMessage(URLError(.timedOut)).contains("timed out"))
        #expect(researchFailureMessage(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))).contains("unreadable format"))
    }

    @Test func liveLearningIsSeparateFromTheSavedForecast() throws {
        var payload = try #require(JSONSerialization.jsonObject(with: Data(MarketResearchFixture.settledJSON.utf8)) as? [String: Any])
        let live = #"{"symbol":"QQQ","score":38,"status":"available","confidence":"low","as_of":"2026-10-13T18:00:00Z","components":{"news":{"status":"available","points":-4}},"factors":[],"coverage":{"headline_stories":12,"matched_stories":2},"call":{"headline":"Expect a lower session","tone":"negative","strength":2},"learning":{"model":"forecast-adaptive-v1","adjustment":-0.2,"settled":1,"same_horizon":0,"sessions":1,"note":"Learning from one completed forecast."}}"#
        payload["current"] = try JSONSerialization.jsonObject(with: Data(live.utf8))
        let result = try NewswireAPI.decoder().decode(MarketResearchResponse.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(result.current?.score == 38)
        #expect(result.current?.learning?.settled == 1)
        #expect(result.latest?.score == 54.1)
        #expect(result.latest?.tilt == "neutral")
    }

    @Test func evidenceWithoutDatesDoesNotHideTheForecast() throws {
        var payload = try #require(JSONSerialization.jsonObject(with: Data(MarketResearchFixture.settledJSON.utf8)) as? [String: Any])
        var latest = try #require(payload["latest"] as? [String: Any])
        var evidence = try #require(latest["evidence"] as? [[String: Any]])
        evidence[0].removeValue(forKey: "received_at")
        latest["evidence"] = evidence
        payload["latest"] = latest
        let result = try NewswireAPI.decoder().decode(MarketResearchResponse.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(result.latest?.evidence.first?.at == nil)
        #expect(result.latest?.evidence.first?.title == "Overnight futures rise ahead of the open")
        #expect(result.latest?.outcome?.direction == 1)
    }

    @Test func evidenceAcceptsPublishedDriverDate() throws {
        let data = Data(#"{"title":"Energy supply report","source":"Source","url":"https://example.com/evidence","at":"2026-10-13T11:00:00.000Z","reason":"energy"}"#.utf8)
        let result = try NewswireAPI.decoder().decode(MarketResearchResponse.Evidence.self, from: data)
        #expect(result.at != nil)
    }

    @Test func decodesActualCollectingResearchResponseFixture() throws {
        let result = try NewswireAPI.decoder().decode(MarketResearchResponse.self, from: Data(MarketResearchFixture.collectingJSON.utf8))

        #expect(result.symbol == "SPY")
        #expect(result.status == .collecting)
        #expect(result.latest == nil)
        #expect(result.performance.settled == 0)
        #expect(result.performance.horizons["opening_gap"]?.hitRate == nil)
        #expect(result.questions.first?.query == "Does overnight energy strength add useful information to the opening gap forecast?")
        #expect(result.model.probabilities == nil)
        #expect(result.discovery == nil)
    }

    @Test func decodesActualSettledResearchResponseAndNestedForecastEvidence() throws {
        let result = try NewswireAPI.decoder().decode(MarketResearchResponse.self, from: Data(MarketResearchFixture.settledJSON.utf8))

        #expect(result.symbol == "QQQ")
        #expect(result.status == .available)
        #expect(result.latest?.horizon == "opening_gap")
        #expect(result.latest?.probabilityUp == nil)
        #expect(result.latest?.outcome?.direction == 1)
        #expect(result.latest?.outcome?.source == "Yahoo Finance")
        #expect(result.latest?.evidence.first?.id == "https://example.com/evidenceOvernight futures rise ahead of the open")
        #expect(result.latest?.evidence.first?.url.host() == "example.com")
        #expect(result.latest?.evidence.first?.at == Date(timeIntervalSince1970: 1_791_808_200))
        #expect(result.latest?.contradictions.first?.reason == "A conflicting input is retained alongside supporting evidence.")
        #expect(result.performance.horizons["opening_gap"]?.hitRate == 1)
        #expect(result.recent.first?.id == result.latest?.id)
        #expect(result.model.activeCandidate?.version == "ridge-logit-shadow-v1")
        #expect(result.performance.candidateForwardSessions == 8)
        #expect(result.discovery?.status?.health == "partial")
        #expect(result.discovery?.status?.processed == 4)
        #expect(result.discovery?.status?.findings == 2)
        #expect(result.discovery?.status?.questionsAttempted == 3)
        #expect(result.discovery?.status?.failures == ["One source timed out"])
        #expect(result.discovery?.findings.first?.originalUrl.host() == "example.com")
        #expect(result.discovery?.attempts.first?.status == "completed")
    }
}
