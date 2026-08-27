import Foundation

@MainActor
package struct CodexReviewStoreSeed {
    package var shouldAutoStartEmbeddedServer: Bool
    package var initialAccount: CodexAccount?
    package var initialAccounts: [CodexAccount]
    package var initialActiveAccountKey: String?
    package var initialSettingsSnapshot: CodexReviewSettings.Snapshot

    package init(
        shouldAutoStartEmbeddedServer: Bool = false,
        initialAccount: CodexAccount? = nil,
        initialAccounts: [CodexAccount] = [],
        initialActiveAccountKey: String? = nil,
        initialSettingsSnapshot: CodexReviewSettings.Snapshot = .init()
    ) {
        self.shouldAutoStartEmbeddedServer = shouldAutoStartEmbeddedServer
        self.initialAccount = initialAccount
        self.initialAccounts = initialAccounts
        self.initialActiveAccountKey = initialActiveAccountKey
        self.initialSettingsSnapshot = initialSettingsSnapshot
    }
}

@MainActor
package protocol CodexReviewStoreBackend: CodexReviewSettingsBackend, Sendable {
    var seed: CodexReviewStoreSeed { get }
    var isActive: Bool { get }
    var semanticStopExecutionOwner: ReviewRuntimeSemanticStopExecutionOwner { get }
    var mcpServerLifecycle: any MCPServerLifecycleOwner { get }

    func attachStore(_ store: CodexReviewStore)
    func prepareRuntime(
        generation: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose
    ) async throws -> PreparedRuntime
    func commitRuntimePublication(
        _ snapshot: RuntimePublicationSnapshot,
        handle: any RuntimeLifecycleHandle,
        auth: CodexReviewAuthModel
    ) throws
    func waitForRuntimePublication(
        handle: any RuntimeLifecycleHandle
    ) async
    func stop(
        context: ReviewRuntimeSemanticStopContext,
        intent: ReviewRuntimeTeardownIntent
    ) async
    func waitUntilStopped() async
    func refreshAuth(auth: CodexReviewAuthModel) async
    func signIn(auth: CodexReviewAuthModel) async
    func addAccount(auth: CodexReviewAuthModel) async
    func cancelAuthentication(auth: CodexReviewAuthModel) async
    func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws
    func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws
    func reorderPersistedAccount(auth: CodexReviewAuthModel, accountKey: String, toIndex: Int) async throws
    func signOutActiveAccount(auth: CodexReviewAuthModel) async throws
    func refreshAccountRateLimits(auth: CodexReviewAuthModel, accountKey: String) async
    func requiresCurrentSessionRecovery(auth: CodexReviewAuthModel, accountKey: String) -> Bool

    func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt
    func interruptReview(_ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason) async throws
    func interruptReview(
        _ admission: ReviewInterruptRequestAdmission,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws
    func prepareReviewRecovery(
        _ candidate: ReviewRecoveryCandidate
    ) async throws -> PreparedReviewRecovery
    func stageReviewRecovery(
        _ prepared: PreparedReviewRecovery,
        destinationGeneration: ReviewRuntimeGeneration,
        request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery
    func commitReviewRecovery(_ staged: StagedReviewRecovery) async throws
    func discardReviewRecovery(_ prepared: PreparedReviewRecovery) async throws
    func discardReviewRecovery(_ staged: StagedReviewRecovery) async throws
    func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async throws
}

extension CodexReviewStoreBackend {
    package func commitRuntimePublication(
        _ snapshot: RuntimePublicationSnapshot,
        handle _: any RuntimeLifecycleHandle,
        auth: CodexReviewAuthModel
    ) throws {
        applyRuntimeAuthenticationSnapshot(snapshot.authentication, to: auth)
    }

    package func waitForRuntimePublication(
        handle _: any RuntimeLifecycleHandle
    ) async {}

    package func prepareReviewRecovery(
        _: ReviewRecoveryCandidate
    ) async throws -> PreparedReviewRecovery {
        throw ReviewAttemptContractFailure(
            message: "Typed review recovery route preparation is not installed."
        )
    }

    package func stageReviewRecovery(
        _: PreparedReviewRecovery,
        destinationGeneration _: ReviewRuntimeGeneration,
        request _: CodexReviewBackendModel.Review.Start,
        admission _: ReviewStartAdmission
    ) async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery {
        throw ReviewRecoveryStagingFailure.callerRetainsPreparedRecovery(
            message: "Typed review recovery route staging is not installed."
        )
    }

    package func commitReviewRecovery(_: StagedReviewRecovery) async throws {
        throw ReviewAttemptContractFailure(
            message: "Typed review recovery route commit is not installed."
        )
    }

    package func discardReviewRecovery(_: PreparedReviewRecovery) async throws {
        throw ReviewAttemptContractFailure(
            message: "Typed prepared review recovery discard is not installed."
        )
    }

    package func discardReviewRecovery(_: StagedReviewRecovery) async throws {
        throw ReviewAttemptContractFailure(
            message: "Typed staged review recovery discard is not installed."
        )
    }

}
