import Testing
@_spi(Testing) @testable import CodexReviewKit
import CodexReviewTesting

@Suite("Review chat link", .serialized)
@MainActor
struct ReviewChatLinkTests {
    @Test func startedReviewExposesDetachedReviewThreadAsActiveChatThread() async throws {
        let backend = FakeCodexReviewBackend(
            nextRun: .init(
                attemptID: "attempt-1",
                threadID: "source-thread",
                turnID: "turn-1",
                reviewThreadID: "review-thread",
                model: "gpt-5.5"
            ))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )

        try await withReviewChatLinkStoreCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let link = try #require(store.job(id: "job-1")?.reviewChatLink)
            #expect(link.jobID == "job-1")
            #expect(link.sessionID == "session-1")
            #expect(link.cwd == "/tmp/project")
            #expect(link.attemptID == "attempt-1")
            #expect(link.sourceThreadID == "source-thread")
            #expect(link.reviewThreadID == "review-thread")
            #expect(link.activeChatThreadID == "review-thread")
            #expect(link.turnID == "turn-1")
            #expect(link.model == "gpt-5.5")
        }
    }

    @Test func missingOrInlineReviewThreadFallsBackToSourceThread() throws {
        let missingReviewThreadJob = makeRunningJob(
            attemptID: "attempt-1",
            sourceThreadID: "source-thread",
            reviewThreadID: nil,
            turnID: "turn-1"
        )
        let missingReviewThreadLink = try #require(missingReviewThreadJob.reviewChatLink)
        #expect(missingReviewThreadLink.attemptID == "attempt-1")
        #expect(missingReviewThreadLink.reviewThreadID == nil)
        #expect(missingReviewThreadLink.activeChatThreadID == "source-thread")

        let inlineReviewThreadJob = makeRunningJob(
            attemptID: "attempt-2",
            sourceThreadID: "source-thread",
            reviewThreadID: "source-thread",
            turnID: "turn-1"
        )
        let inlineReviewThreadLink = try #require(inlineReviewThreadJob.reviewChatLink)
        #expect(inlineReviewThreadLink.attemptID == "attempt-2")
        #expect(inlineReviewThreadLink.reviewThreadID == "source-thread")
        #expect(inlineReviewThreadLink.activeChatThreadID == "source-thread")
    }

    @Test func emptyStringsAreNormalizedAway() throws {
        let job = makeRunningJob(
            sourceThreadID: "source-thread",
            reviewThreadID: "  ",
            turnID: "turn-1",
            model: "\n"
        )

        let link = try #require(job.reviewChatLink)
        #expect(link.reviewThreadID == nil)
        #expect(link.activeChatThreadID == "source-thread")
        #expect(link.attemptID == nil)
        #expect(link.model == nil)

        job.core.run.threadID = ""
        #expect(job.reviewChatLink == nil)

        job.core.run.threadID = "source-thread"
        job.core.run.turnID = "  "
        #expect(job.reviewChatLink == nil)
    }

    private func makeRunningJob(
        attemptID: String? = nil,
        sourceThreadID: String?,
        reviewThreadID: String?,
        turnID: String?,
        model: String? = "gpt-5"
    ) -> CodexReviewJob {
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            sessionID: "session-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            model: model,
            threadID: sourceThreadID,
            turnID: turnID,
            status: .running,
            summary: "Running"
        )
        job.core.run.attemptID = attemptID
        job.core.run.reviewThreadID = reviewThreadID
        return job
    }
}

@MainActor
private func withReviewChatLinkStoreCleanup(
    backend: FakeCodexReviewBackend,
    store: CodexReviewStore,
    operation: () async throws -> Void
) async rethrows {
    do {
        try await operation()
    } catch {
        await cleanupReviewChatLinkStore(backend: backend, store: store)
        throw error
    }
    await cleanupReviewChatLinkStore(backend: backend, store: store)
}

@MainActor
private func cleanupReviewChatLinkStore(
    backend: FakeCodexReviewBackend,
    store: CodexReviewStore
) async {
    await backend.finishEventMailboxes()
    await store.cancelAndDrainReviewWorkersForTesting()
    await backend.finishEventMailboxes()
}
