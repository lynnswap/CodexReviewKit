import Foundation
import CodexAppServerKit
import CodexReviewKit
import CodexReviewAppServer

struct LoginRuntime: Sendable {
    let appServer: CodexAppServer
    let backend: AppServerCodexReviewBackend
    let codexHomeURL: URL
    let usesPrimaryRuntime: Bool
}

enum LoginPurpose: Equatable, Sendable {
    case signIn
    case addAccountPreservingActive(String?)

    var activation: LoginActivation {
        switch self {
        case .signIn:
            return .activateAuthenticatedAccount
        case .addAccountPreservingActive(let activeAccountKey):
            return .preserveActiveAccount(activeAccountKey)
        }
    }
}

enum LoginActivation: Equatable, Sendable {
    case activateAuthenticatedAccount
    case preserveActiveAccount(String?)

    func resolvedActiveAccountKey(
        authenticatedAccountKey: String,
        persistedAccounts: [CodexReviewAccount]
    ) -> String? {
        switch self {
        case .activateAuthenticatedAccount:
            return authenticatedAccountKey
        case .preserveActiveAccount(let activeAccountKey):
            return activeAccountKey.flatMap { activeAccountKey in
                persistedAccounts.contains(where: { $0.accountKey == activeAccountKey })
                    ? activeAccountKey
                    : nil
            }
        }
    }
}

enum LoginRootObservation: Sendable {
    case outcome(CodexLoginOutcome)
    case failure(CodexReviewAuthenticationFailure)
    case waiterCancelled(message: String?)
}

enum LoginTerminationReason: Equatable, Sendable {
    case rootOutcome
    case explicitCancellation
    case urlOpenFailure(CodexReviewAuthenticationFailure)
    case runtimeFailure(CodexReviewAuthenticationFailure)
    case storeStop

    var requestsSDKCancellation: Bool {
        switch self {
        case .rootOutcome:
            return false
        case .explicitCancellation, .urlOpenFailure, .runtimeFailure, .storeStop:
            return true
        }
    }
}

enum LoginSessionTerminal: Equatable, Sendable {
    case succeeded
    case failed(CodexReviewAuthenticationFailure)
    case cancelled
    case stopped
}

actor LoginStartCompletion {
    private var result: Result<Void, CodexReviewAuthenticationFailure>?
    private var waiters: [CheckedContinuation<Result<Void, CodexReviewAuthenticationFailure>, Never>] = []

    func wait() async -> Result<Void, CodexReviewAuthenticationFailure> {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resolve(_ result: Result<Void, CodexReviewAuthenticationFailure>) {
        guard self.result == nil else {
            return
        }
        self.result = result
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}

actor LoginOperationState {
    enum BindDisposition: Sendable {
        case proceed
        case cancel
    }

    private enum Phase {
        case acquiringRuntime
        case runtimeBound(LoginRuntime)
        case loginPending(LoginRuntime, CodexLoginHandle)
        case resourcesTaken
    }

    private var phase: Phase = .acquiringRuntime
    private var cancellationRequested = false
    private var cancellationClaimed = false

    func requestCancellation() -> CodexLoginHandle? {
        cancellationRequested = true
        guard cancellationClaimed == false else {
            return nil
        }
        guard case .loginPending(_, let handle) = phase else {
            return nil
        }
        cancellationClaimed = true
        return handle
    }

    func bind(runtime: LoginRuntime) -> BindDisposition {
        guard case .acquiringRuntime = phase else {
            preconditionFailure("A login runtime can be bound only once.")
        }
        phase = .runtimeBound(runtime)
        return cancellationRequested ? .cancel : .proceed
    }

    func bind(handle: CodexLoginHandle, runtime: LoginRuntime) -> BindDisposition {
        guard case .runtimeBound(let boundRuntime) = phase,
              boundRuntime.appServer === runtime.appServer else {
            preconditionFailure("A login handle must bind to its reserved runtime exactly once.")
        }
        phase = .loginPending(runtime, handle)
        guard cancellationRequested else {
            return .proceed
        }
        cancellationClaimed = true
        return .cancel
    }

    func runtime() -> LoginRuntime? {
        switch phase {
        case .acquiringRuntime, .resourcesTaken:
            return nil
        case .runtimeBound(let runtime), .loginPending(let runtime, _):
            return runtime
        }
    }

    func handle() -> CodexLoginHandle? {
        guard case .loginPending(_, let handle) = phase else {
            return nil
        }
        return handle
    }

    func takeOwnedRuntime() -> LoginRuntime? {
        switch phase {
        case .runtimeBound(let runtime), .loginPending(let runtime, _):
            guard runtime.usesPrimaryRuntime == false else {
                return nil
            }
            phase = .resourcesTaken
            return runtime
        case .acquiringRuntime, .resourcesTaken:
            return nil
        }
    }
}

@MainActor
final class LoginSession {
    typealias RootOperation = @MainActor @Sendable (
        LoginOperationState,
        LoginStartCompletion
    ) async -> LoginRootObservation
    typealias TerminationHandler = @MainActor @Sendable (
        LoginSession,
        LoginTerminationReason,
        LoginRootObservation
    ) async -> LoginSessionTerminal

    private enum State {
        case initialized
        case active
        case closing(
            reason: LoginTerminationReason,
            completion: Task<LoginSessionTerminal, Never>
        )
        case closed(LoginSessionTerminal)
    }

    let generationID: UUID
    let purpose: LoginPurpose
    private let mutationLease: AccountRegistryStore.MutationLease
    private let operationState = LoginOperationState()
    private let startCompletion = LoginStartCompletion()
    private let rootOperation: RootOperation
    private let terminationHandler: TerminationHandler
    private let cancellationTimeout: Duration
    private var rootTask: Task<LoginRootObservation, Never>?
    private var state: State = .initialized
    private var didReleaseMutationLease = false

    init(
        generationID: UUID,
        purpose: LoginPurpose,
        mutationLease: AccountRegistryStore.MutationLease,
        cancellationTimeout: Duration = .seconds(5),
        rootOperation: @escaping RootOperation,
        terminationHandler: @escaping TerminationHandler
    ) {
        self.generationID = generationID
        self.purpose = purpose
        self.mutationLease = mutationLease
        self.cancellationTimeout = cancellationTimeout
        self.rootOperation = rootOperation
        self.terminationHandler = terminationHandler
    }

    func activate() async -> Result<Void, CodexReviewAuthenticationFailure> {
        guard case .initialized = state else {
            preconditionFailure("A login session root task can be activated only once.")
        }
        let operationState = operationState
        let startCompletion = startCompletion
        let rootOperation = rootOperation
        rootTask = Task { @MainActor in
            await rootOperation(operationState, startCompletion)
        }
        state = .active
        return await startCompletion.wait()
    }

    func publishRootObservation(_: LoginRootObservation) {
        guard case .active = state else {
            return
        }
        _ = beginClosing(reason: .rootOutcome)
    }

    func terminate(reason: LoginTerminationReason) async -> LoginSessionTerminal {
        switch state {
        case .initialized:
            preconditionFailure("A login session must be activated before termination.")
        case .active:
            return await beginClosing(reason: reason).value
        case .closing(_, let completion):
            return await completion.value
        case .closed(let terminal):
            return terminal
        }
    }

    func runtime() async -> LoginRuntime? {
        await operationState.runtime()
    }

    func handle() async -> CodexLoginHandle? {
        await operationState.handle()
    }

    func takeOwnedRuntimeForClose() async -> LoginRuntime? {
        await operationState.takeOwnedRuntime()
    }

    func takeMutationLeaseForRelease() -> AccountRegistryStore.MutationLease? {
        guard didReleaseMutationLease == false else {
            return nil
        }
        didReleaseMutationLease = true
        return mutationLease
    }

    private func beginClosing(
        reason: LoginTerminationReason
    ) -> Task<LoginSessionTerminal, Never> {
        guard case .active = state else {
            preconditionFailure("Only an active login session can begin termination.")
        }
        guard rootTask != nil else {
            preconditionFailure("A login session must own its root task through termination.")
        }
        let completion = Task { @MainActor [weak self] in
            guard let self else {
                return LoginSessionTerminal.stopped
            }
            return await self.performTermination(reason: reason)
        }
        state = .closing(reason: reason, completion: completion)
        return completion
    }

    private func performTermination(
        reason: LoginTerminationReason
    ) async -> LoginSessionTerminal {
        guard let rootTask else {
            preconditionFailure("A login session must own its root task through termination.")
        }
        var cancellationFailureMessage: String?
        if reason.requestsSDKCancellation,
           let handle = await operationState.requestCancellation() {
            do {
                _ = try await handle.cancel(acknowledgementTimeout: cancellationTimeout)
            } catch {
                cancellationFailureMessage = error.localizedDescription
                rootTask.cancel()
            }
        }

        var observation = await rootTask.value
        if case .waiterCancelled = observation,
           let cancellationFailureMessage {
            observation = .waiterCancelled(message: cancellationFailureMessage)
        }
        let terminal = await terminationHandler(self, reason, observation)
        state = .closed(terminal)
        return terminal
    }

    isolated deinit {
        rootTask?.cancel()
    }
}
