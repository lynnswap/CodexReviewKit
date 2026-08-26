import Foundation
import Observation
import OSLog

private let runtimeLifecycleLogger = Logger(
    subsystem: "CodexReviewKit",
    category: "runtime-lifecycle"
)

private struct ReviewRuntimeCancellationRegistration: Sendable {
    let jobID: String
    let receipt: ReviewCancellationRequestReceipt
}

package enum StoreReviewAttemptOwnership {
    case starting(ReviewStartAdmission)
    case active(StoreReviewActiveAttempt)
    case recovering(StoreReviewRecoveryReceipt)

    package var run: CodexReviewBackendModel.Review.Run? {
        switch self {
        case .starting: nil
        case .active(let active): active.run
        case .recovering(let receipt): receipt.source.run
        }
    }

    package var workerAdmission: ReviewStartAdmission {
        switch self {
        case .starting(let admission): admission
        case .active(let active): active.workerAdmission
        case .recovering(let receipt): receipt.source.workerAdmission
        }
    }

    package func matches(_ other: Self) -> Bool {
        switch (self, other) {
        case (.starting(let lhs), .starting(let rhs)): lhs === rhs
        case (.active(let lhs), .active(let rhs)): lhs.matches(rhs)
        case (.recovering(let lhs), .recovering(let rhs)): lhs === rhs
        default: false
        }
    }
}

@MainActor
@Observable
public final class CodexReviewStore {
    private struct RuntimeStartOperation {
        let task: Task<Void, Never>
        let sourceCloseReceiptOwner: ReviewRuntimeRecoveryReplacement?
    }

    package struct ReviewTerminalWaiter {
        package var id: UUID
        package var continuation: CheckedContinuation<Void, Never>
        package var timeoutTask: Task<Void, Never>?
    }

    public package(set) var serverState: CodexReviewServerState = .stopped
    public let auth: CodexReviewAuthModel
    package let settings: SettingsStore
    public package(set) var serverURL: URL?
    public package(set) var workspaces: Set<CodexReviewWorkspace> = []
    public package(set) var jobs: Set<CodexReviewJob> = []
    package var shouldAutoStartEmbeddedServer: Bool {
        backend.seed.shouldAutoStartEmbeddedServer
    }
    package var runtimeTeardownFinalState: ReviewRuntimeTeardownIntent.FinalState? {
        guard case .tearingDown(_, _, let finalIntent, _) = runtimeState else {
            return nil
        }
        return finalIntent.finalState
    }
    package var runtimeLifecycleAdmissionGeneration: UInt64 {
        runtimeState.generation.rawValue
    }

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let settingsService: CodexReviewSettingsService
    @ObservationIgnored package let backend: any CodexReviewStoreBackend
    @ObservationIgnored package let networkMonitor: any CodexReviewNetworkMonitoring
    @ObservationIgnored package let networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy
    @ObservationIgnored package var previewSupportRetainer: AnyObject?
    @ObservationIgnored package let clock: CodexReviewClock
    @ObservationIgnored package let idGenerator: CodexReviewIDGenerator
    @ObservationIgnored package var reviewAttemptOwnerships: [String: StoreReviewAttemptOwnership] = [:]
    @ObservationIgnored package var reviewWorkerTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored package var runtimeStopDetachedReviewWorkerTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored package var reviewTerminalWaiters: [String: [ReviewTerminalWaiter]] = [:]
    @ObservationIgnored package var nextCancellationRequestOrdinal: UInt64 = 0
    @ObservationIgnored package var closedSessions: Set<String> = []
    @ObservationIgnored package var accountRateLimitAutoRefreshDriver: CodexReviewStoreRateLimitAutoRefreshDriver?
    @ObservationIgnored package let storeWorkRegistry = ReviewStoreWorkRegistry()
    @ObservationIgnored package var runtimeState: ReviewStoreRuntimeState = .stopped(
        .init(rawValue: 0)
    )

    package init(
        backend: any CodexReviewStoreBackend = PreviewCodexReviewStoreBackend(),
        settingsService: CodexReviewSettingsService? = nil,
        diagnosticsURL: URL? = nil,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init(),
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default
    ) {
        self.backend = backend
        self.networkMonitor = networkMonitor
        self.networkRecoveryPolicy = networkRecoveryPolicy
        self.diagnosticsURL = diagnosticsURL
        self.clock = clock
        self.idGenerator = idGenerator
        self.auth = CodexReviewAuthModel()
        self.settings = SettingsStore(snapshot: backend.seed.initialSettingsSnapshot)
        self.settingsService = settingsService ?? CodexReviewSettingsService(
            initialSnapshot: backend.seed.initialSettingsSnapshot,
            backend: backend
        )
        self.settingsService.attach(settings: settings)
        auth.applyPersistedAccountStates(
            backend.seed.initialAccounts.map(savedAccountPayload(from:)),
            activeAccountKey: backend.seed.initialActiveAccountKey
        )
        if let initialAccount = backend.seed.initialAccount {
            if auth.persistedAccounts.contains(where: { $0.accountKey == initialAccount.accountKey }) {
                auth.selectPersistedAccount(initialAccount.id)
            } else {
                auth.updateCurrentAccount(initialAccount)
            }
        } else if let initialActiveAccountKey = backend.seed.initialActiveAccountKey {
            auth.selectPersistedAccount(initialActiveAccountKey)
        }
        backend.attachStore(self)
    }

    isolated deinit {
        accountRateLimitAutoRefreshDriver?.cancel()
        storeWorkRegistry.cancelWithoutWaiting()
        switch runtimeState {
        case .acquiring(_, _, let task),
             .replacing(_, let task),
             .tearingDown(_, _, _, let task):
            task.cancel()
        case .stopped, .running, .failed:
            break
        }
        for task in reviewWorkerTasks.values {
            task.cancel()
        }
        for task in runtimeStopDetachedReviewWorkerTasks.values {
            task.cancel()
        }
        for waiters in reviewTerminalWaiters.values {
            for waiter in waiters {
                waiter.timeoutTask?.cancel()
                waiter.continuation.resume()
            }
        }
    }

    public static func makePreviewStore(diagnosticsURL: URL? = nil) -> CodexReviewStore {
        makePreviewStore(seed: .init(), diagnosticsURL: diagnosticsURL)
    }

    package static func makePreviewStore(
        seed: CodexReviewStoreSeed,
        diagnosticsURL: URL? = nil
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: PreviewCodexReviewStoreBackend(seed: seed),
            diagnosticsURL: diagnosticsURL,
            networkMonitor: StaticCodexReviewNetworkMonitor()
        )
    }

    package static func makeTestingStore(
        backend: any CodexReviewStoreBackend,
        diagnosticsURL: URL? = nil,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init(),
        networkMonitor: any CodexReviewNetworkMonitoring = StaticCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: backend,
            diagnosticsURL: diagnosticsURL,
            clock: clock,
            idGenerator: idGenerator,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy
        )
    }

    public func start(forceRestartIfNeeded: Bool = false) async {
        guard let operation = admitRuntimeStart(
            forceRestartIfNeeded: forceRestartIfNeeded
        ) else {
            return
        }
        let sourceCloseJoin = operation.sourceCloseReceiptOwner?.sourceCloseJoin()
        await operation.task.value
        guard let replacement = operation.sourceCloseReceiptOwner,
              let sourceCloseJoin
        else {
            return
        }
        _ = await sourceCloseJoin.value()
        if let failure = replacement.consumeSourceCloseFailure() {
            runtimeLifecycleLogger.error(
                "Source runtime close failed; sourceGeneration=\(replacement.sourceGeneration.rawValue, privacy: .public) replacementGeneration=\(replacement.replacementGeneration.rawValue, privacy: .public) error=\(failure.localizedDescription)"
            )
        }
    }

    private func admitRuntimeStart(
        forceRestartIfNeeded: Bool
    ) -> RuntimeStartOperation? {
        let previousState = runtimeState
        switch previousState {
        case .running where forceRestartIfNeeded == false:
            return nil
        case .acquiring(_, _, let task) where forceRestartIfNeeded == false:
            return .init(task: task, sourceCloseReceiptOwner: nil)
        case .replacing(_, let task):
            return .init(task: task, sourceCloseReceiptOwner: nil)
        case .stopped, .acquiring, .running, .tearingDown, .failed:
            break
        }

        closePublishedRuntimeAdmission(in: previousState)
        switch previousState {
        case .running(let sourceGeneration, let runtime, let mcp):
            return admitRuntimeReplacement(
                sourceGeneration: sourceGeneration,
                retiringRuntime: runtime,
                retainedMCP: mcp
            )
        case .failed(let sourceGeneration, let retainedMCP?):
            return admitRuntimeReplacement(
                sourceGeneration: sourceGeneration,
                retiringRuntime: nil,
                retainedMCP: retainedMCP
            )
        case .acquiring(let sourceGeneration, let context, let task):
            task.cancel()
            return .init(
                task: admitRuntimeAcquisition(
                    generation: sourceGeneration.successor(),
                    context: context,
                    predecessor: task
                ),
                sourceCloseReceiptOwner: nil
            )
        case .tearingDown(let sourceGeneration, _, _, let task):
            return .init(
                task: admitRuntimeAcquisition(
                    generation: sourceGeneration.successor(),
                    predecessor: task
                ),
                sourceCloseReceiptOwner: nil
            )
        case .stopped(let sourceGeneration),
             .failed(let sourceGeneration, nil):
            return .init(
                task: admitRuntimeAcquisition(
                    generation: sourceGeneration.successor()
                ),
                sourceCloseReceiptOwner: nil
            )
        case .replacing(_, let task):
            return .init(task: task, sourceCloseReceiptOwner: nil)
        }
    }

    public func stop() async {
        await stop(intent: .explicitStop)
    }

    package func stop(intent: ReviewRuntimeTeardownIntent) async {
        let task = admitRuntimeTeardown(intent: intent)
        await task.value
    }

    package func requestRuntimeTeardown(
        intent: ReviewRuntimeTeardownIntent
    ) {
        _ = admitRuntimeTeardown(intent: intent)
    }

    package func requestRuntimeFailure(
        handle: any RuntimeLifecycleHandle,
        cause: String
    ) {
        let ownsHandle: Bool
        switch runtimeState {
        case .running(_, let runtime, _):
            ownsHandle = runtime.handle === handle
        case .replacing(let replacement, _):
            ownsHandle = replacement.ownsPublishedRuntime(handle: handle)
        case .stopped, .acquiring, .tearingDown, .failed:
            ownsHandle = false
        }
        guard ownsHandle else {
            return
        }
        _ = admitRuntimeTeardown(intent: .unexpectedFailure(cause))
    }

    private func admitRuntimeTeardown(
        intent: ReviewRuntimeTeardownIntent
    ) -> Task<Void, Never> {
        if case .tearingDown(
            let currentGeneration,
            let cleanupIntent,
            let finalIntent,
            let currentTask
        ) = runtimeState {
            guard intent.supersedesConcurrentFinalState,
                  finalIntent != intent
            else {
                return currentTask
            }
            let generation = currentGeneration.successor()
            let task = Task<Void, Never> { @MainActor [weak self] in
                await currentTask.value
                self?.finishRuntimeTeardown(generation: generation)
            }
            runtimeState = .tearingDown(
                generation: generation,
                cleanupIntent: cleanupIntent,
                finalIntent: intent,
                task: task
            )
            return task
        }

        let previousState = runtimeState
        closePublishedRuntimeAdmission(in: previousState)
        let generation = previousState.generation.successor()
        if case .replacing(let replacement, _) = previousState {
            replacement.finish(.superseded(runtimeTransitionPurpose(for: intent)))
        }
        if case .failed(let message) = intent.finalState {
            transitionToFailed(message)
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performRuntimeTeardown(
                previousState: previousState,
                generation: generation,
                intent: intent
            )
            self.finishRuntimeTeardown(generation: generation)
        }
        runtimeState = .tearingDown(
            generation: generation,
            cleanupIntent: intent,
            finalIntent: intent,
            task: task
        )
        return task
    }

    private func performRuntimeTeardown(
        previousState: ReviewStoreRuntimeState,
        generation: ReviewRuntimeGeneration,
        intent: ReviewRuntimeTeardownIntent
    ) async {
        switch previousState {
        case .acquiring(_, let context, let task):
            task.cancel()
            await task.value
            if let recyclingState = context.takeRecyclingState() {
                await performRuntimeTeardown(
                    previousState: recyclingState,
                    generation: generation,
                    intent: intent
                )
            }

        case .replacing(let replacement, let task):
            task.cancel()
            if let publishedRuntime = replacement.takePublishedRuntime() {
                await stopPublishedRuntimeSemantics(intent: intent)
                await closeRuntime(
                    publishedRuntime,
                    purpose: runtimeTransitionPurpose(for: intent),
                    admissionAlreadyClosed: true
                )
            }
            await task.value
            await closeRetiringRuntime(for: replacement)
            await stopMCPServer()

        case .running(_, let runtime, _):
            await stopPublishedRuntimeSemantics(intent: intent)
            await stopMCPServer()
            await closeRuntime(
                runtime,
                purpose: intent == .explicitStop ? .stop : .runtimeFailure,
                admissionAlreadyClosed: true
            )

        case .tearingDown(_, _, _, let task):
            await task.value

        case .failed(_, let retainedMCP):
            if retainedMCP != nil {
                await stopMCPServer()
            }

        case .stopped:
            break
        }
    }

    private func finishRuntimeTeardown(
        generation: ReviewRuntimeGeneration
    ) {
        guard case .tearingDown(
            let currentGeneration,
            _,
            let finalIntent,
            _
        ) = runtimeState,
              currentGeneration == generation
        else {
            return
        }
        switch finalIntent.finalState {
        case .stopped:
            runtimeState = .stopped(generation)
            transitionToStopped()
        case .failed(let message):
            runtimeState = .failed(generation: generation, retainedMCP: nil)
            transitionToFailed(message)
        }
    }

    public func restart() async {
        await start(forceRestartIfNeeded: true)
    }

    package func recycleRuntimeAfterAccountChange() async {
        await admitRuntimeRecycleAfterAccountChange()?.value
    }

    package func admitRuntimeRecycleAfterAccountChange() -> Task<Void, Never>? {
        let previousState = runtimeState
        closePublishedRuntimeAdmission(in: previousState)
        let generation = previousState.generation.successor()
        let predecessor: Task<Void, Never>?
        let context: RuntimeAcquisitionContext
        switch previousState {
        case .acquiring(_, let currentContext, let task):
            task.cancel()
            predecessor = task
            context = currentContext
        case .replacing(let replacement, let task):
            replacement.finish(.superseded(.start))
            task.cancel()
            predecessor = Task<Void, Never> { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await self.performRuntimeTeardown(
                    previousState: previousState,
                    generation: generation,
                    intent: .explicitStop
                )
            }
            context = .init()
        case .running:
            predecessor = nil
            context = .init(recycling: previousState)
        case .stopped, .tearingDown, .failed:
            return nil
        }

        serverState = .starting
        serverURL = nil
        writeDiagnosticsIfNeeded()
        let task = Task<Void, Never> { @MainActor [weak self] in
            if let predecessor {
                await predecessor.value
            }
            guard let self, self.isCurrentAcquisition(generation) else {
                return
            }
            await self.performRuntimeAcquisition(
                generation: generation,
                context: context
            )
        }
        runtimeState = .acquiring(
            generation: generation,
            context: context,
            task: task
        )
        return task
    }

    public func waitUntilStopped() async {
        if case .tearingDown(_, _, _, let task) = runtimeState {
            await task.value
        }
        await backend.waitUntilStopped()
    }

    package var storeWorkRegistryStatus: ReviewStoreWorkRegistryStatus {
        storeWorkRegistry.status
    }

    package func closeRegisteredStoreWork(
        reason: ReviewCancellation
    ) async -> ReviewStoreWorkDrainResult {
        let reviewWorkerJobIDs: [String]
        let cancellationRegistrations: [ReviewRuntimeCancellationRegistration]
        if storeWorkRegistryStatus == .open {
            reviewWorkerJobIDs = recordActiveReviewCancellationRequestsForRuntimeStop(
                reason: reason
            )
            cancellationRegistrations = reviewWorkerJobIDs.compactMap { jobID in
                guard let receipt = job(id: jobID)?.pendingCancellationRequest else {
                    return nil
                }
                return .init(jobID: jobID, receipt: receipt)
            }
        } else {
            reviewWorkerJobIDs = []
            cancellationRegistrations = []
        }
        let operation = storeWorkRegistry.beginClosing { [self] in
            accountRateLimitAutoRefreshDriver?.closeAdmission()
        } beforeTaskCancellation: { [self] in
            for registration in cancellationRegistrations {
                switch reviewAttemptOwnerships[registration.jobID] {
                case .starting(let admission):
                    await admission.registerCancellationRequest(registration.receipt)
                case .active(let active):
                    await active.admission.registerCancellationRequest(registration.receipt)
                case .recovering(let recoveryReceipt):
                    await recoveryReceipt.cancelOwnedOperation(
                        cancellationRequest: registration.receipt
                    )
                case nil:
                    break
                }
            }
        }
        let result = await operation.task.value
        await cancelAccountRateLimitAutoRefreshAndWait()
        storeWorkRegistry.completeClosing(operation, result: result)
        return result
    }

    package func startRegisteredStoreWork(
        kind: ReviewStoreWorkKind,
        cancelledBeforeEntry: ReviewStoreWorkCancelledBeforeEntryPolicy = .skip,
        operation: @escaping @MainActor @Sendable (CodexReviewStore) async -> Void
    ) -> Task<Void, Never>? {
        guard let admission = storeWorkRegistry.register(kind) else {
            return nil
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            defer {
                self?.storeWorkRegistry.finish(admission)
            }
            guard let self else {
                return
            }
            if Task.isCancelled || storeWorkRegistry.acceptsNewWork == false {
                switch cancelledBeforeEntry {
                case .skip:
                    return
                case .runFinalizer(let finalizer):
                    finalizer(self)
                    return
                }
            }
            await operation(self)
        }
        storeWorkRegistry.install(task, for: admission)
        return task
    }

    package func performRegisteredStoreWork(
        kind: ReviewStoreWorkKind,
        operation: @escaping @MainActor @Sendable (CodexReviewStore) async -> Void
    ) async {
        guard let task = startRegisteredStoreWork(
            kind: kind,
            operation: operation
        ) else {
            return
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    package func performThrowingRegisteredStoreWork<Value: Sendable>(
        kind: ReviewStoreWorkKind,
        operation: @escaping @MainActor @Sendable (CodexReviewStore) async throws -> Value
    ) async throws -> Value {
        guard let admission = storeWorkRegistry.register(kind) else {
            throw CodexReviewAPI.Error.io("Review Store work admission is closed.")
        }
        let task = Task<Value, any Error> { @MainActor [weak self] in
            guard let self else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            if self.storeWorkRegistry.acceptsNewWork == false {
                throw CancellationError()
            }
            return try await operation(self)
        }
        storeWorkRegistry.install(task, for: admission)
        defer {
            storeWorkRegistry.finish(admission)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func admitRuntimeAcquisition(
        generation: ReviewRuntimeGeneration,
        context: RuntimeAcquisitionContext = .init(),
        predecessor: Task<Void, Never>? = nil
    ) -> Task<Void, Never> {
        if predecessor == nil {
            serverState = .starting
            serverURL = nil
            writeDiagnosticsIfNeeded()
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            if let predecessor {
                await predecessor.value
            }
            guard let self, self.isCurrentAcquisition(generation) else {
                return
            }
            if predecessor != nil {
                self.serverState = .starting
                self.serverURL = nil
                self.writeDiagnosticsIfNeeded()
            }
            await self.performRuntimeAcquisition(
                generation: generation,
                context: context
            )
        }
        runtimeState = .acquiring(
            generation: generation,
            context: context,
            task: task
        )
        return task
    }

    private func performRuntimeAcquisition(
        generation: ReviewRuntimeGeneration,
        context: RuntimeAcquisitionContext
    ) async {
        guard isCurrentAcquisition(generation) else {
            if let recyclingState = context.takeRecyclingState() {
                await performRuntimeTeardown(
                    previousState: recyclingState,
                    generation: generation,
                    intent: .explicitStop
                )
            }
            return
        }
        var cutoverToken: CodexReviewSettingsService.RuntimeCutoverToken?
        var settingsServiceOwnsCutover = false
        var preparedRuntime: PreparedRuntime?
        var preparedMCPServer: PreparedMCPServer?

        do {
            let token = try await settingsService.beginRuntimeCutover()
            cutoverToken = token

            if let previousState = context.takeRecyclingState() {
                await performRuntimeTeardown(
                    previousState: previousState,
                    generation: generation,
                    intent: .explicitStop
                )
            }
            guard isCurrentAcquisition(generation) else {
                cancelRuntimeCutover(token)
                return
            }

            let mcpPreparation = try await backend.mcpServerLifecycle.prepare()
            preparedMCPServer = mcpPreparation
            guard isCurrentAcquisition(generation) else {
                await stopMCPServer()
                cancelRuntimeCutover(token)
                return
            }

            let runtime = try await backend.prepareRuntime(
                generation: generation,
                purpose: .start
            )
            preparedRuntime = runtime
            guard isCurrentAcquisition(generation) else {
                await closeRuntime(runtime, purpose: .start)
                await stopMCPServer()
                cancelRuntimeCutover(token)
                return
            }

            try await runtime.handle.activate()
            guard isCurrentAcquisition(generation) else {
                await closeRuntime(runtime, purpose: .start)
                await stopMCPServer()
                cancelRuntimeCutover(token)
                return
            }

            let mcpSnapshot = try await backend.mcpServerLifecycle.activate(mcpPreparation)
            guard isCurrentAcquisition(generation) else {
                await closeRuntime(runtime, purpose: .start)
                await stopMCPServer()
                cancelRuntimeCutover(token)
                return
            }

            settingsServiceOwnsCutover = true
            try await settingsService.commitRuntimeSnapshot(
                token: token,
                snapshot: runtime.snapshot.settings
            )
            guard isCurrentAcquisition(generation) else {
                await closeRuntime(runtime, purpose: .start)
                await stopMCPServer()
                return
            }

            try backend.commitRuntimePublication(
                runtime.snapshot,
                handle: runtime.handle,
                auth: auth
            )
            guard isCurrentAcquisition(generation) else {
                await closeRuntime(runtime, purpose: .start)
                await stopMCPServer()
                return
            }

            let retainedMCP = RetainedMCPServer(serverURL: mcpSnapshot.serverURL)
            runtimeState = .running(
                generation: generation,
                runtime: runtime,
                mcp: retainedMCP
            )
            publishRuntime(serverURL: retainedMCP.serverURL)
            await backend.waitForRuntimePublication(handle: runtime.handle)
        } catch {
            if let recyclingState = context.takeRecyclingState() {
                await performRuntimeTeardown(
                    previousState: recyclingState,
                    generation: generation,
                    intent: .explicitStop
                )
            }
            if let preparedRuntime {
                await closeRuntime(preparedRuntime, purpose: .start)
            }
            if preparedMCPServer != nil {
                await stopMCPServer()
            }
            let isCurrentGeneration = isCurrentAcquisition(generation)
            let wasIntentionallyCancelled = Task.isCancelled || isCurrentGeneration == false
            if let cutoverToken, settingsServiceOwnsCutover == false {
                if wasIntentionallyCancelled {
                    cancelRuntimeCutover(cutoverToken)
                } else {
                    abortRuntimeCutover(cutoverToken, message: error.localizedDescription)
                }
            }
            guard wasIntentionallyCancelled == false else {
                return
            }
            runtimeState = .failed(generation: generation, retainedMCP: nil)
            transitionToFailed(error.localizedDescription)
        }
    }

    private func admitRuntimeReplacement(
        sourceGeneration: ReviewRuntimeGeneration,
        retiringRuntime: PreparedRuntime?,
        retainedMCP: RetainedMCPServer
    ) -> RuntimeStartOperation {
        let replacement = ReviewRuntimeRecoveryReplacement(
            sourceGeneration: sourceGeneration,
            retiringRuntime: retiringRuntime,
            retainedMCP: retainedMCP
        )
        serverState = .starting
        serverURL = retainedMCP.serverURL
        writeDiagnosticsIfNeeded()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performRuntimeReplacement(replacement)
        }
        runtimeState = .replacing(
            replacement: replacement,
            task: task
        )
        return .init(task: task, sourceCloseReceiptOwner: replacement)
    }

    private func performRuntimeReplacement(
        _ replacement: ReviewRuntimeRecoveryReplacement
    ) async {
        guard isCurrentReplacement(replacement) else {
            return
        }
        var cutoverToken: CodexReviewSettingsService.RuntimeCutoverToken?
        var settingsServiceOwnsCutover = false
        var preparedRuntime: PreparedRuntime?

        do {
            let token = try await settingsService.beginRuntimeCutover()
            cutoverToken = token

            await closeRetiringRuntime(for: replacement)
            guard isCurrentReplacement(replacement) else {
                cancelRuntimeCutover(token)
                return
            }

            let runtime = try await backend.prepareRuntime(
                generation: replacement.replacementGeneration,
                purpose: .restartSameAccount
            )
            preparedRuntime = runtime
            guard isCurrentReplacement(replacement) else {
                await closeRuntime(runtime, purpose: .restartSameAccount)
                cancelRuntimeCutover(token)
                return
            }

            try await runtime.handle.activate()
            guard isCurrentReplacement(replacement) else {
                await closeRuntime(runtime, purpose: .restartSameAccount)
                cancelRuntimeCutover(token)
                return
            }

            settingsServiceOwnsCutover = true
            try await settingsService.commitRuntimeSnapshot(
                token: token,
                snapshot: runtime.snapshot.settings
            )
            guard isCurrentReplacement(replacement) else {
                await closeRuntime(runtime, purpose: .restartSameAccount)
                return
            }

            try backend.commitRuntimePublication(
                runtime.snapshot,
                handle: runtime.handle,
                auth: auth
            )
            guard isCurrentReplacement(replacement) else {
                await closeRuntime(runtime, purpose: .restartSameAccount)
                return
            }

            replacement.installPublishedRuntime(runtime)
            preparedRuntime = nil
            await backend.waitForRuntimePublication(handle: runtime.handle)
            guard isCurrentReplacement(replacement) else {
                return
            }
            guard let publishedRuntime = replacement.takePublishedRuntime() else {
                preconditionFailure(
                    "ReviewRuntimeRecoveryReplacement must own its published runtime until exact-identity transfer."
                )
            }

            runtimeState = .running(
                generation: replacement.replacementGeneration,
                runtime: publishedRuntime,
                mcp: replacement.retainedMCP
            )
            publishRuntime(serverURL: replacement.retainedMCP.serverURL)
            replacement.finish(.running(replacement.replacementGeneration))
        } catch {
            await closeRetiringRuntime(for: replacement)
            if let preparedRuntime {
                await closeRuntime(preparedRuntime, purpose: .restartSameAccount)
            }
            let isCurrentGeneration = isCurrentReplacement(replacement)
            let wasIntentionallyCancelled = Task.isCancelled || isCurrentGeneration == false
            if let cutoverToken, settingsServiceOwnsCutover == false {
                if wasIntentionallyCancelled {
                    cancelRuntimeCutover(cutoverToken)
                } else {
                    abortRuntimeCutover(cutoverToken, message: error.localizedDescription)
                }
            }
            guard wasIntentionallyCancelled == false else {
                return
            }
            runtimeState = .failed(
                generation: replacement.replacementGeneration,
                retainedMCP: replacement.retainedMCP
            )
            serverURL = replacement.retainedMCP.serverURL
            serverState = .failed(error.localizedDescription)
            writeDiagnosticsIfNeeded()
            replacement.finish(.failed(error.localizedDescription))
        }
    }

    private func closePublishedRuntimeForReplacement(
        _ runtime: PreparedRuntime
    ) async -> ReviewRuntimeCloseFailure? {
        await stopPublishedRuntimeSemantics(intent: .explicitStop)
        return await closeRuntime(
            runtime,
            purpose: .restartSameAccount,
            admissionAlreadyClosed: true
        )
    }

    private func closeRetiringRuntime(
        for replacement: ReviewRuntimeRecoveryReplacement
    ) async {
        guard let retiringRuntime = replacement.takeRetiringRuntime() else {
            replacement.finishSourceClose(.closed)
            return
        }
        let failure = await closePublishedRuntimeForReplacement(retiringRuntime)
        if let failure {
            replacement.finishSourceClose(.failed(failure))
        } else {
            replacement.finishSourceClose(.closed)
        }
    }

    private func stopPublishedRuntimeSemantics(
        intent: ReviewRuntimeTeardownIntent
    ) async {
        let locallyCancelledJobIDs: [String]
        if backend.handlesActiveReviewStopCleanup {
            locallyCancelledJobIDs = []
        } else {
            let cancellationOutcome = await requestActiveReviewCancellationsForRuntimeStop(
                reason: intent.reviewCancellation
            )
            locallyCancelledJobIDs = cancellationOutcome.jobIDs
            if let failure = cancellationOutcome.firstFailure {
                runtimeLifecycleLogger.error(
                    "Review cancellation request failed before runtime stop: \(failure.localizedDescription, privacy: .public)"
                )
            }
        }
        await backend.stop(store: self, intent: intent)
        let remainingLocallyCancelledJobIDs = cancelActiveReviewsLocallyForRuntimeStop(
            reason: intent.reviewCancellation
        )
        await cancelAndDetachReviewWorkersForRuntimeStop(
            jobIDs: Array(Set(locallyCancelledJobIDs + remainingLocallyCancelledJobIDs)),
            reason: intent.reviewCancellation
        )
    }

    @discardableResult
    private func closeRuntime(
        _ runtime: PreparedRuntime,
        purpose: ReviewRuntimeTransitionPurpose,
        admissionAlreadyClosed: Bool = false
    ) async -> ReviewRuntimeCloseFailure? {
        if admissionAlreadyClosed == false {
            runtime.handle.closeAdmission()
        }
        var firstFailure: ReviewRuntimeCloseFailure?
        do {
            try await runtime.handle.close(purpose: purpose)
        } catch {
            firstFailure = runtimeCloseFailure(from: error)
            writeDiagnosticsIfNeeded()
        }
        do {
            try await runtime.handle.waitUntilClosed()
        } catch {
            if firstFailure == nil {
                firstFailure = runtimeCloseFailure(from: error)
            }
            writeDiagnosticsIfNeeded()
        }
        return firstFailure
    }

    private func runtimeCloseFailure(
        from error: any Error
    ) -> ReviewRuntimeCloseFailure {
        if let failure = error as? ReviewRuntimeCloseFailure {
            return failure
        }
        return .cleanup(error.localizedDescription)
    }

    private func closePublishedRuntimeAdmission(
        in state: ReviewStoreRuntimeState
    ) {
        switch state {
        case .running(_, let runtime, _):
            runtime.handle.closeAdmission()
        case .replacing(let replacement, _):
            replacement.closePublishedRuntimeAdmission()
        case .stopped, .acquiring, .tearingDown, .failed:
            break
        }
    }

    private func stopMCPServer() async {
        do {
            try await backend.mcpServerLifecycle.stop()
        } catch {
            writeDiagnosticsIfNeeded()
        }
    }

    private func abortRuntimeCutover(
        _ token: CodexReviewSettingsService.RuntimeCutoverToken,
        message: String
    ) {
        do {
            try settingsService.abortRuntimeCutover(token: token, message: message)
        } catch {
            preconditionFailure(
                "CodexReviewStore must consume its current runtime cutover token exactly once: \(error)"
            )
        }
    }

    private func cancelRuntimeCutover(
        _ token: CodexReviewSettingsService.RuntimeCutoverToken
    ) {
        do {
            try settingsService.cancelRuntimeCutover(token: token)
        } catch {
            preconditionFailure(
                "CodexReviewStore must consume its current runtime cutover token exactly once: \(error)"
            )
        }
    }

    private func isCurrentAcquisition(
        _ generation: ReviewRuntimeGeneration
    ) -> Bool {
        guard case .acquiring(let currentGeneration, _, _) = runtimeState else {
            return false
        }
        return currentGeneration == generation
    }

    private func isCurrentReplacement(
        _ replacement: ReviewRuntimeRecoveryReplacement
    ) -> Bool {
        guard case .replacing(let currentReplacement, _) = runtimeState else {
            return false
        }
        return currentReplacement === replacement
    }

    private func runtimeTransitionPurpose(
        for intent: ReviewRuntimeTeardownIntent
    ) -> ReviewRuntimeTransitionPurpose {
        switch intent {
        case .explicitStop:
            .stop
        case .unexpectedFailure:
            .runtimeFailure
        }
    }

    private func publishRuntime(serverURL: URL?) {
        transitionToRunning(serverURL: serverURL)
        startAccountRateLimitAutoRefresh()
    }

    public func refreshAuthentication() async {
        await backend.refreshAuth(auth: auth)
    }

    public func signIn() async {
        await backend.signIn(auth: auth)
    }

    public func addAccount() async {
        await backend.addAccount(auth: auth)
    }

    public func cancelAuthentication() async {
        await backend.cancelAuthentication(auth: auth)
    }

    package func performPrimaryAuthenticationAction() async {
        if auth.isAuthenticating {
            await cancelAuthentication()
            return
        }
        guard canPerformPrimaryAuthenticationAction else {
            return
        }
        if serverState.canRestartForAuthentication {
            await start(forceRestartIfNeeded: true)
        }
        guard case .running = serverState,
              canPerformPrimaryAuthenticationAction
        else {
            return
        }
        await signIn()
    }

    public func logout() async {
        if auth.isAuthenticating, auth.selectedAccount == nil {
            await cancelAuthentication()
            return
        }
        do {
            try await signOutActiveAccount()
        } catch {
            if auth.errorMessage == nil, auth.isAuthenticated {
                auth.updatePhase(.failed(message: error.localizedDescription))
            }
        }
    }

    public func signOutActiveAccount() async throws {
        try await backend.signOutActiveAccount(auth: auth)
    }

    package func switchAccount(_ account: CodexAccount) async throws {
        guard canSwitchAccount(account) else {
            return
        }
        let targetAccount = auth.persistedAccounts.first(where: { $0.accountKey == account.accountKey })
        if auth.persistedAccounts.contains(where: { $0.isSwitching }) || auth.selectedAccount?.isSwitching == true {
            return
        }
        targetAccount?.updateIsSwitching(true)
        defer {
            targetAccount?.updateIsSwitching(false)
        }
        try await backend.switchAccount(auth: auth, accountKey: account.accountKey)
    }

    package func requestSwitchAccount(_ account: CodexAccount, requiresConfirmation: Bool) {
        guard storeWorkRegistry.acceptsNewWork else {
            return
        }
        auth.requestSwitchAccount(account, requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func requestSwitchAccountFromUserAction(_ account: CodexAccount) {
        guard storeWorkRegistry.acceptsNewWork else {
            return
        }
        requestSwitchAccount(
            account,
            requiresConfirmation: hasRunningJobs
                && switchActionRequiresRunningJobsConfirmation(for: account)
        )
    }

    package func requestSignOutActiveAccount(requiresConfirmation: Bool) {
        guard storeWorkRegistry.acceptsNewWork else {
            return
        }
        auth.requestSignOutActiveAccount(requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func requestRemoveAccount(_ account: CodexAccount, requiresConfirmation: Bool) {
        guard storeWorkRegistry.acceptsNewWork else {
            return
        }
        auth.requestRemoveAccount(account, requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func confirmPendingAccountAction() {
        guard storeWorkRegistry.acceptsNewWork else {
            return
        }
        guard let action = auth.consumePendingAccountAction() else {
            return
        }
        _ = startRegisteredStoreWork(kind: .accountAction) { @MainActor store in
            do {
                try await store.executePendingAccountAction(action)
                if let warningMessage = store.auth.warningMessage {
                    store.auth.presentAccountActionAlert(
                        title: "Account Updated With Warning",
                        message: warningMessage
                    )
                }
            } catch {
                store.auth.presentAccountActionAlert(
                    title: action.failureTitle,
                    message: error.localizedDescription
                )
            }
        }
    }

    package func cancelPendingAccountAction() {
        guard storeWorkRegistry.acceptsNewWork else {
            return
        }
        auth.cancelPendingAccountAction()
    }

    package func dismissAccountActionAlert() {
        guard storeWorkRegistry.acceptsNewWork else {
            return
        }
        auth.dismissAccountActionAlert()
    }

    package func removeAccount(accountKey: String) async throws {
        try await backend.removeAccount(auth: auth, accountKey: accountKey)
    }

    package func reorderPersistedAccount(accountKey: String, toIndex: Int) async throws {
        try await backend.reorderPersistedAccount(auth: auth, accountKey: accountKey, toIndex: toIndex)
    }

    package func refreshAccountRateLimits(accountKey: String) async {
        await backend.refreshAccountRateLimits(auth: auth, accountKey: accountKey)
    }

    package func startStartupAuthRefresh() {
        if auth.selectedAccount == nil {
            auth.updatePhase(.signedOut)
        }
    }

    package func cancelStartupAuthRefresh() {}

    package func reconcileAuthenticatedSession(serverIsRunning _: Bool, runtimeGeneration _: Int) async {}

    package func switchActionIsDisabled(for account: CodexAccount) -> Bool {
        canSwitchAccount(account) == false
    }

    package func switchActionRequiresRunningJobsConfirmation(for account: CodexAccount) -> Bool {
        guard canSwitchAccount(account) else {
            return false
        }
        return true
    }

    package func refreshSettings() async {
        await settingsService.refresh()
    }

    package func updateSettingsModel(_ model: String) async {
        await settingsService.updateModel(model)
    }

    package func clearSettingsModelOverride() async {
        await settingsService.clearModelOverride()
    }

    package func updateSettingsReasoningEffort(_ reasoningEffort: CodexReviewSettings.ReasoningEffort?) async {
        await settingsService.updateReasoningEffort(reasoningEffort)
    }

    package func clearSettingsReasoningEffort() async {
        await updateSettingsReasoningEffort(nil)
    }

    package func updateSettingsServiceTier(_ serviceTier: CodexReviewSettings.ServiceTier?) async {
        await settingsService.updateServiceTier(serviceTier)
    }

    package func transitionToRunning(serverURL: URL?) {
        self.serverURL = serverURL
        serverState = .running
        writeDiagnosticsIfNeeded()
    }

    package func transitionToFailed(_ message: String, resetJobs: Bool = false) {
        serverURL = nil
        if resetJobs {
            resetReviews()
        }
        serverState = .failed(message)
        writeDiagnosticsIfNeeded()
    }

    package func transitionToStopped(resetJobs: Bool = false) {
        serverURL = nil
        if resetJobs {
            resetReviews()
        }
        serverState = .stopped
        writeDiagnosticsIfNeeded()
    }

    package func writeDiagnosticsIfNeeded() {
        guard let diagnosticsURL else {
            return
        }
        let jobs = orderedJobs.map { job in
            CodexReviewStoreDiagnosticsSnapshot.Job(
                status: job.core.lifecycle.status.rawValue,
                summary: job.core.output.summary,
                logText: job.logText,
                rawLogText: job.rawLogText
            )
        }
        let snapshot = CodexReviewStoreDiagnosticsSnapshot(
            serverState: serverState.displayText,
            failureMessage: serverState.failureMessage,
            serverURL: serverURL?.absoluteString,
            childRuntimePath: nil,
            jobs: jobs
        )
        do {
            try FileManager.default.createDirectory(
                at: diagnosticsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: diagnosticsURL, options: .atomic)
        } catch {}
    }

    package func noteJobMutation() {
        writeDiagnosticsIfNeeded()
    }

    public var hasRunningJobs: Bool {
        jobs.contains(where: { $0.isTerminal == false })
    }

    public var runningJobCount: Int {
        jobs.filter { $0.isTerminal == false }.count
    }

    public var canPerformPrimaryAuthenticationAction: Bool {
        if auth.isAuthenticating {
            return true
        }
        guard auth.isAuthenticated == false else {
            return false
        }
        switch serverState {
        case .running, .stopped, .failed:
            return true
        case .starting:
            return false
        }
    }

    private func resetReviews() {
        workspaces = []
        jobs = []
    }

    private func executePendingAccountAction(_ action: CodexReviewAuthModel.PendingAccountAction) async throws {
        switch action {
        case .switchAccount(let accountKey):
            guard let account = auth.persistedAccounts.first(where: { $0.accountKey == accountKey }) else {
                return
            }
            try await switchAccount(account)
        case .signOutActiveAccount:
            try await signOutActiveAccount()
        case .removeAccount(let accountKey):
            try await removeAccount(accountKey: accountKey)
        }
    }

    private func canSwitchAccount(_ account: CodexAccount) -> Bool {
        auth.canRequestSwitchAccount(account)
    }

}

private extension CodexReviewServerState {
    var canRestartForAuthentication: Bool {
        switch self {
        case .stopped, .failed:
            true
        case .starting, .running:
            false
        }
    }
}
