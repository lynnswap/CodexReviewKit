import Foundation
import Testing
import CodexReview
import CodexReviewTesting

@Suite("runtime recovery replacement", .serialized)
@MainActor
struct ReviewRuntimeRecoveryReplacementTests {
    @Test func derivesOneSuccessorGenerationAndRetainsMCP() throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:19431/mcp"))
        let sourceGeneration = ReviewRuntimeGeneration(rawValue: 41)

        let replacement = ReviewRuntimeRecoveryReplacement(
            sourceGeneration: sourceGeneration,
            retiringRuntime: nil,
            retainedMCP: .init(serverURL: endpoint)
        )

        #expect(replacement.sourceGeneration == sourceGeneration)
        #expect(replacement.replacementGeneration == .init(rawValue: 42))
        #expect(replacement.retainedMCP.serverURL == endpoint)
    }

    @Test func retiringRuntimeCanBeTakenOnce() async throws {
        let sourceGeneration = ReviewRuntimeGeneration(rawValue: 7)
        let backend = TestingCodexReviewStoreBackend(
            reviewBackend: FakeCodexReviewBackend()
        )
        let runtime = try await backend.prepareRuntime(
            generation: sourceGeneration,
            purpose: .start
        )
        let replacement = ReviewRuntimeRecoveryReplacement(
            sourceGeneration: sourceGeneration,
            retiringRuntime: runtime,
            retainedMCP: .init(serverURL: nil)
        )

        let takenRuntime = try #require(replacement.takeRetiringRuntime())

        #expect(takenRuntime.handle === runtime.handle)
        #expect(replacement.takeRetiringRuntime() == nil)
    }

    @Test func terminalOutcomeReplaysToPreAndPostCompletionWaiters() async {
        let replacement = ReviewRuntimeRecoveryReplacement(
            sourceGeneration: .init(rawValue: 12),
            retiringRuntime: nil,
            retainedMCP: .init(serverURL: nil)
        )
        var waitingBeforeCompletion = replacement.outcomes().makeAsyncIterator()
        let expected = ReviewRuntimeRecoveryReplacement.Outcome.running(
            replacement.replacementGeneration
        )

        replacement.finish(expected)
        replacement.finish(.failed("ignored duplicate"))

        #expect(await waitingBeforeCompletion.next() == expected)
        #expect(await waitingBeforeCompletion.next() == nil)
        var waitingAfterCompletion = replacement.outcomes().makeAsyncIterator()
        #expect(await waitingAfterCompletion.next() == expected)
        #expect(await waitingAfterCompletion.next() == nil)
    }

    @Test func sourceCloseFailureReplaysAndCanBeConsumedOnce() async {
        let replacement = ReviewRuntimeRecoveryReplacement(
            sourceGeneration: .init(rawValue: 15),
            retiringRuntime: nil,
            retainedMCP: .init(serverURL: nil)
        )
        let expected = ReviewRuntimeCloseFailure.process("Injected close failure.")
        var waitingBeforeCompletion = replacement.sourceCloseResults().makeAsyncIterator()

        replacement.finishSourceClose(.failed(expected))

        #expect(await waitingBeforeCompletion.next() == .failed(expected))
        var waitingAfterCompletion = replacement.sourceCloseResults().makeAsyncIterator()
        #expect(await waitingAfterCompletion.next() == .failed(expected))
        #expect(replacement.consumeSourceCloseFailure() == expected)
        #expect(replacement.consumeSourceCloseFailure() == nil)
    }

    @Test func abandonedOutcomeWaitersAreRemovedBeforeTerminalCompletion() async {
        let replacement = ReviewRuntimeRecoveryReplacement(
            sourceGeneration: .init(rawValue: 18),
            retiringRuntime: nil,
            retainedMCP: .init(serverURL: nil)
        )
        let outcomes = replacement.outcomes()
        #expect(replacement.pendingOutcomeWaiterCount == 1)
        let waiter = Task { @MainActor in
            var iterator = outcomes.makeAsyncIterator()
            return await iterator.next()
        }

        waiter.cancel()
        #expect(await waiter.value == nil)
        #expect(replacement.pendingOutcomeWaiterCount == 0)

        var droppedOutcomes: AsyncStream<ReviewRuntimeRecoveryReplacement.Outcome>? =
            replacement.outcomes()
        #expect(droppedOutcomes != nil)
        #expect(replacement.pendingOutcomeWaiterCount == 1)
        droppedOutcomes = nil
        #expect(replacement.pendingOutcomeWaiterCount == 0)
    }
}
