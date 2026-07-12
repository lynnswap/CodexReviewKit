import Foundation
import OSLog
import CodexReviewKit

private let logger = Logger(subsystem: "CodexReviewKit", category: "live-store-backend")

struct IsolatedLoginProductCommitCancelled: Error, Sendable {}

struct IsolatedLoginProductCommitFailure: Error, LocalizedError, Sendable {
    let failure: CodexReviewAuthenticationFailure

    var errorDescription: String? {
        failure.localizedDescription
    }
}

actor AccountRegistryStore {
    struct Snapshot: Sendable {
        let accounts: [CodexSavedAccountPayload]
        let activeAccountKey: String?
    }

    struct MutationLease: Hashable, Sendable {
        let id: UUID
    }

    struct AccountMutation: Sendable {
        let lease: MutationLease
        let before: Snapshot
    }

    struct PreparedMutation: Hashable, Sendable {
        let id: UUID
    }

    enum PreparedAbortDisposition: Sendable {
        case restoredBefore(Snapshot)
        case forwardedDesired(Snapshot)
    }

    struct RuntimeCommitAuthorization: Sendable {
        let generation: UInt64

        init(generation: UInt64) {
            self.generation = generation
        }
    }

    struct AuthenticationMutation: Sendable {
        let lease: MutationLease
        let purpose: LoginPurpose
        let previousActiveAccountKey: String?
    }

    enum TemporaryCodexHomeKind: Sendable {
        case authentication
        case rateLimits

        var pathPrefix: String {
            switch self {
            case .authentication:
                "codex-review-auth-"
            case .rateLimits:
                "codex-review-rate-limits-"
            }
        }
    }

    private enum MutationKind: Equatable {
        case authentication
        case account
    }

    let codexHomeURL: URL
    private let authenticationMutationDidBegin: CodexReviewAuthenticationMutationDidBegin?
    private let authenticationCancellationDidRequest: CodexReviewAuthenticationCancellationDidRequest?
    private let authenticationProductCommitDidApply: CodexReviewAuthenticationProductCommitDidApply?
    private let registryDestinationDidReplace: CodexReviewRegistryDestinationDidReplace?
    private let directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)?
    private let loadDidBegin: CodexReviewAccountRegistryLoadDidBegin?
    private var activeMutation: (
        lease: MutationLease,
        kind: MutationKind,
        cancellationRequested: Bool,
        productCommitClaimed: Bool
    )?
    private var activeRuntimeGeneration: UInt64?

    init(
        codexHomeURL: URL,
        authenticationMutationDidBegin: CodexReviewAuthenticationMutationDidBegin? = nil,
        authenticationCancellationDidRequest: CodexReviewAuthenticationCancellationDidRequest? = nil,
        authenticationProductCommitDidApply: CodexReviewAuthenticationProductCommitDidApply? = nil,
        registryDestinationDidReplace: CodexReviewRegistryDestinationDidReplace? = nil,
        directoryDurabilityDidSynchronize: (@Sendable (URL) throws -> Void)? = nil,
        loadDidBegin: CodexReviewAccountRegistryLoadDidBegin? = nil
    ) {
        self.codexHomeURL = codexHomeURL
        self.authenticationMutationDidBegin = authenticationMutationDidBegin
        self.authenticationCancellationDidRequest = authenticationCancellationDidRequest
        self.authenticationProductCommitDidApply = authenticationProductCommitDidApply
        self.registryDestinationDidReplace = registryDestinationDidReplace
        self.directoryDurabilityDidSynchronize = directoryDurabilityDidSynchronize
        self.loadDidBegin = loadDidBegin
    }

    nonisolated static func loadInitialSnapshot(codexHomeURL: URL) throws -> Snapshot {
        try Disk.load(codexHomeURL: codexHomeURL)
    }

    func load() async throws -> Snapshot {
        await loadDidBegin?()
        return try Disk.load(codexHomeURL: codexHomeURL)
    }

    func openRuntimeAdmission(generation: UInt64) {
        guard activeRuntimeGeneration == nil || activeRuntimeGeneration == generation else {
            preconditionFailure("A new runtime generation cannot publish before the previous registry admission closes.")
        }
        activeRuntimeGeneration = generation
    }

    func closeRuntimeAdmission(generation: UInt64) {
        guard activeRuntimeGeneration == generation else {
            return
        }
        activeRuntimeGeneration = nil
    }

    func deactivateAccount(
        authorization: MutationLease?,
        runtimeAuthorization: RuntimeCommitAuthorization? = nil
    ) async throws -> Snapshot {
        try requireMutationAuthorization(authorization)
        try requireRuntimeAuthorization(runtimeAuthorization)
        try Disk.deactivateAccount(
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
        return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
    }

    func prepareAccountActivation(_ accountKey: String) throws -> PreparedMutation {
        try Disk.prepareAccountActivation(accountKey, codexHomeURL: codexHomeURL)
    }

    func updateCachedRateLimits(
        from account: CodexSavedAccountPayload,
        runtimeAuthorization: RuntimeCommitAuthorization? = nil
    ) async throws {
        try requireNoAccountMutationForBackgroundPersistence()
        try requireRuntimeAuthorization(runtimeAuthorization)
        try Disk.updateCachedRateLimits(
            from: account,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
    }

    func saveSharedAuth(
        from sourceCodexHomeURL: URL? = nil,
        for account: CodexSavedAccountPayload,
        runtimeAuthorization: RuntimeCommitAuthorization? = nil
    ) throws {
        try requireNoAccountMutationForBackgroundPersistence()
        try requireRuntimeAuthorization(runtimeAuthorization)
        try Disk.saveSharedAuth(
            from: sourceCodexHomeURL ?? codexHomeURL,
            for: account,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
    }

    func commitAuthenticatedAccount(
        _ authenticatedAccount: CodexSavedAccountPayload,
        activation: LoginActivation,
        authSourceCodexHomeURL: URL?,
        authorization: MutationLease?,
        runtimeAuthorization: RuntimeCommitAuthorization? = nil,
        isolatedProductCommitAuthorization: MutationLease? = nil
    ) async throws -> Snapshot {
        try requireMutationAuthorization(authorization)
        try requireRuntimeAuthorization(runtimeAuthorization)
        let didClaimIsolatedProductCommit: Bool
        if let isolatedProductCommitAuthorization,
           claimAuthenticationProductCommit(isolatedProductCommitAuthorization) == false {
            throw IsolatedLoginProductCommitCancelled()
        } else {
            didClaimIsolatedProductCommit = isolatedProductCommitAuthorization != nil
        }
        do {
            try Disk.commitAuthenticatedAccount(
                authenticatedAccount,
                activation: activation,
                authSourceCodexHomeURL: authSourceCodexHomeURL ?? codexHomeURL,
                codexHomeURL: codexHomeURL,
                destinationDidReplace: registryDestinationDidReplace
            )
            if didClaimIsolatedProductCommit {
                await authenticationProductCommitDidApply?()
            }
            return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
        } catch {
            guard didClaimIsolatedProductCommit else {
                throw error
            }
            let failure = (error as? CodexReviewAuthenticationFailure)
                ?? CodexReviewAuthenticationFailure.accountCommit(message: error.localizedDescription)
            throw IsolatedLoginProductCommitFailure(failure: failure)
        }
    }

    func upsertAccount(
        _ account: CodexSavedAccountPayload,
        activation: LoginActivation,
        authorization: MutationLease?,
        runtimeAuthorization: RuntimeCommitAuthorization? = nil
    ) async throws -> Snapshot {
        try requireMutationAuthorization(authorization)
        try requireRuntimeAuthorization(runtimeAuthorization)
        try Disk.upsertAccount(
            account,
            activation: activation,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
        return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
    }

    func prepareIrreversibleRemoval(
        accountKey: String
    ) throws -> PreparedMutation {
        try Disk.prepareIrreversibleRemoval(
            accountKey: accountKey,
            codexHomeURL: codexHomeURL
        )
    }

    func commitPreparedMutation(_ mutation: PreparedMutation) throws -> Snapshot {
        try Disk.commitPreparedMutation(mutation, codexHomeURL: codexHomeURL)
        return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
    }

    func abortPreparedMutation(
        _ mutation: PreparedMutation
    ) throws -> PreparedAbortDisposition {
        try Disk.abortPreparedMutation(mutation, codexHomeURL: codexHomeURL)
    }

    func removeInactiveAccount(accountKey: String) throws -> Snapshot {
        try Disk.removeInactiveAccount(
            accountKey: accountKey,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
        return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
    }

    func reorderAccount(accountKey: String, toIndex: Int) throws -> Snapshot {
        try Disk.reorderAccount(
            accountKey: accountKey,
            toIndex: toIndex,
            codexHomeURL: codexHomeURL,
            destinationDidReplace: registryDestinationDidReplace
        )
        return try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
    }

    func cleanupRemovedAccountDirectory(accountKey: String) {
        do {
            try Disk.removeSavedAccountDirectory(
                accountKey: accountKey,
                codexHomeURL: codexHomeURL
            )
        } catch {
            // The registry replace is the product commit. A stale account directory
            // is unreferenced data and is collected by the next load; it cannot roll
            // a committed account selection back into the UI.
            logger.error(
                "Committed account removal left cleanup debt for \(accountKey, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func recordReconciliationDebt(
        expectedAccount: ExpectedRuntimeAccount,
        message: String
    ) throws {
        try Disk.recordReconciliationDebt(
            expectedAccount: expectedAccount,
            message: message,
            codexHomeURL: codexHomeURL,
            directoryDurabilityDidSynchronize: directoryDurabilityDidSynchronize
        )
    }

    func reconciliationDebtExpectation() throws -> ExpectedRuntimeAccount? {
        try Disk.reconciliationDebtExpectation(codexHomeURL: codexHomeURL)
    }

    func clearReconciliationDebt() throws {
        try Disk.clearReconciliationDebt(codexHomeURL: codexHomeURL)
    }

    func reserveTemporaryCodexHome(kind: TemporaryCodexHomeKind) throws -> URL {
        try Disk.reserveTemporaryCodexHome(kind: kind, codexHomeURL: codexHomeURL)
    }

    func finishTemporaryCodexHome(_ url: URL) {
        do {
            try Disk.finishTemporaryCodexHome(
                url,
                codexHomeURL: codexHomeURL,
                directoryDurabilityDidSynchronize: directoryDurabilityDidSynchronize
            )
        } catch {
            preconditionFailure(
                "Credential-bearing temporary home cleanup debt must be durable: \(error.localizedDescription)"
            )
        }
    }

    func copySavedAuth(accountKey: String, to destinationCodexHomeURL: URL) throws -> Bool {
        try requireNoAccountMutationForBackgroundPersistence()
        return try Disk.copySavedAuth(
            accountKey: accountKey,
            from: codexHomeURL,
            to: destinationCodexHomeURL
        )
    }

    func beginAuthenticationMutation(request: LoginRequest) async throws -> AuthenticationMutation {
        if let activeMutation {
            switch activeMutation.kind {
            case .authentication:
                throw CodexReviewAuthenticationFailure.alreadyInProgress
            case .account:
                throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
            }
        }
        let snapshot = try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
        let purpose: LoginPurpose = switch request {
        case .signIn:
            .signIn
        case .addAccount:
            snapshot.activeAccountKey == nil ? .signIn : .addAccountPreservingActive
        }
        let mutation = AuthenticationMutation(
            lease: installMutation(kind: .authentication),
            purpose: purpose,
            previousActiveAccountKey: snapshot.activeAccountKey
        )
        await authenticationMutationDidBegin?()
        return mutation
    }

    func beginAccountMutation() async throws -> AccountMutation {
        guard activeMutation == nil else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
        let lease = installMutation(kind: .account)
        await loadDidBegin?()
        do {
            let before = try Disk.loadSnapshotWithoutMaintenance(codexHomeURL: codexHomeURL)
            return .init(lease: lease, before: before)
        } catch {
            precondition(activeMutation?.lease == lease)
            activeMutation = nil
            throw error
        }
    }

    func finishMutation(_ lease: MutationLease) {
        precondition(activeMutation?.lease == lease, "Only the active account mutation owner can release its lease.")
        activeMutation = nil
    }

    func requestAuthenticationCancellation(_ lease: MutationLease) async {
        guard activeMutation?.lease == lease,
              activeMutation?.kind == .authentication else {
            return
        }
        if activeMutation?.productCommitClaimed == false {
            activeMutation?.cancellationRequested = true
        }
        await authenticationCancellationDidRequest?()
    }

    private func installMutation(kind: MutationKind) -> MutationLease {
        let lease = MutationLease(id: UUID())
        activeMutation = (
            lease: lease,
            kind: kind,
            cancellationRequested: false,
            productCommitClaimed: false
        )
        return lease
    }

    private func claimAuthenticationProductCommit(_ lease: MutationLease) -> Bool {
        guard activeMutation?.lease == lease,
              activeMutation?.kind == .authentication else {
            preconditionFailure("Only the active authentication lease can claim its product commit.")
        }
        guard activeMutation?.cancellationRequested == false else {
            return false
        }
        activeMutation?.productCommitClaimed = true
        return true
    }

    private func requireNoAccountMutationForBackgroundPersistence() throws {
        guard activeMutation == nil else {
            throw CodexReviewAuthenticationFailure.accountCommit(
                message: "Background account metadata persistence is blocked while an account mutation or authentication is in progress."
            )
        }
    }

    private func requireMutationAuthorization(
        _ authorization: MutationLease?
    ) throws {
        guard let activeMutation else {
            guard authorization == nil else {
                preconditionFailure("A released account mutation lease cannot authorize registry work.")
            }
            return
        }
        guard authorization == activeMutation.lease else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
    }

    private func requireRuntimeAuthorization(
        _ authorization: RuntimeCommitAuthorization?
    ) throws {
        guard let authorization else {
            return
        }
        guard activeRuntimeGeneration == authorization.generation else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
    }
}

extension AccountRegistryStore.Snapshot {
    var expectedRuntimeAccount: ExpectedRuntimeAccount {
        guard let activeAccountKey else {
            return .signedOut
        }
        guard let account = accounts.first(where: {
            $0.accountKey == activeAccountKey
        }) else {
            preconditionFailure("An active account registry snapshot requires its account payload.")
        }
        return .observedAccount(
            accountKey: activeAccountKey,
            provider: .init(account.kind)
        )
    }
}
