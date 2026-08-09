import Foundation

package actor LoginRegistry {
    private var activeState: LoginState?
    private var pendingReservation: UUID?
    private let sleep: @Sendable (Duration) async throws -> Void

    package init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.sleep = sleep
    }

    package func reserve(
        readinessTimeout: Duration?,
        cancel:
            @escaping @Sendable (CodexLoginHandle.ID, Duration?) async throws
            -> CodexLoginOutcome,
        closeConnection: @escaping @Sendable () async -> Void
    ) async throws -> LoginState {
        if let activeState {
            guard await activeState.isTerminal else {
                throw CodexAppServerError.loginAlreadyInProgress
            }
            self.activeState = nil
        }
        guard pendingReservation == nil else {
            throw CodexAppServerError.loginAlreadyInProgress
        }
        let reservation = UUID()
        pendingReservation = reservation
        let state = LoginState(
            reservation: reservation,
            readinessTimeout: readinessTimeout,
            cancel: cancel,
            closeConnection: closeConnection,
            sleep: sleep,
            didTerminate: { [weak self] reservation in
                await self?.releaseTerminatedState(reservation: reservation)
            }
        )
        activeState = state
        return state
    }

    package func bind(
        _ state: LoginState,
        id: CodexLoginHandle.ID,
        authenticationURL: URL
    ) async throws -> CodexLoginHandle {
        guard activeState === state, pendingReservation == state.reservation else {
            throw CodexAppServerError.loginAlreadyInProgress
        }
        pendingReservation = nil
        await state.bind(id: id, authenticationURL: authenticationURL)
        return CodexLoginHandle(state: state, id: id, authenticationURL: authenticationURL)
    }

    package func apply(_ completion: CodexLoginCompletion) async {
        guard let state = activeState else {
            return
        }
        await state.apply(completion)
    }

    package func applyAccountUpdate(
        _ update: AppServerNotificationDecoder.AccountUpdate
    ) async {
        guard let state = activeState else {
            return
        }
        await state.applyAccountUpdate(update)
    }

    package func finish(throwing error: CodexAppServerError) async {
        guard let state = activeState else {
            return
        }
        await state.finishConnection(throwing: error)
    }

    package func abandon(_ state: LoginState) async {
        guard activeState === state else {
            return
        }
        pendingReservation = nil
        activeState = nil
        await state.abandon()
    }

    private func releaseTerminatedState(reservation: UUID) async {
        guard let state = activeState,
              state.reservation == reservation,
              await state.isTerminal else {
            return
        }
        guard activeState === state else {
            return
        }
        pendingReservation = nil
        activeState = nil
    }

}

package actor LoginState {
    package let reservation: UUID

    private enum Phase {
        case starting
        case pending(id: CodexLoginHandle.ID, observedAuthMode: AccountUpdate.AuthMode?)
        case successAwaitingAccount(id: CodexLoginHandle.ID)
        case terminal(Result<CodexLoginOutcome, CodexAppServerError>)
    }

    private typealias AccountUpdate = AppServerNotificationDecoder.AccountUpdate

    private enum PreBindEvent: Sendable {
        case completion(CodexLoginCompletion)
        case accountUpdate(AppServerNotificationDecoder.AccountUpdate)
    }

    private var phase: Phase = .starting
    private var waiters: [UUID: CheckedContinuation<Result<CodexLoginOutcome, Error>, Never>] = [:]
    private var readinessTask: Task<Void, Never>?
    private var cancelTask: Task<Result<CodexLoginOutcome, Error>, Never>?
    private var preBindEvents: [PreBindEvent] = []
    private let readinessTimeout: Duration?
    private let cancelOperation:
        @Sendable (CodexLoginHandle.ID, Duration?) async throws
            -> CodexLoginOutcome
    private let closeConnectionOperation: @Sendable () async -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private let didTerminate: @Sendable (UUID) async -> Void

    package init(
        reservation: UUID,
        readinessTimeout: Duration?,
        cancel:
            @escaping @Sendable (CodexLoginHandle.ID, Duration?) async throws
            -> CodexLoginOutcome,
        closeConnection: @escaping @Sendable () async -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        didTerminate: @escaping @Sendable (UUID) async -> Void
    ) {
        self.reservation = reservation
        self.readinessTimeout = readinessTimeout
        self.cancelOperation = cancel
        self.closeConnectionOperation = closeConnection
        self.sleep = sleep
        self.didTerminate = didTerminate
    }

    package var isTerminal: Bool {
        if case .terminal = phase { true } else { false }
    }

    package func bind(id: CodexLoginHandle.ID, authenticationURL _: URL) {
        switch phase {
        case .starting:
            phase = .pending(id: id, observedAuthMode: nil)
        case .terminal:
            return
        case .pending, .successAwaitingAccount:
            preconditionFailure("A login start response can bind only once.")
        }
        let events = preBindEvents
        preBindEvents.removeAll(keepingCapacity: false)
        for event in events {
            switch event {
            case .completion(let completion):
                apply(completion)
            case .accountUpdate(let update):
                applyAccountUpdate(update)
            }
        }
    }

    package func apply(_ completion: CodexLoginCompletion) {
        switch phase {
        case .starting:
            bufferPreBindEvent(.completion(completion))
        case .pending(let id, let observedAuthMode):
            guard let loginID = completion.loginID else {
                resolve(
                    .success(
                        .failed(
                            message: "account/login/completed omitted loginId for the active login."
                        )))
                return
            }
            guard loginID == id else {
                return
            }
            if completion.success {
                if let observedAuthMode {
                    resolveReadiness(authMode: observedAuthMode)
                } else {
                    phase = .successAwaitingAccount(id: id)
                    startReadinessDeadlineIfNeeded()
                }
            } else {
                resolve(.success(.failed(message: completion.error)))
            }
        case .successAwaitingAccount, .terminal:
            return
        }
    }

    package func applyAccountUpdate(_ update: AppServerNotificationDecoder.AccountUpdate) {
        if case .starting = phase {
            bufferPreBindEvent(.accountUpdate(update))
            return
        }
        guard let authMode = update.authMode else {
            return
        }
        if case .pending(let id, _) = phase {
            phase = .pending(id: id, observedAuthMode: authMode)
            return
        }
        guard case .successAwaitingAccount = phase else {
            return
        }
        resolveReadiness(authMode: authMode)
    }

    private func resolveReadiness(authMode: AccountUpdate.AuthMode) {
        guard authMode == .chatGPT else {
            resolve(
                .success(
                    .authenticationCommittedNeedsConnectionReconciliation(
                        .chatGPTAccountUnavailableAfterSuccess
                    )))
            return
        }
        resolve(.success(.succeeded))
    }

    package func finishConnection(throwing error: CodexAppServerError) {
        switch phase {
        case .successAwaitingAccount:
            if case .malformedNotification(let malformed) = error,
                malformed.method == "account/updated"
            {
                resolve(
                    .success(
                        .authenticationCommittedNeedsConnectionReconciliation(
                            .malformedAccountUpdateAfterSuccess(malformed)
                        )))
                return
            }
            let termination: CodexConnectionTermination =
                if case .connectionTerminated(let value) = error {
                    value
                } else {
                    .transportFailure(
                        .protocolViolation(
                            message: error.localizedDescription,
                            rawData: nil
                        ))
                }
            resolve(
                .success(
                    .authenticationCommittedNeedsConnectionReconciliation(
                        .connectionTerminated(termination)
                    )))
        case .pending where cancelTask != nil:
            resolve(.success(cancelOutcomeRequiringReconciliation(requestFailure: nil)))
        case .starting, .pending:
            resolve(.failure(error))
        case .terminal:
            break
        }
    }

    package func abandon() {
        switch phase {
        case .starting:
            resolve(.failure(.loginAlreadyInProgress))
        case .pending, .successAwaitingAccount, .terminal:
            break
        }
    }

    package func result() async throws -> CodexLoginOutcome {
        let token = UUID()
        return try await withTaskCancellationHandler {
            let result = await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<CodexLoginOutcome, Error>, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(CancellationError()))
                } else if case .terminal(let result) = phase {
                    continuation.resume(returning: result.mapError { $0 as Error })
                } else {
                    waiters[token] = continuation
                }
            }
            return try result.get()
        } onCancel: {
            Task { await self.cancelWaiter(token) }
        }
    }

    package func cancel(acknowledgementTimeout: Duration?) async throws -> CodexLoginOutcome {
        switch phase {
        case .terminal(let result):
            return try result.get()
        case .pending(let id, _), .successAwaitingAccount(let id):
            let task: Task<Result<CodexLoginOutcome, Error>, Never>
            if let cancelTask {
                task = cancelTask
            } else {
                task = Task { [cancelOperation] in
                    do {
                        return .success(try await cancelOperation(id, acknowledgementTimeout))
                    } catch {
                        return .failure(error)
                    }
                }
                cancelTask = task
            }
            let outcome: CodexLoginOutcome
            do {
                outcome = try await task.value.get()
            } catch {
                switch phase {
                case .pending, .successAwaitingAccount:
                    let requestFailure: CodexRequestFailure?
                    if let appServerError = error as? CodexAppServerError,
                        case .request(let failure) = appServerError
                    {
                        requestFailure = failure
                    } else {
                        requestFailure = nil
                    }
                    let reconciliation = cancelOutcomeRequiringReconciliation(
                        requestFailure: requestFailure
                    )
                    resolve(.success(reconciliation))
                    return reconciliation
                case .terminal(let result):
                    return try result.get()
                case .starting:
                    throw error
                }
            }
            switch phase {
            case .successAwaitingAccount:
                return try await result()
            case .terminal(let result):
                return try result.get()
            case .pending:
                resolve(.success(outcome))
                return outcome
            case .starting:
                preconditionFailure("A started login cannot return to its starting phase.")
            }
        case .starting:
            throw CodexAppServerError.loginAlreadyInProgress
        }
    }

    package func closeConnection() async {
        await closeConnectionOperation()
    }

    private func cancelWaiter(_ token: UUID) {
        waiters.removeValue(forKey: token)?.resume(returning: .failure(CancellationError()))
    }

    private func cancelOutcomeRequiringReconciliation(
        requestFailure: CodexRequestFailure?
    ) -> CodexLoginOutcome {
        .authenticationCommittedNeedsConnectionReconciliation(
            .cancelOutcomeUnknown(requestFailure)
        )
    }

    private func bufferPreBindEvent(_ event: PreBindEvent) {
        guard preBindEvents.count < Self.preBindEventLimit else {
            resolve(
                .failure(
                    .malformedNotification(
                        .init(
                            method: "account/login pre-bind events",
                            message: "Exceeded the bounded pre-bind event capacity.",
                            rawData: nil
                        ))))
            return
        }
        preBindEvents.append(event)
    }

    private func startReadinessDeadlineIfNeeded() {
        guard let readinessTimeout else {
            return
        }
        let sleep = self.sleep
        readinessTask = Task { [weak self, sleep] in
            do {
                try await sleep(readinessTimeout)
            } catch {
                return
            }
            await self?.readinessDeadlineExceeded(readinessTimeout)
        }
    }

    private func readinessDeadlineExceeded(_ timeout: Duration) {
        guard case .successAwaitingAccount = phase else {
            return
        }
        resolve(
            .success(
                .authenticationCommittedNeedsConnectionReconciliation(
                    .accountReadinessDeadlineExceeded(timeout)
                )))
    }

    private func resolve(_ result: Result<CodexLoginOutcome, CodexAppServerError>) {
        if case .terminal = phase {
            return
        }
        readinessTask?.cancel()
        readinessTask = nil
        cancelTask?.cancel()
        cancelTask = nil
        preBindEvents.removeAll(keepingCapacity: false)
        phase = .terminal(result)
        let reservation = reservation
        let didTerminate = didTerminate
        Task {
            await didTerminate(reservation)
        }
        let continuations = waiters.values
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume(returning: result.mapError { $0 as Error })
        }
    }

    private static let preBindEventLimit = 16
}
