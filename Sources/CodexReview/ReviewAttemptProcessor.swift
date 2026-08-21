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

package enum ReviewAttemptBarrierTerminal: Equatable, Sendable {
    case canonical(
        run: CodexReviewBackendModel.Review.Run,
        terminal: ReviewTerminalRecord
    )
    case connection(ReviewRuntimeCloseFailure)
    case localCancellation(ReviewCancellation)

    package var diagnosticDescription: String {
        switch self {
        case .canonical(let run, let terminal):
            "canonical terminal \(terminal.kind.rawValue) for attempt \(run.attemptID)"
        case .connection(let failure):
            failure.localizedDescription
        case .localCancellation(let cancellation):
            cancellation.message
        }
    }

    package var canonicalRun: CodexReviewBackendModel.Review.Run? {
        guard case .canonical(let run, _) = self else {
            return nil
        }
        return run
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
    private var startTask: Task<BackendReviewAttempt, any Error>?
    private var cancellationTask: Task<ReviewAttemptCancellationResolution, any Error>?
    private var interruptRequestTask: Task<Void, Never>?
    private var terminalBarrierTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var forceCloseTask: Task<Void, Never>?
    private var cleanupTasksByAttemptID: [String: Task<Void, any Error>] = [:]
    private var terminal: ReviewAttemptBarrierTerminal?
    private var startFailed = false
    private var requestResult: Result<Void, ReviewInterruptRequestFailure>?
    private var forceCloseResult: Result<Void, ReviewRuntimeCloseFailure>?
    private var graceDidExpire = false
    private var cancellationResult: Result<ReviewAttemptCancellationResolution, any Error>?
    private var terminalWaiters: [UUID: CheckedContinuation<ReviewAttemptBarrierTerminal?, Never>] = [:]
    private var activeRunWaiters: [CheckedContinuation<CodexReviewBackendModel.Review.Run?, Never>] = []
    private var cancellationAdmissionWaiters: [CheckedContinuation<ReviewCancellation?, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Result<ReviewAttemptCancellationResolution, any Error>, Never>] = []

    package init(closePolicy: ReviewRuntimeClosePolicy = .production) {
        self.closePolicy = closePolicy
    }

    package func start(
        _ operation: @escaping @Sendable (ReviewStartAdmission) async throws -> BackendReviewAttempt
    ) -> Task<BackendReviewAttempt, any Error> {
        precondition(
            startTask == nil,
            "ReviewStartAdmission owns exactly one registered start Task."
        )
        phase = .preparingThread(.notSent)
        let task = Task {
            do {
                let attempt = try await operation(self)
                self.finishStart(with: .success(attempt))
                return attempt
            } catch {
                self.finishStart(with: .failure(error))
                throw error
            }
        }
        startTask = task
        return task
    }

    package func admitThreadStartDispatch() -> Bool {
        guard requestedCancellation == nil else {
            return false
        }
        switch phase {
        case .preparingThread(.notSent):
            phase = .preparingThread(.outcomeUnknown)
            return true
        case .queued, .preparingThread(.outcomeUnknown), .startingReview,
             .active, .interrupting, .finishing, .terminal:
            return false
        }
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
    ) -> Bool {
        guard requestedCancellation == nil else {
            return false
        }
        guard case .startingReview(let currentRun, .notSent) = phase,
              currentRun.attemptID == preparedRun.attemptID
        else {
            return false
        }
        phase = .startingReview(preparedRun: preparedRun, dispatch: .outcomeUnknown)
        return true
    }

    package func recordActiveRun(_ run: CodexReviewBackendModel.Review.Run) {
        guard terminal == nil else {
            return
        }
        phase = .active(run)
        resumeActiveRunWaiters(returning: run)
    }

    package func recordCanonicalTerminal(
        _ terminalRecord: ReviewTerminalRecord,
        for run: CodexReviewBackendModel.Review.Run
    ) throws {
        if let terminal {
            let candidate = ReviewAttemptBarrierTerminal.canonical(run: run, terminal: terminalRecord)
            guard terminal == candidate else {
                throw ReviewAttemptContractFailure(
                    message: "Conflicting terminal for review attempt \(run.attemptID)."
                )
            }
            return
        }
        guard let canonicalRun = canonicalRunForTerminal,
              Self.matchesCanonicalPair(run, canonicalRun)
        else {
            return
        }
        receiveTerminal(.canonical(run: run, terminal: terminalRecord))
    }

    package func recordConnectionTerminal(_ failure: ReviewRuntimeCloseFailure) {
        guard terminal == nil else {
            return
        }
        if Self.isOutcomeUnknownStartPhase(phase) {
            startTask?.cancel()
        }
        receiveTerminal(.connection(failure))
    }

    package func cancel(
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
        requestedCancellation = cancellation
        resumeCancellationAdmissionWaiters(returning: cancellation)
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
        if let requestedCancellation {
            return requestedCancellation
        }
        if terminal != nil {
            return nil
        }
        if startFailed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            if let requestedCancellation {
                continuation.resume(returning: requestedCancellation)
            } else if terminal != nil || startFailed {
                continuation.resume(returning: nil)
            } else {
                cancellationAdmissionWaiters.append(continuation)
            }
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

    package func recordedConnectionTerminal() -> ReviewRuntimeCloseFailure? {
        guard case .connection(let failure) = terminal else {
            return nil
        }
        return failure
    }

    private func finishStart(
        with result: Result<BackendReviewAttempt, any Error>
    ) {
        switch result {
        case .success(let attempt):
            if terminal == nil {
                phase = .active(attempt.run)
                resumeActiveRunWaiters(returning: attempt.run)
            }
        case .failure(let error):
            startFailed = true
            if terminal == nil {
                if let cancellation = (error as? ReviewStartCancelledBeforeDispatch)?.cancellation {
                    receiveTerminal(.localCancellation(cancellation))
                } else if error is CancellationError,
                          let requestedCancellation,
                          case .preparingThread(.notSent) = phase {
                    receiveTerminal(.localCancellation(requestedCancellation))
                }
            }
            resumeActiveRunWaiters(returning: nil)
            resumeCancellationAdmissionWaiters(returning: nil)
        }
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
        } else if Self.requiresGraceDeadline(phase) {
            installGraceTask(forceClose: forceClose)
        }

        if let startTask, activeRun == nil, terminal == nil {
            _ = await startTask.result
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
        phase = cancellationTask == nil ? .terminal(terminal) : .finishing(terminal)
        let waiters = Array(terminalWaiters.values)
        terminalWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: terminal)
        }
        resumeActiveRunWaiters(returning: nil)
        resumeCancellationAdmissionWaiters(returning: nil)
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
                case .connection(let connectionFailure):
                    resolveCancellation(.failure(ReviewInterruptRequestFailure(
                        outcome: requestFailure.outcome,
                        secondaryBarrierDiagnostic: connectionFailure.localizedDescription
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
        case .finishing(let terminal), .terminal(let terminal):
            if case .canonical(let run, _) = terminal {
                run
            } else {
                nil
            }
        case .queued, .preparingThread:
            nil
        }
    }

    private var activeRun: CodexReviewBackendModel.Review.Run? {
        switch phase {
        case .active(let run), .interrupting(let run):
            run
        case .queued, .preparingThread, .startingReview, .finishing, .terminal:
            nil
        }
    }

    private static func requiresGraceDeadline(_ phase: Phase) -> Bool {
        switch phase {
        case .preparingThread(.outcomeUnknown), .startingReview:
            true
        case .queued, .preparingThread(.notSent), .active, .interrupting,
             .finishing, .terminal:
            false
        }
    }

    private static func isOutcomeUnknownStartPhase(_ phase: Phase) -> Bool {
        switch phase {
        case .preparingThread(.outcomeUnknown), .startingReview(_, .outcomeUnknown):
            true
        case .queued, .preparingThread(.notSent), .startingReview(_, .notSent),
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
