import Testing
@testable import CodexReviewKit
@testable import CodexReviewTesting

@MainActor
@Suite("review network monitoring")
struct CodexReviewNetworkMonitoringTests {
    @Test func manualMonitorKeepsOnlyNewestSnapshotAndCanFinishExplicitly() async throws {
        let monitor = ManualCodexReviewNetworkMonitor()
        var iterator = monitor.snapshots().makeAsyncIterator()

        #expect(await iterator.next()?.status == .satisfied)

        monitor.yield(.init(status: .unsatisfied))
        monitor.yield(.satisfied())

        #expect(await iterator.next()?.status == .satisfied)

        monitor.finish()
        #expect(await iterator.next() == nil)
    }

    @Test func unexpectedNetworkSourceFinishFailsAnOtherwiseLiveReview() async throws {
        let attempt = makeReviewAttemptForTesting(
            attemptID: "attempt-network-source-finish",
            sourceThreadID: "thread-network-source-finish",
            activeTurnThreadID: "review-thread-network-source-finish",
            turnID: "turn-network-source-finish"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let monitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-network-source-finish" }),
            networkMonitor: monitor
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
        )
        try #require(
            await StoreSnapshotProbe(store: store).waitUntilRunStatus(
                .running,
                runID: "run-network-source-finish"
            ) != nil
        )

        monitor.finish()
        let read = try await result

        #expect(read.core.status == .failed)
        #expect(read.core.failure == .connectivityObservationEnded)
    }

    @Test func terminalCandidateWinsWhenNetworkSourceFinishesAtTheSameBoundary() async throws {
        let attempt = makeReviewAttemptForTesting(
            attemptID: "attempt-terminal-network-race",
            sourceThreadID: "thread-terminal-network-race",
            activeTurnThreadID: "review-thread-terminal-network-race",
            turnID: "turn-terminal-network-race"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let monitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-terminal-network-race" }),
            networkMonitor: monitor
        )

        async let result = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
        )
        try #require(
            await StoreSnapshotProbe(store: store).waitUntilRunStatus(
                .running,
                runID: "run-terminal-network-race"
            ) != nil
        )

        await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
        monitor.finish()
        let read = try await result

        #expect(read.core.status == .succeeded)
    }
}
