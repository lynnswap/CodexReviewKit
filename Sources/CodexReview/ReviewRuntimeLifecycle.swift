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
    let observedAccounts = snapshot.accounts.compactMap { account -> CodexAccount? in
        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountKey = CodexAccount.normalizedEmail(account.id.rawValue)
        guard label.isEmpty == false, accountKey.isEmpty == false else {
            return nil
        }
        return CodexAccount(
            accountKey: accountKey,
            email: label,
            planType: account.planType,
            kind: account.kind,
            capabilities: account.capabilities
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
            accounts[index].updateEmail(observedAccount.email)
            accounts[index].updateKind(
                observedAccount.kind,
                capabilities: observedAccount.capabilities
            )
            accounts[index].updatePlanType(observedAccount.planType)
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
    func closeAdmission() async
    func close(purpose: ReviewRuntimeTransitionPurpose) async throws
    func waitUntilClosed() async throws
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
package final class RuntimeReplacementContext {
    private var retiringRuntime: PreparedRuntime?

    package init(retiringRuntime: PreparedRuntime?) {
        self.retiringRuntime = retiringRuntime
    }

    package func takeRetiringRuntime() -> PreparedRuntime? {
        defer { retiringRuntime = nil }
        return retiringRuntime
    }
}

@MainActor
package final class RuntimeAcquisitionContext {
    private var recyclingState: ReviewStoreRuntimeState?

    package init(recycling state: ReviewStoreRuntimeState? = nil) {
        recyclingState = state
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
        generation: ReviewRuntimeGeneration,
        context: RuntimeReplacementContext,
        retainedMCP: RetainedMCPServer,
        task: Task<Void, Never>
    )
    case tearingDown(
        generation: ReviewRuntimeGeneration,
        cleanupIntent: ReviewRuntimeTeardownIntent,
        finalIntent: ReviewRuntimeTeardownIntent,
        task: Task<Void, Never>
    )
    case failed(
        generation: ReviewRuntimeGeneration,
        retainedMCP: RetainedMCPServer?
    )

    package var generation: ReviewRuntimeGeneration {
        switch self {
        case .stopped(let generation),
             .acquiring(let generation, _, _),
             .running(let generation, _, _),
             .replacing(let generation, _, _, _),
             .tearingDown(let generation, _, _, _),
             .failed(let generation, _):
            generation
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
