import Foundation

package struct ReviewRuntimeGeneration: Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package func successor() -> Self {
        .init(rawValue: rawValue + 1)
    }
}

package enum ReviewRuntimeCleanupRecoverySuppression: Equatable, Sendable {
    case explicitStop
    case staleSource
    case successorAlreadyFinished
}

package enum ReviewRuntimeCleanupRecoveryAdmission: Equatable, Sendable {
    case admitted(
        sourceGeneration: ReviewRuntimeGeneration,
        successorGeneration: ReviewRuntimeGeneration
    )
    case joined(
        sourceGeneration: ReviewRuntimeGeneration,
        successorGeneration: ReviewRuntimeGeneration
    )
    case suppressed(ReviewRuntimeCleanupRecoverySuppression)
}

package enum ReviewRuntimeTransitionPurpose: Equatable, Sendable {
    case start
    case restartSameAccount
    case stop
    case runtimeFailure
}

package struct RuntimePublicationSnapshot: Sendable {
    package let authentication: CodexReviewBackendModel.Auth.Snapshot
    package let settings: CodexReviewSettings.Snapshot

    package init(
        authentication: CodexReviewBackendModel.Auth.Snapshot,
        settings: CodexReviewSettings.Snapshot
    ) {
        self.authentication = authentication
        self.settings = settings
    }
}

@MainActor
package func applyRuntimeAuthenticationSnapshot(
    _ snapshot: CodexReviewBackendModel.Auth.Snapshot,
    to auth: CodexReviewAuthModel
) {
    let persistedAccounts = auth.persistedAccounts
    let observedAccounts = snapshot.accounts.compactMap { account in
        preparedCodexAccount(
            from: account,
            preservingRateLimitStateFrom: persistedAccounts
        )
    }
    let activeAccountKey = snapshot.activeAccountID.map {
        CodexAccount.normalizedEmail($0.rawValue)
    }
    var accounts = auth.persistedAccounts
    for observedAccount in observedAccounts {
        if let index = accounts.firstIndex(where: {
            $0.accountKey == observedAccount.accountKey
        }) {
            accounts[index].apply(savedAccountPayload(from: observedAccount))
        } else {
            accounts.insert(observedAccount, at: 0)
        }
    }
    auth.applyPersistedAccountStates(
        accounts.map(savedAccountPayload(from:)),
        activeAccountKey: activeAccountKey
    )
    auth.selectPersistedAccount(activeAccountKey)
    auth.updatePhase(.signedOut)
}

@MainActor
package protocol RuntimeLifecycleHandle: AnyObject, Sendable {
    func activate() async throws
    func closeAdmission()
    func close(purpose: ReviewRuntimeTransitionPurpose) async throws
    func waitUntilClosed() async throws
}

@MainActor
package final class ReviewRuntimeFailureIncident {
    private enum SuccessorState {
        case available
        case admitted(ReviewRuntimeGeneration)
        case finished
    }

    package let sourceGeneration: ReviewRuntimeGeneration

    private weak var sourceHandle: (any RuntimeLifecycleHandle)?
    private var successorState: SuccessorState = .available

    package init(
        sourceHandle: any RuntimeLifecycleHandle,
        sourceGeneration: ReviewRuntimeGeneration
    ) {
        self.sourceHandle = sourceHandle
        self.sourceGeneration = sourceGeneration
    }

    package func matches(
        sourceHandle: any RuntimeLifecycleHandle,
        sourceGeneration: ReviewRuntimeGeneration
    ) -> Bool {
        self.sourceHandle === sourceHandle && self.sourceGeneration == sourceGeneration
    }

    package func admitSuccessor(
        generation: ReviewRuntimeGeneration
    ) -> ReviewRuntimeCleanupRecoveryAdmission {
        switch successorState {
        case .available:
            successorState = .admitted(generation)
            return .admitted(
                sourceGeneration: sourceGeneration,
                successorGeneration: generation
            )
        case .admitted(let successorGeneration):
            if generation.rawValue > successorGeneration.rawValue {
                successorState = .admitted(generation)
                return .joined(
                    sourceGeneration: sourceGeneration,
                    successorGeneration: generation
                )
            }
            return .joined(
                sourceGeneration: sourceGeneration,
                successorGeneration: successorGeneration
            )
        case .finished:
            return .suppressed(.successorAlreadyFinished)
        }
    }

    package func joinedSuccessorAdmission() -> ReviewRuntimeCleanupRecoveryAdmission {
        switch successorState {
        case .available:
            return .suppressed(.staleSource)
        case .admitted(let successorGeneration):
            return .joined(
                sourceGeneration: sourceGeneration,
                successorGeneration: successorGeneration
            )
        case .finished:
            return .suppressed(.successorAlreadyFinished)
        }
    }

    package func finishSuccessor(generation: ReviewRuntimeGeneration) {
        guard case .admitted(let admittedGeneration) = successorState,
              admittedGeneration == generation
        else {
            return
        }
        successorState = .finished
    }
}

package struct PreparedRuntime: Sendable {
    package let snapshot: RuntimePublicationSnapshot
    package let handle: any RuntimeLifecycleHandle

    package init(
        snapshot: RuntimePublicationSnapshot,
        handle: any RuntimeLifecycleHandle
    ) {
        self.snapshot = snapshot
        self.handle = handle
    }
}

package final class PreparedMCPServer: @unchecked Sendable {
    package init() {}
}

package struct MCPServerPublicationSnapshot: Sendable {
    package let serverURL: URL?

    package init(serverURL: URL?) {
        self.serverURL = serverURL
    }
}

package struct RetainedMCPServer: Sendable {
    package let serverURL: URL?

    package init(serverURL: URL?) {
        self.serverURL = serverURL
    }
}

@MainActor
package final class RuntimeAcquisitionContext {
    private var recyclingState: ReviewStoreRuntimeState?
    package let failureIncident: ReviewRuntimeFailureIncident?

    package init(
        recycling state: ReviewStoreRuntimeState? = nil,
        failureIncident: ReviewRuntimeFailureIncident? = nil
    ) {
        recyclingState = state
        self.failureIncident = failureIncident
    }

    package func takeRecyclingState() -> ReviewStoreRuntimeState? {
        defer { recyclingState = nil }
        return recyclingState
    }
}

package enum ReviewStoreRuntimeState {
    case stopped(ReviewRuntimeGeneration)
    case acquiring(
        generation: ReviewRuntimeGeneration,
        context: RuntimeAcquisitionContext,
        task: Task<Void, Never>
    )
    case running(
        generation: ReviewRuntimeGeneration,
        runtime: PreparedRuntime,
        mcp: RetainedMCPServer
    )
    case replacing(
        replacement: ReviewRuntimeRecoveryReplacement,
        task: Task<Void, Never>
    )
    case tearingDown(
        generation: ReviewRuntimeGeneration,
        cleanupIntent: ReviewRuntimeTeardownIntent,
        finalIntent: ReviewRuntimeTeardownIntent,
        failureIncident: ReviewRuntimeFailureIncident?,
        task: Task<Void, Never>
    )
    case failed(
        generation: ReviewRuntimeGeneration,
        retainedMCP: RetainedMCPServer?,
        failureIncident: ReviewRuntimeFailureIncident?
    )

    package var generation: ReviewRuntimeGeneration {
        switch self {
        case .stopped(let generation),
             .acquiring(let generation, _, _),
             .running(let generation, _, _),
             .tearingDown(let generation, _, _, _, _),
             .failed(let generation, _, _):
            generation
        case .replacing(let replacement, _):
            replacement.replacementGeneration
        }
    }
}

@MainActor
package protocol MCPServerLifecycleOwner: Sendable {
    func prepare() async throws -> PreparedMCPServer
    func activate(
        _ preparation: PreparedMCPServer
    ) async throws -> MCPServerPublicationSnapshot
    func stop() async throws
}

@MainActor
package final class NoMCPServerLifecycleOwner: MCPServerLifecycleOwner {
    private enum State {
        case stopped
        case prepared(PreparedMCPServer)
        case running(PreparedMCPServer)
    }

    private var serverURL: URL?
    private var state: State = .stopped

    package init(serverURL: URL? = nil) {
        self.serverURL = serverURL
    }

    package func updateServerURL(_ serverURL: URL?) {
        self.serverURL = serverURL
    }

    package func prepare() async throws -> PreparedMCPServer {
        guard case .stopped = state else {
            throw CancellationError()
        }
        let preparation = PreparedMCPServer()
        state = .prepared(preparation)
        return preparation
    }

    package func activate(
        _ preparation: PreparedMCPServer
    ) async throws -> MCPServerPublicationSnapshot {
        guard case .prepared(let current) = state,
              current === preparation
        else {
            throw CancellationError()
        }
        state = .running(preparation)
        return .init(serverURL: serverURL)
    }

    package func stop() async throws {
        state = .stopped
    }
}
