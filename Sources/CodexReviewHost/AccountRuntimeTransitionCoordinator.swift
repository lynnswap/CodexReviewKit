import Foundation
import CodexReviewKit

enum ExpectedRuntimeAccount: Equatable, Sendable {
    enum Provider: String, Codable, Equatable, Sendable {
        case chatGPT
        case apiKey
        case amazonBedrock

        init(_ kind: CodexReviewBackendModel.Account.Kind) {
            switch kind {
            case .chatGPT:
                self = .chatGPT
            case .apiKey:
                self = .apiKey
            case .amazonBedrock:
                self = .amazonBedrock
            }
        }

        var accountKind: CodexReviewBackendModel.Account.Kind {
            switch self {
            case .chatGPT:
                .chatGPT
            case .apiKey:
                .apiKey
            case .amazonBedrock:
                .amazonBedrock
            }
        }
    }

    case signedOut
    case account(String)
    case observedAccount(accountKey: String, provider: Provider)
    case anyChatGPT
    case cancelOutcomeUnknown(previousActiveAccountKey: String?)
    case reconcileCurrentRuntime
}

@MainActor
final class AccountRuntimeTransitionCoordinator {
    @MainActor
    private final class FinalShutdownCompletion {
        private var result: Bool?
        private var waiters: [CheckedContinuation<Bool, Never>] = []

        func wait() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func resolve(_ result: Bool) {
            precondition(self.result == nil)
            self.result = result
            let waiters = waiters
            self.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume(returning: result) }
        }
    }

    @MainActor
    private final class PrimaryReconciliationCompletion {
        private var isResolved = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isResolved { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func resolve() {
            precondition(isResolved == false)
            isResolved = true
            let waiters = waiters
            self.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
        }
    }

    enum AccountMutationPhase: Equatable, Sendable {
        case preEffect
        case effectClaimed
        case effectApplied
        case registryCommitted
        case replacementValidating
    }

    enum EffectClaim: Sendable {
        case apply
        case abortForFinalShutdown
    }

    enum PublicationClaim: Equatable, Sendable {
        case published
        case quiescent
    }

    enum PrimaryReconciliationAdmission: Sendable {
        case accepted
        case deferUntilRuntimeStop
    }

    enum PrimaryLoginReconciliationHandoff: Sendable {
        case handedOff
        case deferUntilRuntimeStop
    }

    struct AccountTransition: Sendable {
        fileprivate let id: UUID
    }

    struct PrimaryReconciliationReservation: Sendable {
        fileprivate let id: UUID
    }

    struct ExplicitRuntimeStart: Sendable {
        fileprivate let id: UUID
    }

    struct RuntimeAuthReconciliation: Sendable {
        fileprivate let id: UUID
        fileprivate let generation: UInt64
    }

    struct LoginAdmission: Sendable {
        fileprivate let id: UUID
    }

    private enum ActiveTransition {
        enum RuntimeAuthPhase {
            case reading
            case registryEffectClaimed
        }

        case account(id: UUID, phase: AccountMutationPhase)
        case primaryReconciliation(id: UUID, completion: PrimaryReconciliationCompletion)
        case explicitRuntimeStart(id: UUID, repairsReconciliation: Bool, commitClaimed: Bool)
        case runtimeAuthReconciliation(
            id: UUID,
            generation: UInt64,
            phase: RuntimeAuthPhase
        )
        case loginAdmission(id: UUID)
        case primaryLogin(id: UUID)

        var id: UUID {
            switch self {
            case .account(let id, _),
                 .primaryReconciliation(let id, _),
                 .explicitRuntimeStart(let id, _, _),
                 .runtimeAuthReconciliation(let id, _, _),
                 .loginAdmission(let id),
                 .primaryLogin(let id):
                return id
            }
        }
    }

    private var activeTransition: ActiveTransition?
    private var transitionCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var finalShutdownRequested = false
    private var finalShutdownCompleted = false
    private var finalShutdownCompletion: FinalShutdownCompletion?
    private var reconciliationFailed = false
    private var supersededExplicitRuntimeStarts: Set<UUID> = []
    private var supersededRuntimeAuthReconciliations: Set<UUID> = []
    private var supersededPrimaryLogins: Set<UUID> = []
    private struct PendingPrimaryReconciliation {
        let reservation: PrimaryReconciliationReservation
        let completion: PrimaryReconciliationCompletion
        let operation: @MainActor @Sendable (
            PrimaryReconciliationReservation
        ) async -> Void
    }

    private var pendingPrimaryReconciliation: PendingPrimaryReconciliation?
    private let finalShutdownDidRequest: CodexReviewFinalShutdownDidRequest?
    private var didBecomeIdle: (@MainActor @Sendable () -> Void)?

    init(finalShutdownDidRequest: CodexReviewFinalShutdownDidRequest? = nil) {
        self.finalShutdownDidRequest = finalShutdownDidRequest
    }

    func installDidBecomeIdle(
        _ operation: @escaping @MainActor @Sendable () -> Void
    ) {
        precondition(didBecomeIdle == nil)
        didBecomeIdle = operation
    }

    func perform<T>(
        _ operation: (AccountTransition) async throws -> T
    ) async throws -> T {
        guard activeTransition == nil,
              finalShutdownRequested == false,
              finalShutdownCompleted == false,
              reconciliationFailed == false else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
        let id = UUID()
        activeTransition = .account(id: id, phase: .preEffect)
        defer { finishTransition(id: id) }
        return try await operation(.init(id: id))
    }

    func reserveLoginAdmission() throws -> LoginAdmission {
        guard activeTransition == nil,
              canPublish else {
            throw CodexReviewAuthenticationFailure.accountMutationBlockedByAuthentication
        }
        let id = UUID()
        activeTransition = .loginAdmission(id: id)
        return .init(id: id)
    }

    func canCommitLoginAdmission(_ admission: LoginAdmission) -> Bool {
        guard case .loginAdmission(let id) = activeTransition,
              id == admission.id else {
            return false
        }
        return canPublish
    }

    func finishLoginAdmission(_ admission: LoginAdmission) {
        guard case .loginAdmission(let id) = activeTransition,
              id == admission.id else {
            preconditionFailure("Only the active login admission can finish.")
        }
        finishTransition(id: id)
    }

    func retainPrimaryLoginAdmission(_ admission: LoginAdmission) {
        guard case .loginAdmission(let id) = activeTransition,
              id == admission.id else {
            preconditionFailure("Only the active login admission can retain primary runtime ownership.")
        }
        activeTransition = .primaryLogin(id: id)
    }

    func claimPrimaryLoginResultPublication(
        _ admission: LoginAdmission
    ) -> Bool {
        guard case .primaryLogin(let id) = activeTransition,
              id == admission.id else {
            return false
        }
        return canPublish
    }

    func finishPrimaryLoginAdmission(_ admission: LoginAdmission) {
        guard case .primaryLogin(let id) = activeTransition,
              id == admission.id else {
            if supersededPrimaryLogins.remove(admission.id) != nil {
                return
            }
            preconditionFailure("Only the active primary login can release runtime ownership.")
        }
        finishTransition(id: id)
    }

    func commitPrimaryLoginReconciliationFailure(
        _ admission: LoginAdmission
    ) -> Bool {
        guard case .primaryLogin(let id) = activeTransition,
              id == admission.id else {
            if supersededPrimaryLogins.contains(admission.id) {
                return false
            }
            preconditionFailure("Only the active primary login can fail reconciliation closed.")
        }
        return commitReconciliationFailureIfPublishable()
    }

    func handoffPrimaryLoginToReconciliation(
        _ admission: LoginAdmission,
        operation: @escaping @MainActor @Sendable (
            PrimaryReconciliationReservation
        ) async -> Void
    ) -> PrimaryLoginReconciliationHandoff {
        guard case .primaryLogin(let id) = activeTransition,
              id == admission.id else {
            if supersededPrimaryLogins.contains(admission.id)
                || finalShutdownRequested
                || finalShutdownCompleted {
                return .deferUntilRuntimeStop
            }
            preconditionFailure("Only the active primary login can hand off reconciliation ownership.")
        }
        guard canPublish else {
            return .deferUntilRuntimeStop
        }
        activeTransition = nil
        startPrimaryReconciliation(operation)
        return .handedOff
    }

    func claimEffect(_ transition: AccountTransition) -> EffectClaim {
        guard case .account(let id, .preEffect) = activeTransition,
              id == transition.id else {
            preconditionFailure("An account transition can claim its external effect only once.")
        }
        guard finalShutdownRequested == false else {
            return .abortForFinalShutdown
        }
        activeTransition = .account(id: id, phase: .effectClaimed)
        return .apply
    }

    func recordEffectApplied(_ transition: AccountTransition) {
        guard case .account(let id, .effectClaimed) = activeTransition,
              id == transition.id else {
            preconditionFailure("Only a claimed account effect can be recorded as applied.")
        }
        activeTransition = .account(id: id, phase: .effectApplied)
    }

    func recordEffectAborted(_ transition: AccountTransition) {
        guard case .account(let id, .effectClaimed) = activeTransition,
              id == transition.id else {
            preconditionFailure("Only a claimed account effect can be restored before application.")
        }
        activeTransition = .account(id: id, phase: .preEffect)
    }

    func recordRegistryCommit(_ transition: AccountTransition) {
        guard case .account(let id, let phase) = activeTransition,
              id == transition.id,
              phase == .effectClaimed || phase == .effectApplied else {
            preconditionFailure("A registry commit requires a claimed or applied account effect.")
        }
        activeTransition = .account(id: id, phase: .registryCommitted)
    }

    func claimPublication(_ transition: AccountTransition) -> PublicationClaim {
        guard case .account(let id, .registryCommitted) = activeTransition,
              id == transition.id else {
            preconditionFailure("Only a committed account transition can claim replacement publication.")
        }
        activeTransition = .account(id: id, phase: .replacementValidating)
        return publicationClaim
    }

    func claimPreEffectRecovery(_ transition: AccountTransition) -> PublicationClaim {
        guard case .account(let id, .preEffect) = activeTransition,
              id == transition.id else {
            preconditionFailure("Only a pre-effect account transition can recover its previous runtime.")
        }
        return publicationClaim
    }

    func commitAccountReconciliationFailure(_ transition: AccountTransition) -> Bool {
        guard case .account(let id, _) = activeTransition,
              id == transition.id else {
            preconditionFailure("Only the active account transition can record reconciliation failure.")
        }
        return commitReconciliationFailureIfPublishable()
    }

    func commitPrimaryReconciliationFailure(
        _ reservation: PrimaryReconciliationReservation
    ) -> Bool {
        guard case .primaryReconciliation(let id, _) = activeTransition,
              id == reservation.id else {
            preconditionFailure("Only the active primary reconciliation can record reconciliation failure.")
        }
        return commitReconciliationFailureIfPublishable()
    }

    func commitUnownedReconciliationFailure() -> Bool {
        guard activeTransition == nil else {
            return false
        }
        return commitReconciliationFailureIfPublishable()
    }

    func shouldStageRuntimePublication(_ transition: AccountTransition) -> Bool {
        guard case .account(let id, let phase) = activeTransition,
              id == transition.id,
              phase == .preEffect || phase == .replacementValidating else {
            return false
        }
        return canPublish
    }

    func claimRuntimePublication(_ transition: AccountTransition) -> Bool {
        shouldStageRuntimePublication(transition)
    }

    func primaryPublicationClaim(
        _ reservation: PrimaryReconciliationReservation
    ) -> PublicationClaim {
        guard case .primaryReconciliation(let id, _) = activeTransition,
              id == reservation.id else {
            preconditionFailure("Only the active primary reconciliation can choose runtime publication.")
        }
        return publicationClaim
    }

    func shouldStageRuntimePublication(
        _ reservation: PrimaryReconciliationReservation
    ) -> Bool {
        guard case .primaryReconciliation(let id, _) = activeTransition,
              id == reservation.id else {
            return false
        }
        return canPublish
    }

    func claimRuntimePublication(
        _ reservation: PrimaryReconciliationReservation
    ) -> Bool {
        shouldStageRuntimePublication(reservation)
    }

    func commitLoginResultPublication() -> Bool {
        guard activeTransition == nil else {
            return false
        }
        return canPublish
    }

    func reserveRuntimeAuthReconciliation(
        generation: UInt64
    ) -> RuntimeAuthReconciliation? {
        guard activeTransition == nil, canPublish else {
            return nil
        }
        let id = UUID()
        activeTransition = .runtimeAuthReconciliation(
            id: id,
            generation: generation,
            phase: .reading
        )
        return .init(id: id, generation: generation)
    }

    func claimRuntimeAuthRegistryEffect(
        _ reconciliation: RuntimeAuthReconciliation
    ) -> Bool {
        guard case .runtimeAuthReconciliation(
            let id,
            let generation,
            .reading
        ) = activeTransition,
              id == reconciliation.id,
              generation == reconciliation.generation else {
            return false
        }
        guard canPublish else {
            return false
        }
        activeTransition = .runtimeAuthReconciliation(
            id: id,
            generation: generation,
            phase: .registryEffectClaimed
        )
        return true
    }

    func canPublishRuntimeAuthReadResult(
        _ reconciliation: RuntimeAuthReconciliation
    ) -> Bool {
        guard case .runtimeAuthReconciliation(
            let id,
            let generation,
            .reading
        ) = activeTransition,
              id == reconciliation.id,
              generation == reconciliation.generation else {
            return false
        }
        return canPublish
    }

    func continueRuntimeAuthReadingAfterRegistryCommit(
        _ reconciliation: RuntimeAuthReconciliation
    ) -> Bool {
        guard case .runtimeAuthReconciliation(
            let id,
            let generation,
            .registryEffectClaimed
        ) = activeTransition,
              id == reconciliation.id,
              generation == reconciliation.generation else {
            preconditionFailure("Only a committed runtime authentication effect can continue reading.")
        }
        guard canPublish else {
            supersededRuntimeAuthReconciliations.insert(id)
            finishTransition(id: id)
            return false
        }
        activeTransition = .runtimeAuthReconciliation(
            id: id,
            generation: generation,
            phase: .reading
        )
        return true
    }

    func claimRuntimeAuthReconciliationPublication(
        _ reconciliation: RuntimeAuthReconciliation
    ) -> PublicationClaim {
        guard case .runtimeAuthReconciliation(
            let id,
            let generation,
            .registryEffectClaimed
        ) = activeTransition,
              id == reconciliation.id,
              generation == reconciliation.generation else {
            preconditionFailure("Only the active runtime authentication reconciliation can publish.")
        }
        return publicationClaim
    }

    func commitRuntimeAuthReconciliationFailure(
        _ reconciliation: RuntimeAuthReconciliation
    ) -> Bool {
        guard case .runtimeAuthReconciliation(
            let id,
            let generation,
            _
        ) = activeTransition,
              id == reconciliation.id,
              generation == reconciliation.generation else {
            if supersededRuntimeAuthReconciliations.contains(reconciliation.id) {
                return false
            }
            preconditionFailure("Only the active runtime authentication reconciliation can fail closed.")
        }
        return commitReconciliationFailureIfPublishable()
    }

    func finishRuntimeAuthReconciliation(_ reconciliation: RuntimeAuthReconciliation) {
        guard case .runtimeAuthReconciliation(
            let id,
            let generation,
            _
        ) = activeTransition,
              id == reconciliation.id,
              generation == reconciliation.generation else {
            if supersededRuntimeAuthReconciliations.remove(reconciliation.id) != nil {
                return
            }
            preconditionFailure("Only the active runtime authentication reconciliation can finish.")
        }
        finishTransition(id: id)
    }

    var acceptsNewOperations: Bool {
        activeTransition == nil
            && finalShutdownRequested == false
            && finalShutdownCompleted == false
            && reconciliationFailed == false
    }

    var hasActiveLoginTransition: Bool {
        switch activeTransition {
        case .loginAdmission, .primaryLogin:
            true
        case .account, .primaryReconciliation, .explicitRuntimeStart,
             .runtimeAuthReconciliation, nil:
            false
        }
    }

    func admitPrimaryReconciliation(
        _ operation: @escaping @MainActor @Sendable (
            PrimaryReconciliationReservation
        ) async -> Void
    ) -> PrimaryReconciliationAdmission {
        if case .account = activeTransition {
            guard pendingPrimaryReconciliation == nil else {
                preconditionFailure("Only one primary authentication reconciliation can queue behind an account transition.")
            }
            pendingPrimaryReconciliation = makePendingPrimaryReconciliation(operation)
            return .accepted
        }
        guard activeTransition == nil,
              finalShutdownRequested == false,
              finalShutdownCompleted == false,
              reconciliationFailed == false else {
            return .deferUntilRuntimeStop
        }
        startPrimaryReconciliation(operation)
        return .accepted
    }

    func performStoppedPrimaryReconciliation(
        _ operation: @escaping @MainActor @Sendable (
            PrimaryReconciliationReservation
        ) async -> Void
    ) async {
        let pending = makePendingPrimaryReconciliation(operation)
        if case .account = activeTransition {
            guard pendingPrimaryReconciliation == nil else {
                preconditionFailure("Only one stopped primary reconciliation can queue behind an account transition.")
            }
            pendingPrimaryReconciliation = pending
        } else {
            guard activeTransition == nil,
                  finalShutdownCompleted == false else {
                preconditionFailure("A stopped primary reconciliation requires coordinator ownership before final completion.")
            }
            startPrimaryReconciliation(pending)
        }
        await pending.completion.wait()
    }

    func performFinalShutdown(
        _ operation: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Bool {
        if let finalShutdownCompletion {
            return await finalShutdownCompletion.wait()
        }
        if finalShutdownCompleted {
            return true
        }
        let completion = FinalShutdownCompletion()
        finalShutdownCompletion = completion
        if finalShutdownRequested == false {
            finalShutdownRequested = true
            await finalShutdownDidRequest?()
        }
        while activeTransition != nil {
            if case .explicitRuntimeStart(let id, _, commitClaimed: false) = activeTransition {
                supersededExplicitRuntimeStarts.insert(id)
                finishTransition(id: id)
                break
            }
            if case .runtimeAuthReconciliation(
                let id,
                _,
                .reading
            ) = activeTransition {
                supersededRuntimeAuthReconciliations.insert(id)
                finishTransition(id: id)
                break
            }
            if case .primaryLogin(let id) = activeTransition {
                supersededPrimaryLogins.insert(id)
                finishTransition(id: id)
                break
            }
            await waitForTransitionCompletion()
        }
        if finalShutdownCompleted {
            completion.resolve(true)
            finalShutdownCompletion = nil
            return true
        }
        let didComplete = await operation()
        finalShutdownCompleted = didComplete
        completion.resolve(didComplete)
        finalShutdownCompletion = nil
        return didComplete
    }

    func waitForFinalShutdownCompletionIfRequested() async {
        guard let finalShutdownCompletion else {
            return
        }
        _ = await finalShutdownCompletion.wait()
    }

    var isFinalShutdownRequested: Bool {
        finalShutdownRequested
    }

    func prepareForExplicitRuntimeStart() -> ExplicitRuntimeStart? {
        guard activeTransition == nil,
              finalShutdownCompletion == nil else {
            return nil
        }
        if finalShutdownCompleted {
            finalShutdownRequested = false
            finalShutdownCompleted = false
        }
        guard finalShutdownRequested == false else {
            return nil
        }
        let id = UUID()
        activeTransition = .explicitRuntimeStart(
            id: id,
            repairsReconciliation: reconciliationFailed,
            commitClaimed: false
        )
        return .init(id: id)
    }

    func shouldStageExplicitRuntimeStart(_ start: ExplicitRuntimeStart) -> Bool {
        guard case .explicitRuntimeStart(let id, _, let commitClaimed) = activeTransition,
              id == start.id else {
            return false
        }
        return commitClaimed || (finalShutdownRequested == false && finalShutdownCompleted == false)
    }

    func explicitRuntimeStartRequiresRepair(_ start: ExplicitRuntimeStart) -> Bool {
        guard case .explicitRuntimeStart(let id, let repairsReconciliation, _) = activeTransition,
              id == start.id else {
            return false
        }
        return repairsReconciliation
    }

    func claimExplicitRuntimeStartCommit(_ start: ExplicitRuntimeStart) -> Bool {
        guard case .explicitRuntimeStart(let id, let repairsReconciliation, let commitClaimed) = activeTransition,
              id == start.id else {
            return false
        }
        if commitClaimed {
            return true
        }
        guard finalShutdownRequested == false,
              finalShutdownCompleted == false else {
            return false
        }
        activeTransition = .explicitRuntimeStart(
            id: id,
            repairsReconciliation: repairsReconciliation,
            commitClaimed: true
        )
        return true
    }

    func finishExplicitRuntimeStart(
        _ start: ExplicitRuntimeStart,
        didCommitActiveRuntime: Bool
    ) {
        guard case .explicitRuntimeStart(let id, let repairsReconciliation, let commitClaimed) = activeTransition,
              id == start.id else {
            if supersededExplicitRuntimeStarts.remove(start.id) != nil {
                return
            }
            preconditionFailure("Only the active explicit runtime start can finish.")
        }
        if repairsReconciliation, didCommitActiveRuntime {
            precondition(commitClaimed, "A reconciliation repair can clear failure only after claiming its runtime commit.")
            reconciliationFailed = false
        }
        finishTransition(id: id)
    }

    func commitExplicitRuntimeStartFailure(_ start: ExplicitRuntimeStart) -> Bool {
        guard case .explicitRuntimeStart(let id, _, _) = activeTransition,
              id == start.id else {
            return false
        }
        return commitReconciliationFailureIfPublishable()
    }

    private var publicationClaim: PublicationClaim {
        canPublish ? .published : .quiescent
    }

    private var canPublish: Bool {
        finalShutdownRequested == false
            && finalShutdownCompleted == false
            && reconciliationFailed == false
    }

    private func commitReconciliationFailureIfPublishable() -> Bool {
        guard finalShutdownRequested == false,
              finalShutdownCompleted == false else {
            return false
        }
        reconciliationFailed = true
        return true
    }

    private func waitForTransitionCompletion() async {
        guard activeTransition != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            transitionCompletionWaiters.append(continuation)
        }
    }

    private func finishTransition(id: UUID) {
        guard activeTransition?.id == id else {
            preconditionFailure("Only the active account runtime transition can finish.")
        }
        if case .account = activeTransition,
           let pendingPrimaryReconciliation {
            self.pendingPrimaryReconciliation = nil
            activeTransition = nil
            startPrimaryReconciliation(pendingPrimaryReconciliation)
            return
        }
        let primaryReconciliationCompletion: PrimaryReconciliationCompletion? =
            if case .primaryReconciliation(_, let completion) = activeTransition {
                completion
            } else {
                nil
            }
        activeTransition = nil
        primaryReconciliationCompletion?.resolve()
        let waiters = transitionCompletionWaiters
        transitionCompletionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        didBecomeIdle?()
    }

    private func startPrimaryReconciliation(
        _ operation: @escaping @MainActor @Sendable (
            PrimaryReconciliationReservation
        ) async -> Void
    ) {
        startPrimaryReconciliation(makePendingPrimaryReconciliation(operation))
    }

    private func makePendingPrimaryReconciliation(
        _ operation: @escaping @MainActor @Sendable (
            PrimaryReconciliationReservation
        ) async -> Void
    ) -> PendingPrimaryReconciliation {
        let id = UUID()
        return .init(
            reservation: .init(id: id),
            completion: .init(),
            operation: operation
        )
    }

    private func startPrimaryReconciliation(
        _ pending: PendingPrimaryReconciliation
    ) {
        precondition(activeTransition == nil)
        let id = pending.reservation.id
        activeTransition = .primaryReconciliation(
            id: id,
            completion: pending.completion
        )
        Task { @MainActor [weak self] in
            await pending.operation(pending.reservation)
            self?.finishTransition(id: id)
        }
    }
}
