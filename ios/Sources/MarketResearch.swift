import Foundation
import SwiftUI

nonisolated struct MarketResearchResponse: Decodable, Sendable {
    let symbol: String
    let status: Status
    let summary: String
    let latest: Forecast?
    let performance: Performance
    let recent: [Forecast]
    let questions: [Question]
    let model: Model
    let discovery: Discovery?
    let current: MarketPulse?
    private let agentPayload: Lenient<Agent>?
    var agent: Agent? { agentPayload?.value }

    enum CodingKeys: String, CodingKey {
        case symbol, status, summary, latest, performance, recent, questions, model, discovery, current
        case agentPayload = "agent"
    }

    /// The agent block is newer than the rest of the response; a malformed field there shouldn't hide saved forecasts.
    nonisolated struct Lenient<Value: Decodable & Sendable>: Decodable, Sendable {
        let value: Value?
        nonisolated init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    enum Status: String, Decodable, Sendable {
        case collecting, limited, available
    }

    nonisolated struct Forecast: Decodable, Sendable, Identifiable {
        enum CodingKeys: String, CodingKey {
            case id, symbol, sessionDate, horizon, forecastAt, targetStartAt, targetEndAt
            case modelVersion, inputVersion, score, tilt, probabilityUp, outcome, evidence, contradictions
        }

        let id: String
        let symbol: String
        let sessionDate: String
        let horizon: String
        let forecastAt: Date
        let targetStartAt: Date
        let targetEndAt: Date
        let modelVersion: String
        let inputVersion: String
        let score: Double?
        let tilt: String
        let probabilityUp: Double?
        let outcome: Outcome?
        let evidence: [Evidence]
        let contradictions: [Evidence]

        nonisolated init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            symbol = try values.decode(String.self, forKey: .symbol)
            sessionDate = try values.decode(String.self, forKey: .sessionDate)
            horizon = try values.decode(String.self, forKey: .horizon)
            forecastAt = try values.decode(Date.self, forKey: .forecastAt)
            targetStartAt = try values.decode(Date.self, forKey: .targetStartAt)
            targetEndAt = try values.decode(Date.self, forKey: .targetEndAt)
            modelVersion = try values.decode(String.self, forKey: .modelVersion)
            inputVersion = try values.decode(String.self, forKey: .inputVersion)
            score = try values.decodeIfPresent(Double.self, forKey: .score)
            tilt = try values.decode(String.self, forKey: .tilt)
            probabilityUp = try values.decodeIfPresent(Double.self, forKey: .probabilityUp)
            outcome = try values.decodeIfPresent(Outcome.self, forKey: .outcome)
            evidence = try values.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
            contradictions = try values.decodeIfPresent([Evidence].self, forKey: .contradictions) ?? []
        }
    }

    nonisolated struct Outcome: Decodable, Sendable {
        let baselinePrice: Double
        let baselineAt: Date
        let endpointPrice: Double
        let endpointAt: Date
        let returnPct: Double
        let direction: Int
        let source: String
        let sourceRetrievedAt: Date

    }

    nonisolated struct Evidence: Decodable, Sendable, Identifiable {
        let id: String
        let title: String
        let source: String
        let url: URL
        let at: Date?
        let reason: String

        nonisolated enum CodingKeys: String, CodingKey {
            case id, title, source, url, at, receivedAt, reason
        }

        nonisolated init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try values.decode(String.self, forKey: .title)
            source = try values.decode(String.self, forKey: .source)
            url = try values.decode(URL.self, forKey: .url)
            if let currentAt = try values.decodeIfPresent(Date.self, forKey: .at) {
                at = currentAt
            } else {
                at = try values.decodeIfPresent(Date.self, forKey: .receivedAt)
            }
            id = try values.decodeIfPresent(String.self, forKey: .id) ?? url.absoluteString + title
            reason = try values.decode(String.self, forKey: .reason)
        }
    }

    nonisolated struct Performance: Decodable, Sendable {
        let settled: Int
        let horizons: [String: HorizonPerformance]
        let probabilityMetrics: JSONValue?
        let candidateStatus: String
        let candidate: JSONValue?

        var candidateForwardSessions: Int? {
            guard case .object(let candidate)? = candidate,
                  case .object(let forward)? = candidate["forward"],
                  case .number(let sessions)? = forward["sessions"] else { return nil }
            return Int(sessions)
        }
    }

    nonisolated struct HorizonPerformance: Decodable, Sendable {
        let count: Int
        let scored: Int
        let hitRate: Double?
        let meanReturnPct: Double?
        let tiltReturnPct: Double?
        let baseRateUp: Double?
        let majorityBaselineHitRate: Double?
        let priceOnlyBaseline: String

    }

    nonisolated struct Question: Decodable, Sendable, Identifiable {
        let id: String
        let query: String
        let reason: String
        let status: String
        let createdAt: Date
        let eventId: String?
    }

    nonisolated struct Discovery: Decodable, Sendable {
        let status: RunStatus?
        let findings: [Finding]
        let attempts: [Attempt]
        let questions: [Question]
    }

    nonisolated struct RunStatus: Decodable, Sendable {
        let health: String
        let status: String
        let recordedAt: Date
        let processed: Int
        let findings: Int
        let questionsAttempted: Int
        let failures: [String]
    }

    nonisolated struct Finding: Decodable, Sendable, Identifiable {
        let id: String
        let originalUrl: URL
        let title: String
        let firstDiscoveredAt: Date
        let questionIds: [String]
    }

    nonisolated struct Attempt: Decodable, Sendable, Identifiable {
        var id: String { "\(questionId)-\(attemptedAt.timeIntervalSince1970)" }
        let questionId: String
        let status: String
        let attemptedAt: Date
    }

    nonisolated struct Agent: Decodable, Sendable {
        let performance: AgentPerformance
        let predictions: [Prediction]
        let board: [BoardRow]
        let questions: [QuestionGroup]
    }

    nonisolated struct AgentPerformance: Decodable, Sendable {
        let overall: AgentScore
        let horizons: [String: AgentScore]
    }

    nonisolated struct AgentScore: Decodable, Sendable {
        let count: Int
        let settled: Int
        let scored: Int
        let hitRate: Double?
        let alwaysUpHitRate: Double?
        let brier: Double?
        let signalReturnPct: Double?
    }

    nonisolated struct Prediction: Decodable, Sendable, Identifiable {
        let id: String
        let symbol: String
        let window: String
        let horizon: String
        let madeAt: Date
        let targetEndAt: Date
        let probabilityUp: Double
        let direction: Int
        let expectedMovePct: Double
        let rationale: String
        let drivers: [String]
        let sources: [Source]
        let outcome: PredictionOutcome?
    }

    nonisolated struct PredictionOutcome: Decodable, Sendable {
        let returnPct: Double
        let direction: Int
    }

    nonisolated struct Source: Decodable, Sendable, Identifiable {
        var id: String { url }
        let title: String
        let url: String
        let publisher: String?
        var link: URL? { URL(string: url) }
    }

    nonisolated struct BoardRow: Decodable, Sendable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let predictions: [Prediction]
    }

    nonisolated struct QuestionGroup: Decodable, Sendable, Identifiable {
        let id: String
        let query: String
        let reason: String
        let status: String
        let createdAt: Date
        let event: Event?
        let answer: Answer?
    }

    nonisolated struct Event: Decodable, Sendable {
        let title: String
        let source: String?
    }

    nonisolated struct Answer: Decodable, Sendable {
        let question: String
        let verdict: String
        let answer: String
        let marketEffect: String
        let sources: [Source]
        let answeredAt: Date
    }

    nonisolated struct Model: Decodable, Sendable {
        let version: String
        let horizons: [String]
        let symbols: [String]
        let probabilities: String?
        let candidate: JSONValue?
        let activeCandidate: ActiveCandidate?
    }

    nonisolated struct ActiveCandidate: Decodable, Sendable {
        let version: String
        let promotedAt: Date?
    }

    nonisolated enum JSONValue: Decodable, Sendable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Double)
        case bool(Bool)

        nonisolated init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .object([:]) }
            else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
            else if let number = try? value.decode(Double.self) { self = .number(number) }
            else if let string = try? value.decode(String.self) { self = .string(string) }
            else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
            else { self = .object(try value.decode([String: JSONValue].self)) }
        }
    }
}

extension NewswireAPI {
    @concurrent func marketResearch(symbol: String) async throws -> MarketResearchResponse {
        var components = URLComponents(url: baseURL.appending(path: "v1/research"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        guard let url = components?.url else { throw WireError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw WireError.status(response.statusCode) }
        return try Self.decoder().decode(MarketResearchResponse.self, from: data)
    }
}

#if DEBUG
enum MarketResearchFixture: String {
    case collecting, settled, error

    static var launch: MarketResearchFixture? {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--research-fixture=") }) else { return nil }
        return MarketResearchFixture(rawValue: String(argument.dropFirst("--research-fixture=".count)))
    }

    var payload: MarketResearchResponse? {
        switch self {
        case .collecting: Self.decode(Self.collectingJSON)
        case .settled: Self.decode(Self.settledJSON)
        case .error: nil
        }
    }

    private static func decode(_ json: String) -> MarketResearchResponse? {
        try? NewswireAPI.decoder().decode(MarketResearchResponse.self, from: Data(json.utf8))
    }
    static let collectingJSON = #"{"symbol":"SPY","status":"collecting","summary":"Collecting frozen forecasts; no probability estimate is validated.","latest":null,"performance":{"settled":0,"horizons":{"opening_gap":{"count":0,"scored":0,"hit_rate":null,"mean_return_pct":null,"tilt_return_pct":null,"base_rate_up":null,"majority_baseline_hit_rate":null,"price_only_baseline":"majority historical direction"},"cutoff_to_open":{"count":0,"scored":0,"hit_rate":null,"mean_return_pct":null,"tilt_return_pct":null,"base_rate_up":null,"majority_baseline_hit_rate":null,"price_only_baseline":"majority historical direction"},"open_to_close":{"count":0,"scored":0,"hit_rate":null,"mean_return_pct":null,"tilt_return_pct":null,"base_rate_up":null,"majority_baseline_hit_rate":null,"price_only_baseline":"majority historical direction"}},"probability_metrics":null,"candidate_status":"shadow only","candidate":null},"recent":[],"questions":[{"id":"q-1","query":"Does overnight energy strength add useful information to the opening gap forecast?","reason":"There are no settled forecasts yet.","status":"open","created_at":"2026-10-12T14:00:00Z","event_id":null}],"model":{"version":"forecast-tilt-v1","horizons":["opening_gap","cutoff_to_open","open_to_close"],"symbols":["SPY","QQQ"],"probabilities":null,"candidate":{"version":"ridge-logit-shadow-v1","minimumTrainSessions":180},"active_candidate":null}}"#
    private static let settledBaseJSON = #"{"symbol":"QQQ","status":"available","summary":"neutral research tilt; experimental and uncalibrated","latest":{"id":"QQQ_2026-10-12_opening_gap","symbol":"QQQ","session_date":"2026-10-12","horizon":"opening_gap","forecast_at":"2026-10-12T13:00:00Z","target_start_at":"2026-10-12T13:00:00Z","target_end_at":"2026-10-12T14:00:00Z","model_version":"forecast-tilt-v1","input_version":"market-pulse-v2.1","score":54.1,"tilt":"neutral","probability_up":null,"evidence":[{"title":"Overnight futures rise ahead of the open","source":"Newswire","url":"https://example.com/evidence","reason":"A market input supported the recorded index.","received_at":"2026-10-12T12:30:00Z"}],"contradictions":[{"title":"Trading volume remains below average","source":"Newswire","url":"https://example.com/contradiction","reason":"A conflicting input is retained alongside supporting evidence.","received_at":"2026-10-12T12:35:00Z"}],"outcome":{"baseline_price":500,"baseline_at":"2026-10-12T13:00:00Z","endpoint_price":502.1,"endpoint_at":"2026-10-12T14:00:00Z","return_pct":0.42,"direction":1,"source":"Yahoo Finance","source_retrieved_at":"2026-10-12T14:05:00Z"},"created_at":"2026-10-12T13:00:00Z"},"performance":{"settled":1,"horizons":{"opening_gap":{"count":1,"scored":1,"hit_rate":1,"mean_return_pct":0.42,"tilt_return_pct":0,"base_rate_up":1,"majority_baseline_hit_rate":1,"price_only_baseline":"frozen sign of market-only pulse points at capture","price_only_baseline_hit_rate":null,"majority_baseline":"prior-session majority direction; at least 20 earlier outcomes; evaluated only on the same covered outcomes"},"cutoff_to_open":{"count":0,"scored":0,"hit_rate":null,"mean_return_pct":null,"tilt_return_pct":null,"base_rate_up":null,"majority_baseline_hit_rate":null,"price_only_baseline":"frozen sign of market-only pulse points at capture","price_only_baseline_hit_rate":null,"majority_baseline":"prior-session majority direction; at least 20 earlier outcomes; evaluated only on the same covered outcomes"},"open_to_close":{"count":0,"scored":0,"hit_rate":null,"mean_return_pct":null,"tilt_return_pct":null,"base_rate_up":null,"majority_baseline_hit_rate":null,"price_only_baseline":"frozen sign of market-only pulse points at capture","price_only_baseline_hit_rate":null,"majority_baseline":"prior-session majority direction; at least 20 earlier outcomes; evaluated only on the same covered outcomes"}},"probability_metrics":null,"candidate_status":"promoted","candidate":{"forward":{"predictions":12,"sessions":8,"brier":0.21,"baseline_brier":0.24,"bins":[]}}},"recent":[{"id":"QQQ_2026-10-12_opening_gap","symbol":"QQQ","session_date":"2026-10-12","horizon":"opening_gap","forecast_at":"2026-10-12T13:00:00Z","target_start_at":"2026-10-12T13:00:00Z","target_end_at":"2026-10-12T14:00:00Z","model_version":"forecast-tilt-v1","input_version":"market-pulse-v2.1","score":54.1,"tilt":"neutral","probability_up":null,"evidence":[],"contradictions":[],"outcome":{"baseline_price":500,"baseline_at":"2026-10-12T13:00:00Z","endpoint_price":502.1,"endpoint_at":"2026-10-12T14:00:00Z","return_pct":0.42,"direction":1,"source":"Yahoo Finance","source_retrieved_at":"2026-10-12T14:05:00Z"},"created_at":"2026-10-12T13:00:00Z"}],"questions":[],"model":{"version":"forecast-tilt-v1","horizons":["opening_gap","cutoff_to_open","open_to_close"],"symbols":["SPY","QQQ"],"probabilities":null,"candidate":{"version":"ridge-logit-shadow-v1"},"active_candidate":{"version":"ridge-logit-shadow-v1","promoted_at":"2026-10-12T14:00:00Z"}},"discovery":{"status":{"health":"partial","status":"completed","recorded_at":"2026-10-12T14:10:00Z","processed":4,"findings":2,"questions_attempted":3,"failures":["One source timed out"]},"findings":[{"id":"finding-1","original_url":"https://example.com/research","title":"A follow-up market report","first_discovered_at":"2026-10-12T14:08:00Z","question_ids":["q-1"]}],"attempts":[{"question_id":"q-1","status":"completed","attempted_at":"2026-10-12T14:07:00Z","attempts":1,"search_role":"confirm"}],"questions":[]}}"#
    static let settledJSON = String(settledBaseJSON.dropLast()) + #","agent":"# + agentJSON + "}"
    private static let agentJSON = #"{"performance":{"overall":{"count":14,"settled":12,"scored":11,"hit_rate":0.64,"always_up_hit_rate":0.45,"brier":0.231,"coin_flip_brier":0.25,"signal_return_pct":0.12,"move_error_pct":0.41},"horizons":{"to_open":{"count":6,"settled":5,"scored":5,"hit_rate":0.8,"always_up_hit_rate":0.4,"brier":0.205,"coin_flip_brier":0.25,"signal_return_pct":0.21,"move_error_pct":0.3},"to_close":{"count":4,"settled":4,"scored":3,"hit_rate":0.33,"always_up_hit_rate":0.5,"brier":0.262,"coin_flip_brier":0.25,"signal_return_pct":-0.05,"move_error_pct":0.6},"next_close":{"count":4,"settled":3,"scored":3,"hit_rate":0.67,"always_up_hit_rate":0.33,"brier":0.24,"coin_flip_brier":0.25,"signal_return_pct":0.2,"move_error_pct":0.5}}},"predictions":[],"board":[{"symbol":"SPY","predictions":[{"id":"SPY_2026-10-14_late_to_open","symbol":"SPY","window":"late","horizon":"to_open","made_at":"2026-10-14T19:41:00.000Z","target_session":"2026-10-15","target_end_at":"2026-10-15T13:30:00.000Z","baseline_price":769.6,"baseline_at":"2026-10-14T19:40:00.000Z","probability_up":0.38,"direction":-1,"expected_move_pct":-0.25,"rationale":"[TEST] Futures are slipping after a hotter core CPI print and Fed speakers pushed back on a December cut. Bank earnings before the open are the main upside risk.","drivers":["Core CPI above consensus","Fed odds of a December cut fell","10-year yield up 6 bp"],"sources":[{"title":"Consumer Price Index summary","url":"https://www.bls.gov/news.release/cpi.nr0.htm","publisher":"BLS"},{"title":"Fed funds futures","url":"https://www.cmegroup.com/markets/interest-rates.html","publisher":"CME"}],"model":"deepseek-v4-pro","outcome":null},{"id":"SPY_2026-10-14_late_next_close","symbol":"SPY","window":"late","horizon":"next_close","made_at":"2026-10-14T19:41:00.000Z","target_session":"2026-10-15","target_end_at":"2026-10-15T20:00:00.000Z","baseline_price":769.6,"baseline_at":"2026-10-14T19:40:00.000Z","probability_up":0.46,"direction":-1,"expected_move_pct":-0.15,"rationale":"[TEST] Rates pressure likely persists into Thursday, but strong bank results could offset it by the close.","drivers":["Rates pressure","Bank earnings"],"sources":[],"model":"deepseek-v4-pro","outcome":null}]},{"symbol":"QQQ","predictions":[{"id":"QQQ_2026-10-14_late_to_open","symbol":"QQQ","window":"late","horizon":"to_open","made_at":"2026-10-14T19:41:00.000Z","target_session":"2026-10-15","target_end_at":"2026-10-15T13:30:00.000Z","baseline_price":610.2,"baseline_at":"2026-10-14T19:40:00.000Z","probability_up":0.36,"direction":-1,"expected_move_pct":-0.35,"rationale":"[TEST] Long-duration tech is most exposed to higher yields.","drivers":["Higher yields"],"sources":[],"model":"deepseek-v4-pro","outcome":null},{"id":"QQQ_2026-10-14_late_next_close","symbol":"QQQ","window":"late","horizon":"next_close","made_at":"2026-10-14T19:41:00.000Z","target_session":"2026-10-15","target_end_at":"2026-10-15T20:00:00.000Z","baseline_price":610.2,"baseline_at":"2026-10-14T19:40:00.000Z","probability_up":0.52,"direction":1,"expected_move_pct":0.1,"rationale":"[TEST] TSMC results after the open could lift semiconductors.","drivers":["TSMC earnings"],"sources":[],"model":"deepseek-v4-pro","outcome":null}]},{"symbol":"IWM","predictions":[{"id":"IWM_2026-10-14_premarket_to_open","symbol":"IWM","window":"premarket","horizon":"to_open","made_at":"2026-10-14T12:50:00.000Z","target_session":"2026-10-14","target_end_at":"2026-10-14T13:30:00.000Z","baseline_price":241.1,"baseline_at":"2026-10-14T12:45:00.000Z","probability_up":0.41,"direction":-1,"expected_move_pct":-0.3,"rationale":"[TEST] Small caps are most rate-sensitive.","drivers":[],"sources":[],"model":"deepseek-v4-pro","outcome":{"endpoint_price":240.2,"endpoint_at":"2026-10-14T13:30:00.000Z","return_pct":-0.37,"direction":-1,"source":"https://query1.finance.yahoo.com/v8/finance/chart/IWM"}}]}],"questions":[{"id":"rd_1","question_ids":["rd_1","rd_2"],"query":"riyadh explosion missile oil facilities (official OR statement)","reason":"Pending independent confirmation of the energy report; search results do not establish truth.","status":"answered","created_at":"2026-10-14T16:00:00.000Z","event_id":"abc","event":{"title":"IRNA: An explosion in Riyadh after a missile attack and reports of damage to oil facilities","url":"https://example.com/irna","source":"IRNA"},"answer":{"question":"Did a missile attack damage Saudi oil facilities near Riyadh?","verdict":"contradicted","answer":"[TEST] Saudi state media said air defenses intercepted the missile and no oil facilities were damaged; Aramco reported normal operations. Only Iranian state media carried the damage claim.","market_effect":"none","channel":"energy","confidence":0.7,"sources":[{"title":"Saudi Press Agency statement","url":"https://www.spa.gov.sa/en","publisher":"SPA"}],"answered_at":"2026-10-14T16:20:00.000Z","model":"deepseek-v4.1-flash"}},{"id":"rd_3","question_ids":["rd_3","rd_4"],"query":"sa analyst stagflationary recession risk growing (official OR statement)","reason":"Pending independent confirmation of the growth report; search results do not establish truth.","status":"open","created_at":"2026-10-14T21:00:00.000Z","event_id":"def","event":{"title":"Analyst: stagflationary recession risk is growing","url":"https://example.com/sa","source":"Seeking Alpha"},"answer":null}]}"#
}
#endif

nonisolated func researchFailureMessage(_ error: Error) -> String {
    if error is DecodingError { return "The server returned research in an unreadable format. Try refreshing again." }
    if let error = error as? URLError {
        if error.code == .timedOut { return "Loading research timed out. Try again." }
        return "Research couldn't connect to the server. \(error.localizedDescription)"
    }
    if let error = error as? WireError, case .status(let code) = error {
        if code == 401 || code == 403 { return "The server couldn't authorize this device to load research (\(code)). Try again." }
        return "Research couldn't be loaded from the server (\(code)). Try again."
    }
    return error.localizedDescription
}

struct MarketResearchView: View {
    @AppStorage("researchSymbol") private var symbol = "SPY"
    @Environment(\.scenePhase) private var phase
    @State private var response: MarketResearchResponse?
    @State private var isLoading = false
    @State private var failed = false
    @State private var failureMessage = "Saved forecasts couldn't be loaded. Try again."
    @State private var loadedAt: Date?
    @State private var loadedSymbol: String?

    private var fixture: String? {
        #if DEBUG
        MarketResearchFixture.launch?.rawValue
        #else
        nil
        #endif
    }

    private var isStale: Bool { response?.latest.map { Date.now.timeIntervalSince($0.forecastAt) > 24 * 60 * 60 } ?? false }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    Picker("Market", selection: $symbol) {
                        Text("S&P 500 · SPY").tag("SPY")
                        Text("Nasdaq 100 · QQQ").tag("QQQ")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if let response, response.symbol == symbol {
                    #if DEBUG
                    if fixture != nil {
                        Section { Label("Sample API response · not live data", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
                    }
                    #endif
                    if failed { Section { Label("Refresh failed · showing the last saved research", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.subheadline).foregroundStyle(.secondary) } }
                    if isStale { Section { Label("Latest forecast is over a day old.", systemImage: "clock.arrow.circlepath").font(.subheadline).foregroundStyle(.secondary) } }
                    if let current = response.current { liveOverview(current) }
                    if let agent = response.agent {
                        agentForecast(agent)
                        if let row = agent.board.first(where: { $0.symbol == response.symbol }) { agentReasoning(row).id("why") }
                        agentTrackRecord(agent.performance, symbol: response.symbol).id("track")
                    }
                    overview(response)
                    performanceSection(response.performance)
                    discoverySection(response.discovery)
                    if !response.recent.isEmpty { recentSection(response.recent) }
                    if let questions = response.agent?.questions, !questions.isEmpty { agentQuestionsSection(questions).id("questions") }
                    else if !response.questions.isEmpty { questionsSection(response.questions) }
                } else if failed {
                    ContentUnavailableView {
                        Label("Research unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failureMessage)
                    } actions: {
                        Button("Retry") { Task { await refresh() } }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(isLoading ? "Loading saved research…" : "Collecting forecasts…").foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 56)
                    }
                }
            }
            #if DEBUG
            .task {
                guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--research-scroll=") }) else { return }
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo(String(argument.dropFirst("--research-scroll=".count)), anchor: .top)
            }
            #endif
            }
            .navigationTitle("Research")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh(force: true) } } label: {
                        if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh research")
                }
            }
            .refreshable { await refresh(force: true) }
            .task(id: "\(symbol)-\(phase == .active)") {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await refresh()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private func liveOverview(_ pulse: MarketPulse) -> some View {
        Section("Right now · \(pulse.symbol)") {
            VStack(alignment: .leading, spacing: 12) {
                Label(pulse.call?.headline ?? "Outlook unavailable", systemImage: pulse.arrow)
                    .font(.title2.weight(.semibold)).foregroundStyle(pulse.tint)
                if let summary = pulse.summary { Text(summary).font(.subheadline) }
                Text("Updated \(pulse.asOf.formatted(date: .omitted, time: .shortened)) · refreshes every minute")
                    .font(.caption).foregroundStyle(.secondary)
                if let learning = pulse.learning {
                    Text(learning.note).font(.caption).foregroundStyle(.secondary)
                }
                Text("This reading can change as prices and news change. The saved forecast below stays unchanged for comparison.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func agentForecast(_ agent: MarketResearchResponse.Agent) -> some View {
        Section {
            if agent.board.isEmpty {
                Label("The first AI forecast is made 8:40–9:25 AM or 3:30–3:55 PM Eastern on a trading day.", systemImage: "clock")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(agent.board) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.symbol).font(.headline)
                        Text(indexName(row.symbol)).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(row.predictions) { predictionLine($0) }
                }
                .padding(.vertical, 4)
            }
        } header: {
            if let made = agent.board.flatMap(\.predictions).map(\.madeAt).max() {
                Text("AI forecast · \(made.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
            } else {
                Text("AI forecast")
            }
        } footer: {
            Text("DeepSeek researches headlines, market data and the web, then commits to each call before its target time. Every call is scored against actual prices. Not investment advice.")
        }
    }

    private func predictionLine(_ prediction: MarketResearchResponse.Prediction) -> some View {
        HStack(spacing: 8) {
            Image(systemName: prediction.direction > 0 ? "arrow.up.right" : prediction.direction < 0 ? "arrow.down.right" : "arrow.right")
                .font(.subheadline.weight(.semibold)).foregroundStyle(tint(prediction.direction)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(target(prediction)).font(.subheadline)
                if let outcome = prediction.outcome {
                    let hit = prediction.direction != 0 && outcome.direction == prediction.direction
                    inline("Actual \(signedPercent(outcome.returnPct))", systemImage: hit ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.caption.monospacedDigit()).foregroundStyle(hit ? Color.green : Color.secondary)
                        .accessibilityLabel("Actual \(signedPercent(outcome.returnPct)), \(hit ? "correct" : "missed")")
                }
            }
            Spacer(minLength: 4)
            Text(odds(prediction)).font(.subheadline.monospacedDigit().weight(.medium))
            Text(signedPercent(prediction.expectedMovePct)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .trailing)
        }
    }

    private func agentReasoning(_ row: MarketResearchResponse.BoardRow) -> some View {
        Section("Why · \(row.symbol)") {
            ForEach(row.predictions) { prediction in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(target(prediction)) · \(odds(prediction))").font(.subheadline.weight(.semibold))
                    Text(prediction.rationale).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    if !prediction.drivers.isEmpty {
                        Text(prediction.drivers.map { "• \($0)" }.joined(separator: "\n"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    sourceLinks(prediction.sources)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func agentTrackRecord(_ performance: MarketResearchResponse.AgentPerformance, symbol: String) -> some View {
        Section {
            let overall = performance.overall
            if overall.settled == 0 {
                Text(overall.count == 0 ? "No AI calls yet." : "\(overall.count) call\(overall.count == 1 ? "" : "s") waiting for prices to settle.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("\(overall.settled) settled call\(overall.settled == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                scoreRow(overall)
                ForEach(["to_open", "to_close", "next_close"], id: \.self) { horizon in
                    if let score = performance.horizons[horizon], score.settled > 0 {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(agentHorizon(horizon)).font(.subheadline.weight(.medium))
                            scoreRow(score)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } header: { Text("AI track record · \(symbol)") }
        footer: { Text("Brier score: lower is better and 0.25 is a coin flip. A real edge needs dozens of settled calls before it means much.") }
    }

    private func scoreRow(_ score: MarketResearchResponse.AgentScore) -> some View {
        HStack(spacing: 14) {
            if let rate = score.hitRate { metric("Hits", rate.formatted(.percent.precision(.fractionLength(0)))) }
            if let up = score.alwaysUpHitRate { metric("Always-up", up.formatted(.percent.precision(.fractionLength(0)))) }
            if let brier = score.brier { metric("Brier", brier.formatted(.number.precision(.fractionLength(3)))) }
            if let signal = score.signalReturnPct { metric("Signal return", signedPercent(signal)) }
        }
    }

    private func sourceLinks(_ sources: [MarketResearchResponse.Source]) -> some View {
        ForEach(sources.prefix(3)) { source in
            if let url = source.link {
                Link(destination: url) {
                    inline(source.publisher.map { "\($0): \(source.title)" } ?? source.title, systemImage: "link")
                        .font(.caption).lineLimit(1)
                }
            }
        }
    }

    private func agentQuestionsSection(_ items: [MarketResearchResponse.QuestionGroup]) -> some View {
        Section("Research questions") {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.answer?.question ?? item.event?.title ?? item.query).font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let answer = item.answer {
                        inline("\(verdict(answer.verdict)) · \(effect(answer.marketEffect))", systemImage: answer.verdict == "confirmed" ? "checkmark.seal" : answer.verdict == "contradicted" ? "xmark.seal" : "questionmark.circle")
                            .font(.caption.weight(.medium)).foregroundStyle(answer.verdict == "unresolved" ? Color.secondary : Color.primary)
                        Text(answer.answer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        sourceLinks(answer.sources)
                        Text("Answered \(answer.answeredAt.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Text(item.event?.source.map { "Reported by \($0)" } ?? item.reason).font(.caption).foregroundStyle(.secondary)
                        Text("Researching · \(item.createdAt.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func inline(_ title: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
    }

    private func target(_ prediction: MarketResearchResponse.Prediction) -> String {
        let day = prediction.targetEndAt.formatted(.dateTime.weekday(.abbreviated))
        return prediction.horizon == "to_open" ? "\(day) open" : "\(day) close"
    }

    private func odds(_ prediction: MarketResearchResponse.Prediction) -> String {
        let up = Int((prediction.probabilityUp * 100).rounded())
        return prediction.direction > 0 ? "\(up)% higher" : prediction.direction < 0 ? "\(100 - up)% lower" : "50/50"
    }

    private func tint(_ direction: Int) -> Color { direction > 0 ? .green : direction < 0 ? .red : .secondary }

    private func indexName(_ symbol: String) -> String {
        switch symbol {
        case "SPY": "S&P 500"
        case "QQQ": "Nasdaq 100"
        case "IWM": "Russell 2000"
        case "DIA": "Dow"
        default: ""
        }
    }

    private func agentHorizon(_ value: String) -> String {
        switch value {
        case "to_open": "To the open"
        case "to_close": "To the close"
        default: "One day out"
        }
    }

    private func verdict(_ value: String) -> String {
        switch value {
        case "confirmed": "Confirmed"
        case "contradicted": "Contradicted"
        default: "Unresolved"
        }
    }

    private func effect(_ value: String) -> String {
        switch value {
        case "lower": "points lower"
        case "higher": "points higher"
        case "none": "no market effect"
        default: "effect unclear"
        }
    }

    private func overview(_ item: MarketResearchResponse) -> some View {
        Section("Saved forecast · \(item.symbol)") {
            if let latest = item.latest {
                HStack(alignment: .firstTextBaseline) {
                    Text(direction(latest.tilt)).font(.title2.weight(.semibold))
                    Spacer()
                    if let score = latest.score {
                        Text(score.formatted(.number.precision(.fractionLength(1))))
                            .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("index").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(display(latest.horizon)) · target \(latest.sessionDate)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Saved \(latest.forecastAt.formatted(.relative(presentation: .named))) · \(latest.modelVersion)")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Label("No frozen forecast saved yet", systemImage: "hourglass")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text(item.latest == nil ? "Forecasts will be saved before the open and near the close, then checked against what prices actually did." : "This view keeps the original forecast so we can compare it with the market's later move.")
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Label(item.status == .available ? "Forecast available · uncalibrated" : item.status == .limited ? "Limited inputs" : "Collecting evidence", systemImage: item.status == .available ? "waveform.path.ecg" : "hourglass")
                .font(.caption).foregroundStyle(.secondary)
            Text("Still being tested. The index isn't a percentage chance of prices rising.")
                .font(.caption).foregroundStyle(.secondary)
            if let latest = item.latest {
                if !latest.evidence.isEmpty { forecastEvidence("Why", items: latest.evidence) }
                if !latest.contradictions.isEmpty { forecastEvidence("What points the other way", items: latest.contradictions) }
            }
        }
    }

    private func performanceSection(_ item: MarketResearchResponse.Performance) -> some View {
        Section {
            HStack {
                Text("\(item.settled) settled forecast\(item.settled == 1 ? "" : "s") · model \(item.candidateStatus)")
                Spacer(minLength: 4)
                if let sessions = item.candidateForwardSessions {
                    Text("Candidate: \(sessions) forward sessions").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            ForEach(["opening_gap", "cutoff_to_open", "open_to_close"], id: \.self) { horizon in
                if let result = item.horizons[horizon] { horizonRow(horizon, result) }
            }
        } header: { Text("Measured performance") }
        footer: { Text("Rates below are measured from saved outcomes for each horizon. They are not calibrated probabilities or expected returns.") }
    }

    private func discoverySection(_ item: MarketResearchResponse.Discovery?) -> some View {
        Section("Source discovery") {
            if let item, let status = item.status {
                Text("Last run \(status.recordedAt.formatted(.relative(presentation: .named)))")
                    .font(.subheadline.weight(.medium))
                Text("\(status.health.capitalized) · \(status.processed) processed · \(status.findings) findings · \(status.questionsAttempted) questions attempted")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(item.findings.prefix(3)) { finding in
                    Link(destination: finding.originalUrl) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(finding.title).font(.subheadline).multilineTextAlignment(.leading)
                            Text("Found \(finding.firstDiscoveredAt.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !status.failures.isEmpty {
                    ForEach(Array(status.failures.prefix(3).enumerated()), id: \.offset) { _, failure in
                        Label(failure, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } else {
                Label("Collecting source-discovery runs; none recorded yet.", systemImage: "hourglass")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func horizonRow(_ horizon: String, _ result: MarketResearchResponse.HorizonPerformance) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(display(horizon)).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(result.scored) scored / \(result.count) settled").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                if let rate = result.hitRate { metric("Directional hits", rate.formatted(.percent.precision(.fractionLength(0)))) }
                if let mean = result.meanReturnPct { metric("Mean move", signedPercent(mean)) }
                if let tilted = result.tiltReturnPct { metric("Tilt return", signedPercent(tilted)) }
            }
            if let baseline = result.baseRateUp, let comparison = result.majorityBaselineHitRate {
                Text("Observed up base rate \(baseline.formatted(.percent.precision(.fractionLength(0)))) · majority baseline hit rate \(comparison.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.medium))
        }
    }

    private func recentSection(_ items: [MarketResearchResponse.Forecast]) -> some View {
        Section("Recent frozen forecasts") {
            ForEach(items) { forecast in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(direction(forecast.tilt)).font(.headline)
                        Spacer()
                        if let score = forecast.score { Text("Index \(score.formatted(.number.precision(.fractionLength(1))))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    Text("\(display(forecast.horizon)) · target \(forecast.sessionDate) · \(forecast.forecastAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let outcome = forecast.outcome { outcomeView(outcome) }
                    if !forecast.evidence.isEmpty { forecastEvidence("Supporting evidence", items: forecast.evidence) }
                    if !forecast.contradictions.isEmpty { forecastEvidence("Contradictions", items: forecast.contradictions) }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func outcomeView(_ outcome: MarketResearchResponse.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Observed \(direction(outcome.direction)) · \(signedPercent(outcome.returnPct))")
                .font(.subheadline.weight(.medium))
            Text("\(outcome.baselinePrice.formatted(.number.precision(.fractionLength(2)))) → \(outcome.endpointPrice.formatted(.number.precision(.fractionLength(2)))) · source \(outcome.source)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func forecastEvidence(_ title: String, items: [MarketResearchResponse.Evidence]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items) { evidence in
                Link(destination: evidence.url) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(evidence.title).font(.subheadline).multilineTextAlignment(.leading)
                        Text([evidence.source, evidence.at?.formatted(.relative(presentation: .named)), evidence.reason].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func questionsSection(_ items: [MarketResearchResponse.Question]) -> some View {
        Section("Research questions") {
            ForEach(items) { question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.query).font(.subheadline.weight(.medium))
                    Text(question.reason).font(.caption).foregroundStyle(.secondary)
                    Text("\(question.status.capitalized) · \(question.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func direction(_ value: String) -> String {
        switch value {
        case "up": "Leans higher"
        case "down": "Leans lower"
        case "neutral": "No clear direction"
        default: "Not enough fresh data"
        }
    }

    private func direction(_ value: Int) -> String {
        switch value {
        case 1: "higher"
        case -1: "lower"
        default: "flat"
        }
    }

    private func display(_ value: String) -> String {
        switch value {
        case "opening_gap": "Overnight move to the open"
        case "cutoff_to_open": "Late trading to the next open"
        case "open_to_close": "Trading day move"
        default: value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func signedPercent(_ value: Double) -> String {
        "\(value > 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(2))))%"
    }

    @MainActor private func refresh(force: Bool = false) async {
        #if DEBUG
        if let fixture {
            do {
                if fixture == MarketResearchFixture.error.rawValue { failed = true }
                else {
                    let selected = MarketResearchFixture(rawValue: fixture)
                    response = selected?.payload
                    failed = response == nil
                    if let response { symbol = response.symbol }
                    loadedSymbol = response?.symbol
                    loadedAt = .now
                }
                return
            }
        }
        #endif
        if !force, loadedSymbol == symbol, let loadedAt, loadedAt.timeIntervalSinceNow > -60 { return }
        guard let baseURL = NewswireAPI.validatedURL(FeedStore.shared.serverURL) else { failureMessage = WireError.configuration.localizedDescription; failed = true; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await NewswireAPI(baseURL: baseURL).marketResearch(symbol: symbol)
            guard !Task.isCancelled, result.symbol == symbol else { return }
            response = result
            loadedAt = .now
            loadedSymbol = result.symbol
            failed = false
        } catch {
            if !Task.isCancelled { failureMessage = researchFailureMessage(error); failed = true }
        }
    }
}
