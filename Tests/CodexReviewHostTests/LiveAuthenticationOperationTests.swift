import Testing
import CodexReview
@testable import CodexReviewHost

@Suite("authentication operation")
@MainActor
struct LiveAuthenticationOperationTests {
    @Test func cancellationRevokesSharedStateCommitsWithoutDiscardingResourceOwnership() throws {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        let scope = try #require(operation.installResources(.init()))

        #expect(operation.authorizesSharedStateCommit(from: scope))

        operation.beginCancellation()

        #expect(operation.isCurrent(scope))
        #expect(scope.isOpen)
        #expect(operation.authorizesSharedStateCommit(from: scope) == false)
    }

    @Test func normalCompletionKeepsCommitAuthorityAfterTakingCleanupResources() throws {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        let scope = try #require(operation.installResources(.init()))
        let unrelatedScope = LiveAuthenticationOperation.ResourceScope(.init())

        _ = try #require(scope.takeForCleanup())

        #expect(scope.isOpen == false)
        #expect(operation.authorizesSharedStateCommit(from: scope))
        #expect(operation.authorizesSharedStateCommit(from: unrelatedScope) == false)
    }

    @Test func admittedAPIKeyReconciliationKeepsCommitAuthorityDuringCancellation() throws {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .apiKey(try CodexReviewAPIKey(validating: "sk-test"))
        )
        let scope = try #require(operation.installResources(.init()))
        operation.install(setupTask: Task { @MainActor in })

        #expect(operation.admitAPIKeyRequest())

        operation.beginCancellation()

        #expect(operation.authorizesSharedStateCommit(from: scope))
    }
}
