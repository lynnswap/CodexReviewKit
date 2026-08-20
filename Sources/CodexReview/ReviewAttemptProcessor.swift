import Foundation

package struct ReviewRuntimeClosePolicy: Sendable {
    package var terminalGrace: Duration
    package var sleep: @Sendable (Duration) async throws -> Void

    package init(
        terminalGrace: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.terminalGrace = terminalGrace
        self.sleep = sleep
    }

    package static let production = Self(
        terminalGrace: .seconds(10),
        sleep: { try await Task.sleep(for: $0) }
    )
}

package enum ReviewInterruptRequestOutcome: Equatable, Sendable {
    case rejected(code: Int?, message: String)
    case outcomeUnknown(message: String)
}

package struct ReviewInterruptRequestFailure: LocalizedError, Equatable, Sendable {
    package var outcome: ReviewInterruptRequestOutcome
    package var secondaryBarrierDiagnostic: String?

    package init(
        outcome: ReviewInterruptRequestOutcome,
        secondaryBarrierDiagnostic: String? = nil
    ) {
        self.outcome = outcome
        self.secondaryBarrierDiagnostic = secondaryBarrierDiagnostic
    }

    package var errorDescription: String? {
        switch outcome {
        case .rejected(_, let message), .outcomeUnknown(let message):
            message
        }
    }
}

package enum ReviewRuntimeCloseFailure: LocalizedError, Equatable, Sendable {
    case connection(String)
    case process(String)
    case worker(String)
    case cleanup(String)
    case mcpHandlerDrain(String)

    package var errorDescription: String? {
        switch self {
        case .connection(let message):
            "App-server connection close failed: \(message)"
        case .process(let message):
            "App-server process close failed: \(message)"
        case .worker(let message):
            "Review worker close failed: \(message)"
        case .cleanup(let message):
            "Review cleanup failed: \(message)"
        case .mcpHandlerDrain(let message):
            "MCP handler drain failed: \(message)"
        }
    }
}

package struct ReviewAttemptContractFailure: LocalizedError, Equatable, Sendable {
    package var message: String

    package init(message: String) {
        self.message = message
    }

    package var errorDescription: String? { message }
}

package struct ReviewStartCancelledBeforeDispatch: LocalizedError, Equatable, Sendable {
    package var cancellation: ReviewCancellation

    package init(cancellation: ReviewCancellation) {
        self.cancellation = cancellation
    }

    package var errorDescription: String? { cancellation.message }
}

package struct ReviewStartTerminatedBeforeActivation: LocalizedError, Equatable, Sendable {
    package let terminal: ReviewAttemptBarrierTerminal

    package init(terminal: ReviewAttemptBarrierTerminal) {
        self.terminal = terminal
    }

    package var errorDescription: String? {
        "Review start was resolved before activation: \(terminal.diagnosticDescription)."
    }
}

package enum ReviewAttemptRecoveryTrigger: Equatable, Sendable {
    case sameAccountRestart
    case recoverableNetworkLoss

    fileprivate var cancellation: ReviewCancellation {
        switch self {
        case .sameAccountRestart:
            .system(message: "Review runtime is restarting.")
        case .recoverableNetworkLoss:
            .system(message: "Network unavailable; waiting to reconnect.")
        }
    }
}

package enum ReviewAttemptInterruptionPurpose: Equatable, Sendable {
    case terminalCancellation(ReviewCancellation)
    case recoverableTransition(ReviewAttemptRecoveryTrigger)
}

package enum ReviewAttemptStreamFailure: LocalizedError, Equatable, Sendable {
    case recoverableNetwork(ReviewRuntimeCloseFailure)
    case ownerForcedConnectionClose(ReviewRuntimeCloseFailure)
    case unexpectedConnection(ReviewRuntimeCloseFailure)
    case process(ReviewRuntimeCloseFailure)
    case protocolViolation(ReviewAttemptContractFailure)
    case workerContract(ReviewAttemptContractFailure)
    case ownerCancellation

    package var errorDescription: String? {
        switch self {
        case .recoverableNetwork(let failure),
             .ownerForcedConnectionClose(let failure),
             .unexpectedConnection(let failure),
             .process(let failure):
            failure.localizedDescription
        case .protocolViolation(let failure), .workerContract(let failure):
            failure.localizedDescription
        case .ownerCancellation:
            "Review event owner was cancelled before an attempt terminal."
        }
    }

    package var permitsRecoveryReplacement: Bool {
        switch self {
        case .recoverableNetwork, .ownerForcedConnectionClose:
            true
        case .unexpectedConnection, .process, .protocolViolation,
             .workerContract, .ownerCancellation:
            false
        }
    }
}

package enum ReviewAttemptBarrierTerminal: Equatable, Sendable {
    case canonical(ReviewTerminalRecord)
    case stream(ReviewAttemptStreamFailure)
    case localCancellation(ReviewCancellation)

    package var diagnosticDescription: String {
        switch self {
        case .canonical(let terminal):
            "canonical terminal \(terminal.kind.rawValue)"
        case .stream(let failure):
            failure.localizedDescription
        case .localCancellation(let cancellation):
            cancellation.message
        }
    }
}

package struct ReviewAttemptCancellationResolution: Equatable, Sendable {
    package var terminal: ReviewAttemptBarrierTerminal
    package var requestFailure: ReviewInterruptRequestFailure?

    package init(
        terminal: ReviewAttemptBarrierTerminal,
        requestFailure: ReviewInterruptRequestFailure? = nil
    ) {
        self.terminal = terminal
        self.requestFailure = requestFailure
    }
}

package struct ReviewResolvedAttemptTerminal: Equatable, Sendable {
    package let run: CodexReviewBackendModel.Review.Run
    package let terminal: ReviewAttemptBarrierTerminal
    package let requestFailure: ReviewInterruptRequestFailure?

    fileprivate init(
        run: CodexReviewBackendModel.Review.Run,
        terminal: ReviewAttemptBarrierTerminal,
        requestFailure: ReviewInterruptRequestFailure?
    ) {
        self.run = run
        self.terminal = terminal
        self.requestFailure = requestFailure
    }
}

package struct ReviewRecoveryCandidate: Equatable, Sendable {
    package let resolved: ReviewResolvedAttemptTerminal
    package let trigger: ReviewAttemptRecoveryTrigger

    fileprivate init(
        resolved: ReviewResolvedAttemptTerminal,
        trigger: ReviewAttemptRecoveryTrigger
    ) {
        self.resolved = resolved
        self.trigger = trigger
    }
}

package struct ReviewProductTerminalDisposition: Equatable, Sendable {
    package let resolved: ReviewResolvedAttemptTerminal
    package let productTerminal: ReviewTerminalRecord

    fileprivate init(
        resolved: ReviewResolvedAttemptTerminal,
        productTerminal: ReviewTerminalRecord
    ) {
        self.resolved = resolved
        self.productTerminal = productTerminal
    }
}

package enum ReviewRecoveryDisposition: Equatable, Sendable {
    case productTerminal(ReviewProductTerminalDisposition)
    case replacement(ReviewRecoveryCandidate)

    package var resolvedAttempt: ReviewResolvedAttemptTerminal {
        switch self {
        case .productTerminal(let disposition):
            disposition.resolved
        case .replacement(let candidate):
            candidate.resolved
        }
    }
}

package struct ReviewRecoveryHandoff: Equatable, Sendable {
    package let candidate: ReviewRecoveryCandidate
    package let token: CodexReviewBackendModel.Review.RecoveryToken

    package init(
        candidate: ReviewRecoveryCandidate,
        token: CodexReviewBackendModel.Review.RecoveryToken
    ) {
        self.candidate = candidate
        self.token = token
    }
}

package struct ReviewActiveAttempt: Sendable {
    package let run: CodexReviewBackendModel.Review.Run
    package let admission: ReviewStartAdmission

    package init(
        run: CodexReviewBackendModel.Review.Run,
        admission: ReviewStartAdmission
    ) {
        self.run = run
        self.admission = admission
    }
}

package struct ReviewStartHandleID: Hashable, Sendable {
    package let generation: UInt64

    package init(generation: UInt64) {
        self.generation = generation
    }
}

package struct ReviewRegisteredStart: Sendable {
    package let id: ReviewStartHandleID
    package let admission: ReviewStartAdmission
    package let task: Task<BackendReviewAttempt, any Error>

    package init(
        id: ReviewStartHandleID,
        admission: ReviewStartAdmission,
        task: Task<BackendReviewAttempt, any Error>
    ) {
        self.id = id
        self.admission = admission
        self.task = task
    }
}

package enum ReviewAttemptOwnership: Sendable {
    case initialStart(ReviewRegisteredStart)
    case active(ReviewActiveAttempt)
    case resolvingRecovery(ReviewActiveAttempt)
    case recoveryDisposition(ReviewRecoveryDisposition)
    case preparingRecovery(
        candidate: ReviewRecoveryCandidate,
        preparationTask: Task<ReviewRecoveryHandoff, any Error>
    )
    case waitingForRecovery(ReviewRecoveryHandoff)
    case replacementStart(
        handoff: ReviewRecoveryHandoff,
        start: ReviewRegisteredStart
    )
    case terminal
}

/// Owns one review attempt from the first dispatch admission through terminal and cleanup.
/// Store cancellation and backend request dispatch both consult this actor; there is no
/// call-site startup-cancellation mirror.
package actor ReviewStartAdmission {
    package enum RequestDispatch: Equatable, Sendable {
        case notSent
        case outcomeUnknown
    }

    package enum Phase: Equatable, Sendable {
        case queued
        case registeredStart(ReviewStartHandleID)
        case activatedStart(ReviewStartHandleID)
        case preparingThread(RequestDispatch)
        case startingReview(
            preparedRun: CodexReviewBackendModel.Review.Run,
            dispatch: RequestDispatch
        )
        case active(CodexReviewBackendModel.Review.Run)
        case interrupting(CodexReviewBackendModel.Review.Run)
        case finishing(ReviewAttemptBarrierTerminal)
        case terminal(ReviewAttemptBarrierTerminal)
    }

    private enum CancellationTaskEvent {
        case request(Result<Void, ReviewInterruptRequestFailure>)
        case barrier(ReviewAttemptBarrierTerminal)
        case graceExpired
        case forceClose(Result<Void, ReviewRuntimeCloseFailure>)
    }

    private let closePolicy: ReviewRuntimeClosePolicy
    private var phase: Phase = .queued
    private var requestedCancellation: ReviewCancellation?
    private var joinedTerminalCancellation: ReviewCancellation?
    private var interruptionPurpose: ReviewAttemptInterruptionPurpose?
    private var startTask: Task<BackendReviewAttempt, any Error>?
    private var startDidFinish = false
    private var nextStartGeneration: UInt64 = 0
    private var registeredStartID: ReviewStartHandleID?
    private var startActivationResult: Result<Void, any Error>?
    private var startActivationWaiters: [CheckedContinuation<Result<Void, any Error>, Never>] = []
    private var cancellationTask: Task<ReviewAttemptCancellationResolution, any Error>?
    private var recoveryDispositionTask: Task<ReviewRecoveryDisposition, any Error>?
    private var installedRecoveryDisposition: ReviewRecoveryDisposition?
    private var interruptRequestTask: Task<Void, Never>?
    private var terminalBarrierTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var forceCloseTask: Task<Void, Never>?
    private var cleanupTasksByAttemptID: [String: Task<Void, any Error>] = [:]
    private var terminal: ReviewAttemptBarrierTerminal?
    private var registeredRun: CodexReviewBackendModel.Review.Run?
    private var startFailed = false
    private var requestResult: Result<Void, ReviewInterruptRequestFailure>?
    private var forceCloseResult: Result<Void, ReviewRuntimeCloseFailure>?
    private var graceDidExpire = false
    private var cancellationResult: Result<ReviewAttemptCancellationResolution, any Error>?
    private var terminalWaiters: [UUID: CheckedContinuation<ReviewAttemptBarrierTerminal?, Never>] = [:]
    private var activeRunWaiters: [CheckedContinuation<CodexReviewBackendModel.Review.Run?, Never>] = []
    private var startResolutionWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationAdmissionWaiters: [CheckedContinuation<ReviewCancellation?, Never>] = []
    private var interruptionAdmissionWaiters: [CheckedContinuation<ReviewAttemptInterruptionPurpose?, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Result<ReviewAttemptCancellationResolution, any Error>, Never>] = []

    package init(closePolicy: ReviewRuntimeClosePolicy = .production) {
        self.closePolicy = closePolicy
    }

    package func registerStart(
        _ operation: @escaping @Sendable (ReviewStartAdmission) async throws -> BackendReviewAttempt
    ) throws -> ReviewRegisteredStart {
        guard startTask == nil else {
            throw ReviewAttemptContractFailure(
                message: "ReviewStartAdmission already owns a registered start Task."
            )
        }
        nextStartGeneration &+= 1
        let id = ReviewStartHandleID(generation: nextStartGeneration)
        registeredStartID = id
        if let terminal {
            startActivationResult = .failure(startFailure(for: terminal))
        } else if let requestedCancellation {
            receiveTerminal(.localCancellation(requestedCancellation))
        } else {
            phase = .registeredStart(id)
        }
        let task = Task {
            do {
                try await self.waitForStartActivation(id)
                try self.beginActivatedStart(id)
                let attempt = try await operation(self)
                self.finishStart(with: .success(attempt))
                return attempt
            } catch {
                self.finishStart(with: .failure(error))
                throw error
            }
        }
        startTask = task
        return ReviewRegisteredStart(id: id, admission: self, task: task)
    }

    package func activateStart(_ id: ReviewStartHandleID) throws {
        guard registeredStartID == id else {
            throw ReviewAttemptContractFailure(
                message: "Start activation handle \(id.generation) is stale or belongs to another attempt."
            )
        }
        if let startActivationResult {
            switch startActivationResult {
            case .failure(let error):
                throw error
            case .success:
                guard startDidFinish == false else {
                    throw ReviewAttemptContractFailure(
                        message: "Start activation handle \(id.generation) is stale."
                    )
                }
                return
            }
        }
        guard case .registeredStart(id) = phase else {
            throw ReviewAttemptContractFailure(
                message: "Start activation handle \(id.generation) is not pending."
            )
        }
        phase = .activatedStart(id)
        resolveStartActivation(.success(()))
    }

    package func admitThreadStartDispatch() throws {
        if let terminal {
            throw startFailure(for: terminal)
        }
        if let requestedCancellation {
            throw ReviewStartCancelledBeforeDispatch(cancellation: requestedCancellation)
        }
        guard case .preparingThread(.notSent) = phase else {
            throw ReviewAttemptContractFailure(
                message: "Thread start dispatch requires one pending not-sent request."
            )
        }
        phase = .preparingThread(.outcomeUnknown)
    }

    package func recordThreadStartRejectedForRetry() throws {
        if let requestedCancellation {
            throw ReviewStartCancelledBeforeDispatch(cancellation: requestedCancellation)
        }
        guard terminal == nil else {
            throw ReviewAttemptContractFailure(
                message: "Thread start retry cannot follow an attempt terminal."
            )
        }
        guard case .preparingThread(.outcomeUnknown) = phase else {
            throw ReviewAttemptContractFailure(
                message: "Thread start retry requires one rejected dispatched request."
            )
        }
        phase = .preparingThread(.notSent)
    }

    package func recordPreparedThread(_ run: CodexReviewBackendModel.Review.Run) {
        guard terminal == nil else {
            return
        }
        phase = .startingReview(preparedRun: run, dispatch: .notSent)
    }

    package func admitReviewStartDispatch(
        for preparedRun: CodexReviewBackendModel.Review.Run
    ) throws {
        if let terminal {
            throw startFailure(for: terminal)
        }
        if let requestedCancellation {
            throw ReviewStartCancelledBeforeDispatch(cancellation: requestedCancellation)
        }
        guard case .startingReview(let currentRun, .notSent) = phase,
              currentRun.attemptID == preparedRun.attemptID
        else {
            throw ReviewAttemptContractFailure(
                message: "Review start dispatch requires its pending prepared attempt."
            )
        }
        phase = .startingReview(preparedRun: preparedRun, dispatch: .outcomeUnknown)
    }

    package func recordActiveRun(_ run: CodexReviewBackendModel.Review.Run) {
        guard terminal == nil else {
            return
        }
        registeredRun = run
        phase = .active(run)
        resumeActiveRunWaiters(returning: run)
        resumeStartResolutionWaitersIfNeeded()
    }

    package func recordCanonicalTerminal(
        _ terminalRecord: ReviewTerminalRecord,
        for run: CodexReviewBackendModel.Review.Run
    ) throws {
        guard let canonicalRun = registeredRun ?? canonicalRunForTerminal,
              Self.matchesCanonicalPair(run, canonicalRun)
        else {
            return
        }
        if let terminal {
            let candidate = ReviewAttemptBarrierTerminal.canonical(terminalRecord)
            guard terminal == candidate else {
                throw ReviewAttemptContractFailure(
                    message: "Conflicting terminal for review attempt \(run.attemptID)."
                )
            }
            return
        }
        receiveTerminal(.canonical(terminalRecord))
    }

    package func recordStreamTerminal(_ failure: ReviewAttemptStreamFailure) throws {
        let candidate = ReviewAttemptBarrierTerminal.stream(failure)
        if let terminal {
            guard terminal == candidate else {
                throw ReviewAttemptContractFailure(
                    message: "Conflicting stream terminal for the review attempt."
                )
            }
            return
        }
        if Self.isOutcomeUnknownStartPhase(phase) {
            startTask?.cancel()
        }
        receiveTerminal(candidate)
    }

    package func cancel(
        _ cancellation: ReviewCancellation,
        interrupt: @escaping @Sendable (
            CodexReviewBackendModel.Review.Run,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void,
        forceClose: @escaping @Sendable () async throws -> Void
    ) async throws -> ReviewAttemptCancellationResolution {
        if let recoveryDispositionTask {
            if joinedTerminalCancellation == nil {
                joinedTerminalCancellation = cancellation
                requestedCancellation = cancellation
                resumeCancellationAdmissionWaiters(returning: cancellation)
            }
            let disposition = try await recoveryDispositionTask.value
            return try cancellationResolution(for: disposition)
        }
        if let cancellationTask {
            return try checkedCancellationResolution(try await cancellationTask.value)
        }
        interruptionPurpose = .terminalCancellation(cancellation)
        resumeInterruptionAdmissionWaiters(returning: interruptionPurpose)
        let resolution = try await joinedCancellationResolution(
            cancellation,
            interrupt: interrupt,
            forceClose: forceClose
        )
        return try checkedCancellationResolution(resolution)
    }

    package func beginRecovery(
        trigger: ReviewAttemptRecoveryTrigger,
        interrupt: @escaping @Sendable (
            CodexReviewBackendModel.Review.Run,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void,
        forceClose: @escaping @Sendable () async throws -> Void
    ) async throws -> ReviewRecoveryDisposition {
        if let recoveryDispositionTask {
            return try await recoveryDispositionTask.value
        }
        guard cancellationTask == nil else {
            throw ReviewAttemptContractFailure(
                message: "Recovery cannot replace an admitted terminal cancellation."
            )
        }
        guard activeRun != nil else {
            throw ReviewAttemptContractFailure(
                message: "Recovery interruption requires one canonical review run."
            )
        }
        interruptionPurpose = .recoverableTransition(trigger)
        resumeInterruptionAdmissionWaiters(returning: interruptionPurpose)
        let task = Task {
            try await self.performRecovery(
                trigger: trigger,
                interrupt: interrupt,
                forceClose: forceClose
            )
        }
        recoveryDispositionTask = task
        do {
            return try await task.value
        } catch {
            recoveryDispositionTask = nil
            interruptionPurpose = nil
            throw error
        }
    }

    private func performRecovery(
        trigger: ReviewAttemptRecoveryTrigger,
        interrupt: @escaping @Sendable (
            CodexReviewBackendModel.Review.Run,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void,
        forceClose: @escaping @Sendable () async throws -> Void
    ) async throws -> ReviewRecoveryDisposition {
        guard let run = activeRun else {
            throw ReviewAttemptContractFailure(
                message: "Recovery interruption lost its active review run."
            )
        }
        let resolution = try await joinedCancellationResolution(
            trigger.cancellation,
            interrupt: interrupt,
            forceClose: forceClose
        )
        let resolved = ReviewResolvedAttemptTerminal(
            run: run,
            terminal: resolution.terminal,
            requestFailure: resolution.requestFailure
        )
        let disposition = makeRecoveryDisposition(resolved, trigger: trigger)
        installedRecoveryDisposition = disposition
        return disposition
    }

    private func makeRecoveryDisposition(
        _ resolved: ReviewResolvedAttemptTerminal,
        trigger: ReviewAttemptRecoveryTrigger
    ) -> ReviewRecoveryDisposition {
        switch resolved.terminal {
        case .canonical(let terminal):
            switch terminal {
            case .completed, .failed:
                return .productTerminal(.init(
                    resolved: resolved,
                    productTerminal: terminal
                ))
            case .interrupted:
                if let joinedTerminalCancellation {
                    return .productTerminal(.init(
                        resolved: resolved,
                        productTerminal: .interrupted(.requested(joinedTerminalCancellation))
                    ))
                }
                return .replacement(.init(resolved: resolved, trigger: trigger))
            }
        case .stream(let failure):
            if let joinedTerminalCancellation {
                if resolved.requestFailure == nil {
                    return .productTerminal(.init(
                        resolved: resolved,
                        productTerminal: .interrupted(.requested(joinedTerminalCancellation))
                    ))
                }
                return .productTerminal(.init(
                    resolved: resolved,
                    productTerminal: productTerminal(for: failure)
                ))
            }
            if failure.permitsRecoveryReplacement {
                return .replacement(.init(resolved: resolved, trigger: trigger))
            }
            return .productTerminal(.init(
                resolved: resolved,
                productTerminal: productTerminal(for: failure)
            ))
        case .localCancellation(let cancellation):
            return .productTerminal(.init(
                resolved: resolved,
                productTerminal: .interrupted(.requested(cancellation))
            ))
        }
    }

    private func productTerminal(
        for failure: ReviewAttemptStreamFailure
    ) -> ReviewTerminalRecord {
        switch failure {
        case .process:
            .interrupted(.previousProcessExit)
        case .protocolViolation(let failure), .workerContract(let failure):
            .failed(message: failure.localizedDescription)
        case .ownerCancellation:
            .failed(message: failure.localizedDescription)
        case .recoverableNetwork, .ownerForcedConnectionClose,
             .unexpectedConnection:
            .interrupted(.transport(message: failure.localizedDescription))
        }
    }

    private func cancellationResolution(
        for disposition: ReviewRecoveryDisposition
    ) throws -> ReviewAttemptCancellationResolution {
        let resolved: ReviewResolvedAttemptTerminal = switch disposition {
        case .productTerminal(let product):
            product.resolved
        case .replacement(let candidate):
            candidate.resolved
        }
        if let requestFailure = resolved.requestFailure,
           case .outcomeUnknown = requestFailure.outcome,
           case .stream(let failure) = resolved.terminal {
            throw ReviewInterruptRequestFailure(
                outcome: requestFailure.outcome,
                secondaryBarrierDiagnostic: failure.localizedDescription
            )
        }
        return .init(
            terminal: resolved.terminal,
            requestFailure: resolved.requestFailure
        )
    }

    private func joinedCancellationResolution(
        _ cancellation: ReviewCancellation,
        interrupt: @escaping @Sendable (
            CodexReviewBackendModel.Review.Run,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void,
        forceClose: @escaping @Sendable () async throws -> Void
    ) async throws -> ReviewAttemptCancellationResolution {
        if let cancellationTask {
            return try await cancellationTask.value
        }
        if let terminal {
            return .init(terminal: terminal)
        }
        if joinedTerminalCancellation == nil {
            requestedCancellation = cancellation
            resumeCancellationAdmissionWaiters(returning: cancellation)
        }
        let task = Task {
            try await self.performCancellation(
                cancellation,
                interrupt: interrupt,
                forceClose: forceClose
            )
        }
        cancellationTask = task
        return try await task.value
    }

    package func cleanup(
        run: CodexReviewBackendModel.Review.Run,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        if let cleanupTask = cleanupTasksByAttemptID[run.attemptID] {
            return try await cleanupTask.value
        }
        let task = Task {
            try await operation()
        }
        cleanupTasksByAttemptID[run.attemptID] = task
        return try await task.value
    }

    package func currentPhase() -> Phase { phase }

    package func waitForActiveRun() async -> CodexReviewBackendModel.Review.Run? {
        if let activeRun {
            return activeRun
        }
        if terminal != nil {
            return nil
        }
        if startFailed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            if let activeRun {
                continuation.resume(returning: activeRun)
            } else if terminal != nil || startFailed {
                continuation.resume(returning: nil)
            } else {
                activeRunWaiters.append(continuation)
            }
        }
    }

    package func cancellationRequest() -> ReviewCancellation? {
        requestedCancellation
    }

    package func waitForCancellationAdmission() async -> ReviewCancellation? {
        if let terminalCancellation = joinedTerminalCancellation
            ?? terminalCancellationPurpose {
            return terminalCancellation
        }
        if recoveryDispositionTask == nil, let requestedCancellation {
            return requestedCancellation
        }
        if terminal != nil {
            return nil
        }
        if startFailed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            if let terminalCancellation = joinedTerminalCancellation
                ?? terminalCancellationPurpose {
                continuation.resume(returning: terminalCancellation)
            } else if recoveryDispositionTask == nil, let requestedCancellation {
                continuation.resume(returning: requestedCancellation)
            } else if terminal != nil || startFailed {
                continuation.resume(returning: nil)
            } else {
                cancellationAdmissionWaiters.append(continuation)
            }
        }
    }

    package func waitForInterruptionAdmission() async -> ReviewAttemptInterruptionPurpose? {
        if let interruptionPurpose {
            return interruptionPurpose
        }
        if terminal != nil || startFailed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            if let interruptionPurpose {
                continuation.resume(returning: interruptionPurpose)
            } else if terminal != nil || startFailed {
                continuation.resume(returning: nil)
            } else {
                interruptionAdmissionWaiters.append(continuation)
            }
        }
    }

    package func recoveryDispositionIfInstalled() -> ReviewRecoveryDisposition? {
        installedRecoveryDisposition
    }

    package func terminalCancellationProductTerminal(
        for failure: ReviewAttemptStreamFailure
    ) async -> ReviewTerminalRecord? {
        guard case .terminalCancellation(let cancellation) = interruptionPurpose,
              let cancellationTask
        else {
            return nil
        }
        switch await cancellationTask.result {
        case .success(let resolution):
            guard resolution.terminal == .stream(failure) else {
                return nil
            }
            if resolution.requestFailure == nil,
               case .ownerForcedConnectionClose = failure {
                return .interrupted(.requested(cancellation))
            }
            return productTerminal(for: failure)
        case .failure:
            return productTerminal(for: failure)
        }
    }

    package func recordedCleanupResult(
        for run: CodexReviewBackendModel.Review.Run
    ) async -> Result<Void, any Error>? {
        guard let cleanupTask = cleanupTasksByAttemptID[run.attemptID] else {
            return nil
        }
        return await cleanupTask.result
    }

    private func waitForStartActivation(_ id: ReviewStartHandleID) async throws {
        guard registeredStartID == id else {
            throw ReviewAttemptContractFailure(
                message: "Start handle \(id.generation) became stale before activation."
            )
        }
        if let startActivationResult {
            return try startActivationResult.get()
        }
        let result = await withCheckedContinuation { continuation in
            if let startActivationResult {
                continuation.resume(returning: startActivationResult)
            } else {
                startActivationWaiters.append(continuation)
            }
        }
        try result.get()
    }

    private func beginActivatedStart(_ id: ReviewStartHandleID) throws {
        guard registeredStartID == id else {
            throw ReviewAttemptContractFailure(
                message: "Start handle \(id.generation) became stale before dispatch."
            )
        }
        if let terminal {
            throw startFailure(for: terminal)
        }
        if let requestedCancellation {
            let terminal = ReviewAttemptBarrierTerminal.localCancellation(requestedCancellation)
            receiveTerminal(terminal)
            throw startFailure(for: terminal)
        }
        guard case .activatedStart(id) = phase else {
            throw ReviewAttemptContractFailure(
                message: "Start handle \(id.generation) was not activated for dispatch."
            )
        }
        phase = .preparingThread(.notSent)
    }

    private func resolveStartActivation(_ result: Result<Void, any Error>) {
        guard startActivationResult == nil else {
            return
        }
        startActivationResult = result
        let waiters = startActivationWaiters
        startActivationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func startFailure(for terminal: ReviewAttemptBarrierTerminal) -> any Error {
        switch terminal {
        case .localCancellation(let cancellation):
            ReviewStartCancelledBeforeDispatch(cancellation: cancellation)
        case .stream(let failure):
            failure
        case .canonical:
            ReviewStartTerminatedBeforeActivation(terminal: terminal)
        }
    }

    private func finishStart(
        with result: Result<BackendReviewAttempt, any Error>
    ) {
        startDidFinish = true
        switch result {
        case .success(let attempt):
            registeredRun = attempt.run
            if terminal == nil {
                phase = .active(attempt.run)
                resumeActiveRunWaiters(returning: attempt.run)
            }
        case .failure(let error):
            startFailed = true
            if terminal == nil,
               let cancellation = (error as? ReviewStartCancelledBeforeDispatch)?.cancellation {
                receiveTerminal(.localCancellation(cancellation))
            } else if error is CancellationError,
                      let requestedCancellation {
                switch phase {
                case .registeredStart, .activatedStart, .preparingThread(.notSent):
                    receiveTerminal(.localCancellation(requestedCancellation))
                case .queued, .preparingThread(.outcomeUnknown), .startingReview,
                     .active, .interrupting, .finishing, .terminal:
                    break
                }
            }
            resumeActiveRunWaiters(returning: nil)
            resumeCancellationAdmissionWaiters(returning: nil)
            resumeInterruptionAdmissionWaiters(returning: nil)
        }
        resumeStartResolutionWaitersIfNeeded()
    }

    private func performCancellation(
        _ cancellation: ReviewCancellation,
        interrupt: @escaping @Sendable (
            CodexReviewBackendModel.Review.Run,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void,
        forceClose: @escaping @Sendable () async throws -> Void
    ) async throws -> ReviewAttemptCancellationResolution {
        if case .preparingThread(.notSent) = phase {
            startTask?.cancel()
        } else if case .queued = phase {
            receiveTerminal(.localCancellation(cancellation))
        } else if case .registeredStart = phase {
            receiveTerminal(.localCancellation(cancellation))
        } else if case .activatedStart = phase {
            receiveTerminal(.localCancellation(cancellation))
        } else if Self.isOutcomeUnknownStartPhase(phase) {
            installGraceTask(forceClose: forceClose)
        }

        if startTask != nil, activeRun == nil, terminal == nil {
            await waitForStartResolution()
        }

        if case .failure(let error)? = cancellationResult {
            await drainCancellationTasks()
            throw error
        }

        if let terminal {
            return try await finishCancellationAfterTerminal(terminal)
        }
        guard let run = activeRun else {
            if let startTask {
                switch await startTask.result {
                case .success(let attempt):
                    return try await beginActiveCancellation(
                        run: attempt.run,
                        cancellation: cancellation,
                        interrupt: interrupt,
                        forceClose: forceClose
                    )
                case .failure(let error):
                    throw error
                }
            }
            let local = ReviewAttemptBarrierTerminal.localCancellation(cancellation)
            receiveTerminal(local)
            return .init(terminal: local)
        }
        return try await beginActiveCancellation(
            run: run,
            cancellation: cancellation,
            interrupt: interrupt,
            forceClose: forceClose
        )
    }

    private func beginActiveCancellation(
        run: CodexReviewBackendModel.Review.Run,
        cancellation: ReviewCancellation,
        interrupt: @escaping @Sendable (
            CodexReviewBackendModel.Review.Run,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void,
        forceClose: @escaping @Sendable () async throws -> Void
    ) async throws -> ReviewAttemptCancellationResolution {
        phase = .interrupting(run)
        installTerminalBarrierTask()
        installInterruptRequestTask(
            run: run,
            cancellation: cancellation,
            interrupt: interrupt
        )
        installGraceTask(forceClose: forceClose)
        let result = await withCheckedContinuation { continuation in
            if let cancellationResult {
                continuation.resume(returning: cancellationResult)
            } else {
                cancellationWaiters.append(continuation)
                resolveCancellationIfPossible()
            }
        }
        await drainCancellationTasks()
        switch result {
        case .success(let resolution):
            phase = .terminal(resolution.terminal)
            return resolution
        case .failure(let error):
            if let terminal {
                phase = .terminal(terminal)
            } else if case .active = phase,
                      let requestFailure = error as? ReviewInterruptRequestFailure,
                      case .rejected = requestFailure.outcome {
                resetRejectedCancellationForRetry()
            }
            throw error
        }
    }

    private func resetRejectedCancellationForRetry() {
        requestedCancellation = nil
        joinedTerminalCancellation = nil
        interruptionPurpose = nil
        cancellationTask = nil
        interruptRequestTask = nil
        terminalBarrierTask = nil
        graceTask = nil
        forceCloseTask = nil
        requestResult = nil
        forceCloseResult = nil
        graceDidExpire = false
        cancellationResult = nil
    }

    private func finishCancellationAfterTerminal(
        _ terminal: ReviewAttemptBarrierTerminal
    ) async throws -> ReviewAttemptCancellationResolution {
        if interruptRequestTask != nil || terminalBarrierTask != nil {
            let result = await withCheckedContinuation { continuation in
                if let cancellationResult {
                    continuation.resume(returning: cancellationResult)
                } else {
                    cancellationWaiters.append(continuation)
                    resolveCancellationIfPossible()
                }
            }
            await drainCancellationTasks()
            return try result.get()
        }
        await drainCancellationTasks()
        phase = .terminal(terminal)
        return .init(terminal: terminal)
    }

    private func installInterruptRequestTask(
        run: CodexReviewBackendModel.Review.Run,
        cancellation: ReviewCancellation,
        interrupt: @escaping @Sendable (
            CodexReviewBackendModel.Review.Run,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void
    ) {
        guard interruptRequestTask == nil else {
            return
        }
        interruptRequestTask = Task {
            let result: Result<Void, ReviewInterruptRequestFailure>
            do {
                try await interrupt(run, .init(message: cancellation.message))
                result = .success(())
            } catch let failure as ReviewInterruptRequestFailure {
                result = .failure(failure)
            } catch {
                result = .failure(.init(outcome: .outcomeUnknown(
                    message: error.localizedDescription
                )))
            }
            self.receive(.request(result))
        }
    }

    private func installTerminalBarrierTask() {
        guard terminalBarrierTask == nil else {
            return
        }
        terminalBarrierTask = Task {
            if let terminal = await self.waitForTerminal() {
                self.receive(.barrier(terminal))
            }
        }
    }

    private func installGraceTask(
        forceClose: @escaping @Sendable () async throws -> Void
    ) {
        guard graceTask == nil else {
            return
        }
        let policy = closePolicy
        graceTask = Task {
            do {
                try await policy.sleep(policy.terminalGrace)
            } catch {
                return
            }
            self.receive(.graceExpired)
            self.installForceCloseTask(forceClose)
        }
    }

    private func installForceCloseTask(
        _ forceClose: @escaping @Sendable () async throws -> Void
    ) {
        guard forceCloseTask == nil else {
            return
        }
        forceCloseTask = Task {
            let result: Result<Void, ReviewRuntimeCloseFailure>
            do {
                try await forceClose()
                result = .success(())
            } catch let failure as ReviewRuntimeCloseFailure {
                result = .failure(failure)
            } catch {
                result = .failure(.connection(error.localizedDescription))
            }
            self.receive(.forceClose(result))
        }
    }

    private func receive(_ event: CancellationTaskEvent) {
        switch event {
        case .request(let result):
            requestResult = result
        case .barrier(let terminal):
            if self.terminal == nil {
                self.terminal = terminal
            }
        case .graceExpired:
            graceDidExpire = true
        case .forceClose(let result):
            forceCloseResult = result
        }
        resolveCancellationIfPossible()
    }

    private func receiveTerminal(_ terminal: ReviewAttemptBarrierTerminal) {
        self.terminal = terminal
        if registeredStartID != nil, startActivationResult == nil {
            resolveStartActivation(.failure(startFailure(for: terminal)))
        }
        phase = cancellationTask == nil ? .terminal(terminal) : .finishing(terminal)
        let waiters = Array(terminalWaiters.values)
        terminalWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: terminal)
        }
        resumeActiveRunWaiters(returning: nil)
        resumeCancellationAdmissionWaiters(returning: nil)
        resumeInterruptionAdmissionWaiters(returning: nil)
        resumeStartResolutionWaitersIfNeeded()
        resolveCancellationIfPossible()
    }

    private func resumeActiveRunWaiters(
        returning run: CodexReviewBackendModel.Review.Run?
    ) {
        let waiters = activeRunWaiters
        activeRunWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: run)
        }
    }

    private func resumeCancellationAdmissionWaiters(
        returning cancellation: ReviewCancellation?
    ) {
        let waiters = cancellationAdmissionWaiters
        cancellationAdmissionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: cancellation)
        }
    }

    private func resumeInterruptionAdmissionWaiters(
        returning purpose: ReviewAttemptInterruptionPurpose?
    ) {
        let waiters = interruptionAdmissionWaiters
        interruptionAdmissionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: purpose)
        }
    }

    private var terminalCancellationPurpose: ReviewCancellation? {
        guard case .terminalCancellation(let cancellation) = interruptionPurpose else {
            return nil
        }
        return cancellation
    }

    private func resolveCancellationIfPossible() {
        guard cancellationResult == nil else {
            return
        }
        if graceDidExpire, forceCloseResult == nil {
            return
        }
        if case .failure(let closeFailure)? = forceCloseResult {
            resolveCancellation(.failure(closeFailure))
            return
        }
        guard let requestResult else {
            return
        }
        switch requestResult {
        case .success:
            guard let terminal else {
                return
            }
            resolveCancellation(.success(.init(terminal: terminal)))
        case .failure(let requestFailure):
            switch requestFailure.outcome {
            case .rejected:
                if let terminal {
                    resolveCancellation(.success(.init(
                        terminal: terminal,
                        requestFailure: requestFailure
                    )))
                } else {
                    requestedCancellation = nil
                    if case .interrupting(let run) = phase {
                        phase = .active(run)
                    }
                    resolveCancellation(.failure(requestFailure))
                }
            case .outcomeUnknown:
                guard let terminal else {
                    return
                }
                switch terminal {
                case .stream(let streamFailure):
                    resolveCancellation(.success(.init(
                        terminal: terminal,
                        requestFailure: ReviewInterruptRequestFailure(
                            outcome: requestFailure.outcome,
                            secondaryBarrierDiagnostic: streamFailure.localizedDescription
                        )
                    )))
                case .canonical, .localCancellation:
                    resolveCancellation(.success(.init(
                        terminal: terminal,
                        requestFailure: requestFailure
                    )))
                }
            }
        }
    }

    private func resolveCancellation(
        _ result: Result<ReviewAttemptCancellationResolution, any Error>
    ) {
        cancellationResult = result
        resumeStartResolutionWaitersIfNeeded()
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func waitForTerminal() async -> ReviewAttemptBarrierTerminal? {
        if let terminal {
            return terminal
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let terminal {
                    continuation.resume(returning: terminal)
                } else {
                    terminalWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelTerminalWaiter(waiterID)
            }
        }
    }

    private func waitForStartResolution() async {
        if hasStartResolution {
            return
        }
        await withCheckedContinuation { continuation in
            if hasStartResolution {
                continuation.resume()
            } else {
                startResolutionWaiters.append(continuation)
            }
        }
    }

    private func resumeStartResolutionWaitersIfNeeded() {
        guard hasStartResolution else {
            return
        }
        let waiters = startResolutionWaiters
        startResolutionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private var hasStartResolution: Bool {
        activeRun != nil || terminal != nil || startDidFinish || cancellationResult != nil
    }

    private func checkedCancellationResolution(
        _ resolution: ReviewAttemptCancellationResolution
    ) throws -> ReviewAttemptCancellationResolution {
        if let requestFailure = resolution.requestFailure,
           case .outcomeUnknown = requestFailure.outcome,
           case .stream(let streamFailure) = resolution.terminal {
            throw ReviewInterruptRequestFailure(
                outcome: requestFailure.outcome,
                secondaryBarrierDiagnostic: streamFailure.localizedDescription
            )
        }
        return resolution
    }

    private func cancelTerminalWaiter(_ id: UUID) {
        terminalWaiters.removeValue(forKey: id)?.resume(returning: nil)
    }

    private func drainCancellationTasks() async {
        if terminal == nil {
            terminalBarrierTask?.cancel()
        }
        if case .failure? = forceCloseResult {
            interruptRequestTask?.cancel()
        }
        graceTask?.cancel()
        await interruptRequestTask?.value
        await terminalBarrierTask?.value
        await graceTask?.value
        await forceCloseTask?.value
    }

    private var canonicalRunForTerminal: CodexReviewBackendModel.Review.Run? {
        switch phase {
        case .startingReview(let run, _), .active(let run), .interrupting(let run):
            run
        case .finishing, .terminal:
            registeredRun
        case .queued, .registeredStart, .activatedStart, .preparingThread:
            registeredRun
        }
    }

    private var activeRun: CodexReviewBackendModel.Review.Run? {
        switch phase {
        case .active(let run), .interrupting(let run):
            run
        case .queued, .registeredStart, .activatedStart, .preparingThread,
             .startingReview, .finishing, .terminal:
            nil
        }
    }

    private static func isOutcomeUnknownStartPhase(_ phase: Phase) -> Bool {
        switch phase {
        case .preparingThread(.outcomeUnknown), .startingReview(_, .outcomeUnknown):
            true
        case .queued, .registeredStart, .activatedStart,
             .preparingThread(.notSent), .startingReview(_, .notSent),
             .active, .interrupting, .finishing, .terminal:
            false
        }
    }

    private static func matchesCanonicalPair(
        _ lhs: CodexReviewBackendModel.Review.Run,
        _ rhs: CodexReviewBackendModel.Review.Run
    ) -> Bool {
        lhs.attemptID == rhs.attemptID
            && lhs.reviewThreadID == rhs.reviewThreadID
            && lhs.turnID == rhs.turnID
    }
}
