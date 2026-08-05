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

enum LoginProvider: Equatable, Sendable {
    case chatGPT
    case apiKey

    init(_ method: CodexReviewAuthenticationMethod) {
        switch method {
        case .chatGPT:
            self = .chatGPT
        case .apiKey:
            self = .apiKey
        }
    }

    var expectedProvider: ExpectedRuntimeAccount.Provider {
        switch self {
        case .chatGPT:
            .chatGPT
        case .apiKey:
            .apiKey
        }
    }

    var successfulLoginExpectation: ExpectedRuntimeAccount {
        switch self {
        case .chatGPT:
            .anyChatGPT
        case .apiKey:
            .observedAccount(accountKey: "api-key", provider: .apiKey)
        }
    }
}

enum LoginPurpose: Equatable, Sendable {
    case signIn
    case addAccountPreservingActive

    var activation: LoginActivation {
        switch self {
        case .signIn:
            return .activateAuthenticatedAccount
        case .addAccountPreservingActive:
            return .preserveActiveAccount
        }
    }
}

enum LoginActivation: Equatable, Sendable {
    case activateAuthenticatedAccount
    case preserveActiveAccount
}

enum LoginRootObservation: Sendable {
    case chatGPTOutcome(CodexLoginOutcome)
    case apiKeySucceeded
    case apiKeyOutcomeUnknown
    case cancelled
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

enum PrimaryAuthenticationReconciliationResult: Equatable, Sendable {
    case authenticated(accountKey: String)
    case cancelled
    case committedNeedsRuntimeReconciliation(message: String)
}

enum PrimaryAuthenticationReconciliationCause: Sendable {
    case chatGPTCommitted(CodexLoginReconciliationReason)
    case chatGPTCancelOutcomeUnknown(previousActiveAccountKey: String?)
    case apiKeyOutcomeUnknown(previousActiveAccountKey: String?)
}

@MainActor
final class LoginFinalResultCompletion: Sendable {
    private var result: PrimaryAuthenticationReconciliationResult?
    private var waiters: [CheckedContinuation<PrimaryAuthenticationReconciliationResult, Never>] = []

    func wait() async -> PrimaryAuthenticationReconciliationResult {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    @discardableResult
    func resolve(_ result: PrimaryAuthenticationReconciliationResult) -> Bool {
        guard self.result == nil else {
            return false
        }
        self.result = result
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
        return true
    }
}

struct PrimaryAuthenticationReconciliationHandoff: Sendable {
    let loginGenerationID: UUID
    let mutationLease: AccountRegistryStore.MutationLease
    let cause: PrimaryAuthenticationReconciliationCause
    let finalResult: LoginFinalResultCompletion
}

enum LoginSessionTerminal: Sendable {
    case succeeded
    case failed(CodexReviewAuthenticationFailure)
    case cancelled
    case stopped
    case committedNeedsRuntimeReconciliation(message: String)
    case primaryRuntimeReconciliation(PrimaryAuthenticationReconciliationHandoff)
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
    enum CancellationAction: Sendable {
        case chatGPT(CodexLoginHandle)
        case apiKeyRootTask
    }

    enum BindDisposition: Sendable {
        case proceed
        case cancel
    }

    enum PreCommitFailureDisposition: Sendable {
        case fail
        case cancel
    }

    private enum Phase {
        case acquiringRuntime
        case runtimeBound(LoginRuntime)
        case loginPending(LoginRuntime, CodexLoginHandle)
        case apiKeyPending(LoginRuntime)
        case resourcesTaken
    }

    private var phase: Phase = .acquiringRuntime
    private var cancellationRequested = false
    private var cancellationClaimed = false
    private var preCommitFailureClaimed = false
    private var urlPresentationClaimed = false

    func requestCancellation() -> CancellationAction? {
        if preCommitFailureClaimed == false {
            cancellationRequested = true
        }
        guard preCommitFailureClaimed == false else {
            return nil
        }
        guard cancellationClaimed == false else {
            return nil
        }
        let action: CancellationAction
        switch phase {
        case .loginPending(_, let handle):
            action = .chatGPT(handle)
        case .apiKeyPending:
            action = .apiKeyRootTask
        case .acquiringRuntime, .runtimeBound, .resourcesTaken:
            return nil
        }
        cancellationClaimed = true
        return action
    }

    func recordCancellationIntent() {
        guard preCommitFailureClaimed == false else {
            return
        }
        cancellationRequested = true
    }

    func claimPreCommitFailure() -> PreCommitFailureDisposition {
        guard preCommitFailureClaimed == false else {
            preconditionFailure("A login pre-commit failure can be claimed only once.")
        }
        guard cancellationRequested == false else {
            return .cancel
        }
        preCommitFailureClaimed = true
        return .fail
    }

    func claimKnownAPIKeyFailure() {
        guard preCommitFailureClaimed == false else {
            preconditionFailure("A known API-key failure can be claimed only once.")
        }
        preCommitFailureClaimed = true
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

    func bindAPIKey(runtime: LoginRuntime) -> BindDisposition {
        guard case .runtimeBound(let boundRuntime) = phase,
              boundRuntime.appServer === runtime.appServer else {
            preconditionFailure("An API-key login must bind to its reserved runtime exactly once.")
        }
        phase = .apiKeyPending(runtime)
        guard cancellationRequested else {
            return .proceed
        }
        cancellationClaimed = true
        return .cancel
    }

    func claimURLPresentation(handle: CodexLoginHandle) -> BindDisposition {
        guard case .loginPending(_, let boundHandle) = phase,
              boundHandle == handle else {
            preconditionFailure("A login URL can be presented only for the bound login handle.")
        }
        precondition(urlPresentationClaimed == false, "A login URL can be claimed for presentation only once.")
        guard cancellationRequested == false else {
            return .cancel
        }
        urlPresentationClaimed = true
        return .proceed
    }

    func runtime() -> LoginRuntime? {
        switch phase {
        case .acquiringRuntime, .resourcesTaken:
            return nil
        case .runtimeBound(let runtime), .loginPending(let runtime, _), .apiKeyPending(let runtime):
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
        case .runtimeBound(let runtime), .loginPending(let runtime, _), .apiKeyPending(let runtime):
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
    let provider: LoginProvider
    let previousActiveAccountKey: String?
    private let mutationLease: AccountRegistryStore.MutationLease
    private let operationState = LoginOperationState()
    private let startCompletion = LoginStartCompletion()
    private var rootOperation: RootOperation?
    private let terminationHandler: TerminationHandler
    private let cancellationTimeout: Duration
    private var rootTask: Task<LoginRootObservation, Never>?
    private var state: State = .initialized
    private var didReleaseMutationLease = false
    private var primaryAuthenticationFinalResult: LoginFinalResultCompletion?
    private var didRoutePrimaryAuthenticationHandoff = false

    init(
        generationID: UUID,
        purpose: LoginPurpose,
        provider: LoginProvider,
        previousActiveAccountKey: String?,
        mutationLease: AccountRegistryStore.MutationLease,
        cancellationTimeout: Duration = .seconds(5),
        rootOperation: @escaping RootOperation,
        terminationHandler: @escaping TerminationHandler
    ) {
        self.generationID = generationID
        self.purpose = purpose
        self.provider = provider
        self.previousActiveAccountKey = previousActiveAccountKey
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
        guard let rootOperation else {
            preconditionFailure("A login session root operation can be consumed only once.")
        }
        self.rootOperation = nil
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
            if reason.requestsSDKCancellation {
                await operationState.recordCancellationIntent()
            }
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

    func mutationLeaseForOwnedOperation() -> AccountRegistryStore.MutationLease {
        precondition(
            didReleaseMutationLease == false,
            "A login session cannot authorize registry work after releasing its mutation lease."
        )
        return mutationLease
    }

    func mutationLeaseForCancellation() -> AccountRegistryStore.MutationLease? {
        didReleaseMutationLease ? nil : mutationLease
    }

    func recordCancellationIntent() async {
        await operationState.recordCancellationIntent()
    }

    func claimPreCommitFailure() async -> LoginOperationState.PreCommitFailureDisposition {
        await operationState.claimPreCommitFailure()
    }

    func waitForPrimaryAuthenticationFinalResult() async -> PrimaryAuthenticationReconciliationResult {
        guard let primaryAuthenticationFinalResult else {
            preconditionFailure("Only a handed-off primary authentication can expose a deferred final result.")
        }
        return await primaryAuthenticationFinalResult.wait()
    }

    func takePrimaryAuthenticationReconciliationHandoff(
        cause: PrimaryAuthenticationReconciliationCause
    ) -> PrimaryAuthenticationReconciliationHandoff {
        guard let mutationLease = takeMutationLeaseForRelease() else {
            preconditionFailure("A primary authentication reconciliation lease can be handed off only once.")
        }
        precondition(
            primaryAuthenticationFinalResult == nil,
            "A login session can install its primary authentication final-result completion only once."
        )
        let finalResult = LoginFinalResultCompletion()
        primaryAuthenticationFinalResult = finalResult
        return .init(
            loginGenerationID: generationID,
            mutationLease: mutationLease,
            cause: cause,
            finalResult: finalResult
        )
    }

    func claimPrimaryAuthenticationHandoffForDirectReconciliation(
        _ handoff: PrimaryAuthenticationReconciliationHandoff
    ) {
        precondition(handoff.loginGenerationID == generationID)
        precondition(
            didRoutePrimaryAuthenticationHandoff == false,
            "A primary authentication handoff can have only one reconciliation route."
        )
        didRoutePrimaryAuthenticationHandoff = true
    }

    func takePrimaryAuthenticationHandoffForRuntimeStop(
        from terminal: LoginSessionTerminal
    ) -> PrimaryAuthenticationReconciliationHandoff? {
        guard case .primaryRuntimeReconciliation(let handoff) = terminal else {
            return nil
        }
        guard didRoutePrimaryAuthenticationHandoff == false else {
            return nil
        }
        didRoutePrimaryAuthenticationHandoff = true
        return handoff
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
           let cancellationAction = await operationState.requestCancellation() {
            switch cancellationAction {
            case .chatGPT(let handle):
                do {
                    _ = try await handle.cancel(acknowledgementTimeout: cancellationTimeout)
                } catch {
                    cancellationFailureMessage = error.localizedDescription
                    rootTask.cancel()
                }
            case .apiKeyRootTask:
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
