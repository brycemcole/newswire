import Foundation
import Testing
@testable import Newswire

@MainActor struct MarketOutlookTests {
    private static let validAnswer = """
    ```outlook
    {"headline":"Stocks lean higher into the open","deck":"Futures are firmer while volatility stays muted.","tone":"bullish","symbols":["SPY","QQQ"]}
    ```
    **Stocks lean higher into the open.**

    ## What's driving it

    Futures are firmer overnight.
    """

    private func isolatedDefaults() -> UserDefaults {
        let suite = "MarketOutlookTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func generationSurvivesCallerTaskCancellationAndDeduplicatesReentry() async throws {
        var now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")! // Mon 8:00 AM ET (pre-market)
        var runs = 0
        var releaseResponder: CheckedContinuation<String, Error>?

        let store = MarketOutlookStore(
            defaults: isolatedDefaults(),
            storageKey: "test.outlook",
            fetchPulse: { nil },
            makeChat: {
                StockChat { _, _, _, _, _ in
                    runs += 1
                    return try await withCheckedThrowingContinuation { continuation in
                        releaseResponder = continuation
                    }
                }
            },
            modelName: { _ in "test-model" },
            isAvailable: { true },
            clock: { now }
        )

        // Simulate MarketOutlookRow's .task starting ensure(), then getting cancelled when the user switches tabs/pages.
        let viewTask = Task {
            store.ensure()
            try? await Task.sleep(for: .seconds(60))
        }
        try await waitUntil { releaseResponder != nil }
        #expect(store.generating)
        #expect(runs == 1)

        viewTask.cancel()
        await viewTask.value

        // Even after the view task is cancelled, generation must still be running.
        #expect(store.generating)

        // Simulate returning to the Today screen while generation is still in progress: must not restart or duplicate.
        store.ensure()
        #expect(store.generating)
        #expect(runs == 1)

        // Complete the in-flight generation.
        releaseResponder?.resume(returning: Self.validAnswer)
        try await waitUntil { !store.generating }

        #expect(runs == 1)
        #expect(store.error == nil)
        #expect(store.outlook?.headline == "Stocks lean higher into the open")
        #expect(store.outlook?.symbols == ["SPY", "QQQ"])
        #expect(store.outlook?.generatedAt == now)
        #expect(store.outlook?.validUntil == MarketClock.nextOpen(after: now))
        #expect(store.outlook?.pulseAsOf == nil)
        #expect(store.outlook?.current(at: now) == true)

        // Crossing the target horizon marks the cached outlook stale and eligible for refresh.
        now = MarketClock.nextOpen(after: now).addingTimeInterval(60)
        #expect(store.outlook?.current(at: now) == false)
        #expect(store.needsRefresh(at: now))
    }

    @Test func failureBacksOffAutoEnsureButAllowsManualRetryAndRecovery() async throws {
        var now = ISO8601DateFormatter().date(from: "2026-10-19T14:00:00Z")! // Mon 10:00 AM ET (regular session)
        var attempts = 0

        let store = MarketOutlookStore(
            defaults: isolatedDefaults(),
            storageKey: "test.outlook.retry",
            fetchPulse: { nil },
            makeChat: {
                StockChat { _, _, _, _, _ in
                    attempts += 1
                    if attempts == 1 { throw StockAIError.incomplete }
                    return Self.validAnswer
                }
            },
            modelName: { _ in "test-model" },
            isAvailable: { true },
            clock: { now }
        )

        store.ensure()
        try await waitUntil { !store.generating }
        #expect(attempts == 1)
        #expect(store.outlook == nil)
        #expect(store.error != nil)

        // Automatic ensure backs off within retryDelay (10 min).
        now = now.addingTimeInterval(60)
        store.ensure()
        #expect(!store.generating)
        #expect(attempts == 1)

        // Manual startGeneration / generate bypasses retryDelay and recovers cleanly.
        await store.generate()
        #expect(attempts == 2)
        #expect(store.error == nil)
        #expect(store.outlook?.headline == "Stocks lean higher into the open")
        #expect(store.outlook?.generatedAt == now)
        #expect(store.outlook?.validUntil == MarketClock.session(on: now)?.end)
    }

    @Test func draftPreviewHidesIncompleteFenceAndExtractsStreamingBody() {
        let incomplete = "```outlook\n{\"headline\":\"Partial"
        #expect(MarketOutlookStore.draftPreview(incomplete) == .init(headline: nil, deck: nil, body: ""))

        let streaming = """
        ```outlook
        {"headline":"Stocks lean higher","deck":"Futures are firmer.","tone":"bullish","symbols":["SPY"]}
        ```
        **Stocks lean higher** as yields ease.
        """
        let preview = MarketOutlookStore.draftPreview(streaming)
        #expect(preview.headline == "Stocks lean higher")
        #expect(preview.deck == "Futures are firmer.")
        #expect(preview.body == "**Stocks lean higher** as yields ease.")
    }

    @Test func generationExposesLiveProgressThinkingAndStreamingText() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
        var releaseResponder: CheckedContinuation<String, Error>?
        var activeChat: StockChat?

        let store = MarketOutlookStore(
            defaults: isolatedDefaults(),
            storageKey: "test.outlook.progress",
            fetchPulse: { nil },
            makeChat: {
                let chat = StockChat { _, _, _, _, _ in
                    try await withCheckedThrowingContinuation { continuation in
                        releaseResponder = continuation
                    }
                }
                activeChat = chat
                return chat
            },
            modelName: { _ in "test-model" },
            isAvailable: { true },
            clock: { now }
        )

        store.startGeneration()
        try await waitUntil { releaseResponder != nil }

        activeChat?.activity = "Checking SPY…"
        activeChat?.thinkingText = "Weighing overnight futures against VIX."
        activeChat?.streamingText = "```outlook\n{\"headline\":\"Draft\"}\n```\nFirst paragraph."

        try await waitUntil {
            store.progressLog.contains("Checking SPY…")
                && store.thinking == "Weighing overnight futures against VIX."
                && store.streamingText.contains("First paragraph.")
        }
        #expect(store.progressLog.first == "Reading the market…")
        #expect(store.progressLog.contains("Writing the outlook…"))

        releaseResponder?.resume(returning: Self.validAnswer)
        try await waitUntil { !store.generating }
        #expect(store.progressLog.isEmpty)
        #expect(store.thinking.isEmpty)
        #expect(store.streamingText.isEmpty)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for MarketOutlookStore state")
    }
}
