import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewStore {
    package struct ReviewTerminalWaiter {
        package var id: UUID
        package var continuation: CheckedContinuation<Void, Never>
        package var timeoutTask: Task<Void, Never>?
    }

    package struct CloseCallerWaiter {
        package var targetCount: Int
        package var continuation: CheckedContinuation<Void, Never>
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

    @ObservationIgnored package let diagnosticsURL: URL?
    @ObservationIgnored package let settingsService: CodexReviewSettingsService
    @ObservationIgnored package let backend: any CodexReviewStoreBackend
    @ObservationIgnored package let networkMonitor: any CodexReviewNetworkMonitoring
    @ObservationIgnored package let networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy
    @ObservationIgnored package let reviewRuntimeClosePolicy: ReviewRuntimeClosePolicy
    @ObservationIgnored package var previewSupportRetainer: AnyObject?
    @ObservationIgnored package let clock: CodexReviewClock
    @ObservationIgnored package let idGenerator: CodexReviewIDGenerator
    @ObservationIgnored package var reviewAttemptOwnerships: [String: ReviewAttemptOwnership] = [:]
    @ObservationIgnored package var reviewRegistrationOrder: [String] = []
    @ObservationIgnored package var reviewCleanupFailures: [String: ReviewRuntimeCloseFailure] = [:]
    @ObservationIgnored package var reviewWorkerTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored package var nextReviewMutationID: UInt64 = 0
    @ObservationIgnored package var reviewMutationTasks: [UInt64: Task<String, any Error>] = [:]
    @ObservationIgnored package var reviewMutationPreparationForTesting: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored package var reviewCleanupPreparationForTesting: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored package var reviewTerminalPublicationPreparationForTesting: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored package var runtimeForceCloseReceiptRecordedForTesting: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored package var storeCommandRegistry = ReviewStoreCommandRegistry()
    @ObservationIgnored package var closeCallerCount = 0
    @ObservationIgnored package var closeCallerWaiters: [CloseCallerWaiter] = []
    @ObservationIgnored package var reviewTerminalWaiters: [String: [ReviewTerminalWaiter]] = [:]
    @ObservationIgnored package var closedSessions: Set<String> = []
    @ObservationIgnored package var accountRateLimitAutoRefreshDriver: CodexReviewStoreRateLimitAutoRefreshDriver?
    @ObservationIgnored package var lifetimeState: ReviewStoreLifetimeState = .open
    @ObservationIgnored package var applicationCloseFailureLedger: ReviewCloseFailureLedger?
    @ObservationIgnored package var runtimeState: ReviewStoreRuntimeState = .stopped(
        .init(rawValue: 0)
    )
    @ObservationIgnored package var lastRuntimeTransitionRecord: ReviewRuntimeTransitionRecord?

    package init(
        backend: any CodexReviewStoreBackend = PreviewCodexReviewStoreBackend(),
        settingsService: CodexReviewSettingsService? = nil,
        diagnosticsURL: URL? = nil,
        clock: CodexReviewClock = .init(),
        idGenerator: CodexReviewIDGenerator = .init(),
        networkMonitor: any CodexReviewNetworkMonitoring = SystemCodexReviewNetworkMonitor(),
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        reviewRuntimeClosePolicy: ReviewRuntimeClosePolicy = .production
    ) {
        self.backend = backend
        self.networkMonitor = networkMonitor
        self.networkRecoveryPolicy = networkRecoveryPolicy
        self.reviewRuntimeClosePolicy = reviewRuntimeClosePolicy
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
        if case .closing(let task) = lifetimeState {
            task.cancel()
        }
        switch runtimeState {
        case .acquiring(_, let task, _), .transitioning(_, _, let task, _, _):
            task.cancel()
        case .stopped, .running, .failed:
            break
        }
        for task in reviewWorkerTasks.values {
            task.cancel()
        }
        for task in reviewMutationTasks.values {
            task.cancel()
        }
        for (_, task) in storeCommandRegistry.ownedTaskSnapshot() {
            task.cancel()
        }
        for waiters in reviewTerminalWaiters.values {
            for waiter in waiters {
                waiter.timeoutTask?.cancel()
                waiter.continuation.resume()
            }
        }
        for waiter in closeCallerWaiters {
            waiter.continuation.resume()
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
        networkRecoveryPolicy: CodexReviewNetworkRecoveryPolicy = .default,
        reviewRuntimeClosePolicy: ReviewRuntimeClosePolicy = .production
    ) -> CodexReviewStore {
        CodexReviewStore(
            backend: backend,
            diagnosticsURL: diagnosticsURL,
            clock: clock,
            idGenerator: idGenerator,
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: networkRecoveryPolicy,
            reviewRuntimeClosePolicy: reviewRuntimeClosePolicy
        )
    }

    public func start(forceRestartIfNeeded: Bool = false) async {
        guard case .open = lifetimeState else {
            return
        }
        switch runtimeState {
        case .acquiring:
            return
        case .transitioning(_, _, let task, _, _):
            await task.value
            return
        case .running where forceRestartIfNeeded == false:
            return
        case .running(let generation, let runtime, let mcpGeneration):
            await startRuntimeReplacement(
                previousGeneration: generation,
                previousRuntime: runtime,
                retainedMCPGeneration: mcpGeneration,
                retainedServerURL: serverURL
            )
            return
        case .failed(let generation, let mcpGeneration, let retainedServerURL):
            await startRuntimeReplacement(
                previousGeneration: generation,
                previousRuntime: nil,
                retainedMCPGeneration: mcpGeneration,
                retainedServerURL: retainedServerURL
            )
            return
        case .stopped:
            break
        }
        let purpose: ReviewRuntimeTransitionPurpose = forceRestartIfNeeded
            ? .restartSameAccount
            : .stop
        await startRuntime(purpose: purpose)
    }

    private func startRuntime(purpose: ReviewRuntimeTransitionPurpose) async {
        guard case .stopped(let previousGeneration) = runtimeState else {
            return
        }
        let generation = previousGeneration.successor()
        let record = ReviewRuntimeTransitionRecord()
        serverState = .starting
        serverURL = nil
        writeDiagnosticsIfNeeded()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeAcquisition(
                generation: generation,
                purpose: purpose,
                record: record
            )
        }
        runtimeState = .acquiring(
            generation: generation,
            task: task,
            record: record
        )
        await task.value
    }

    private func startRuntimeReplacement(
        previousGeneration: ReviewRuntimeGeneration,
        previousRuntime: PreparedRuntime?,
        retainedMCPGeneration: MCPServerGeneration,
        retainedServerURL: URL?
    ) async {
        let generation = previousGeneration.successor()
        let record = ReviewRuntimeTransitionRecord()
        serverState = .starting
        writeDiagnosticsIfNeeded()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeReplacement(
                generation: generation,
                previousRuntime: previousRuntime,
                retainedMCPGeneration: retainedMCPGeneration,
                retainedServerURL: retainedServerURL,
                record: record
            )
        }
        runtimeState = .transitioning(
            generation: generation,
            purpose: .restartSameAccount,
            task: task,
            record: record,
            sourceRuntime: previousRuntime
        )
        await task.value
    }

    public func stop() async {
        switch lifetimeState {
        case .open:
            break
        case .closing(let task):
            _ = await task.value
            return
        case .closed:
            return
        }
        let previousState = runtimeState
        switch previousState {
        case .stopped:
            transitionToStopped()
            return
        case .transitioning(_, .stop, let task, _, _):
            await task.value
            return
        case .acquiring, .running, .transitioning, .failed:
            break
        }
        let invalidatedGeneration = previousState.generation.successor()
        let record = ReviewRuntimeTransitionRecord()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeStop(
                previousState: previousState,
                invalidatedGeneration: invalidatedGeneration,
                record: record
            )
        }
        runtimeState = .transitioning(
            generation: invalidatedGeneration,
            purpose: .stop,
            task: task,
            record: record,
            sourceRuntime: previousState.runtimeForClose
        )
        await task.value
    }

    /// Permanently closes this Store and awaits every resource it owns.
    ///
    /// The first call closes mutation admission and records one application-lifetime
    /// close operation. Concurrent and later calls join or replay that exact result.
    /// After close begins, `start(forceRestartIfNeeded:)` and `restart()` are no-ops
    /// and new review mutations are rejected. A thrown error reports the recorded
    /// lifecycle failures after all close stages have been attempted.
    public func close() async throws {
        closeCallerCount += 1
        let completedCloseCallerWaiters = closeCallerWaiters.filter {
            closeCallerCount >= $0.targetCount
        }
        closeCallerWaiters.removeAll {
            closeCallerCount >= $0.targetCount
        }
        for waiter in completedCloseCallerWaiters {
            waiter.continuation.resume()
        }
        let task: Task<Result<Void, ReviewCloseError>, Never>
        switch lifetimeState {
        case .open:
            storeCommandRegistry.closeAdmission()
            let previousRuntimeState = runtimeState
            let invalidatedGeneration = previousRuntimeState.generation.successor()
            let failureLedger = ReviewCloseFailureLedger()
            applicationCloseFailureLedger = failureLedger
            let newTask = Task<Result<Void, ReviewCloseError>, Never> { @MainActor [self] in
                return await self.performApplicationClose(
                    previousRuntimeState: previousRuntimeState,
                    invalidatedGeneration: invalidatedGeneration,
                    failureLedger: failureLedger
                )
            }
            lifetimeState = .closing(newTask)
            task = newTask
        case .closing(let existingTask):
            task = existingTask
        case .closed(let result):
            try result.get()
            return
        }

        let result = await task.value
        lifetimeState = .closed(result)
        applicationCloseFailureLedger = nil
        try result.get()
    }

    package func waitForCloseCallersForTesting(_ count: Int) async {
        if closeCallerCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if closeCallerCount >= count {
                continuation.resume()
            } else {
                closeCallerWaiters.append(.init(
                    targetCount: count,
                    continuation: continuation
                ))
            }
        }
    }

    package func registerStoreCommand() -> UInt64? {
        storeCommandRegistry.register()
    }

    package func installOwnedStoreCommandTask(
        _ task: Task<Void, Never>,
        for id: UInt64
    ) {
        storeCommandRegistry.installOwnedTask(task, for: id)
    }

    package func finishStoreCommand(_ id: UInt64) {
        storeCommandRegistry.finish(id)
    }

    package func waitForAdmittedStoreCommands() async {
        if storeCommandRegistry.activeIDs.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            storeCommandRegistry.appendDrainWaiter(continuation)
        }
    }

    package func performAdmittedStoreCommand(
        _ operation: @MainActor () async -> Void
    ) async {
        guard let commandID = registerStoreCommand() else {
            return
        }
        defer { finishStoreCommand(commandID) }
        await operation()
    }

    package func performThrowingAdmittedStoreCommand<Value>(
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        guard let commandID = registerStoreCommand() else {
            throw CodexReviewAPI.Error.io("Review Store is closed.")
        }
        defer { finishStoreCommand(commandID) }
        return try await operation()
    }

    private func performApplicationClose(
        previousRuntimeState: ReviewStoreRuntimeState,
        invalidatedGeneration: ReviewRuntimeGeneration,
        failureLedger: ReviewCloseFailureLedger
    ) async -> Result<Void, ReviewCloseError> {
        let runningRuntime = previousRuntimeState.runtimeForClose
        if let lastRuntimeTransitionRecord {
            failureLedger.importReceipts(from: lastRuntimeTransitionRecord)
        }

        await backend.mcpServerLifecycle.closeAdmission()
        await cancelAndAwaitAllReviewMutationTasks()

        let cancellation = await requestActiveReviewCancellationsForApplicationClose(
            failureLedger: failureLedger
        )

        await runningRuntime?.handle.closeAdmission()
        var runtimePhysicalCloseCompleted = false
        let unresolvedCancellationJobIDs = cancellation.jobIDs.filter { jobID in
            cancellation.failedJobIDs.contains(jobID)
                && (job(id: jobID)?.isTerminal == false || reviewWorkerTasks[jobID] != nil)
        }
        if unresolvedCancellationJobIDs.isEmpty == false {
            if let runningRuntime {
                await applicationCloseRuntime(
                    runningRuntime,
                    failureLedger: failureLedger
                )
                runtimePhysicalCloseCompleted = true
                await awaitReviewWorkers(jobIDs: unresolvedCancellationJobIDs)
            } else {
                await cancelAndAwaitReviewWorkersForRuntimeStop(
                    jobIDs: unresolvedCancellationJobIDs
                )
            }
        }
        await finishAllReviewWaitersForStoreClose()

        do {
            try await backend.mcpServerLifecycle.drainAdmittedHandlers()
        } catch {
            failureLedger.record(closePrimaryFailure(
                from: error,
                fallback: .mcpHandlerDrain(error.localizedDescription)
            ))
        }

        var mcpCloseFailureWasRecorded = false
        do {
            try await backend.mcpServerLifecycle.close()
        } catch {
            mcpCloseFailureWasRecorded = true
            failureLedger.record(closePrimaryFailure(
                from: error,
                fallback: .mcpServer(error.localizedDescription)
            ))
        }
        do {
            try await backend.mcpServerLifecycle.waitUntilClosed()
        } catch {
            if mcpCloseFailureWasRecorded == false {
                failureLedger.record(closePrimaryFailure(
                    from: error,
                    fallback: .mcpServer(error.localizedDescription)
                ))
            }
        }

        await cancelAccountRateLimitAutoRefreshAndWait()
        switch previousRuntimeState {
        case .acquiring(_, let task, let record),
             .transitioning(_, _, let task, let record, _):
            task.cancel()
            await task.value
            failureLedger.merge(record)
        case .stopped, .running, .failed:
            if let lastRuntimeTransitionRecord {
                failureLedger.merge(lastRuntimeTransitionRecord)
            }
            break
        }

        await cancelAndAwaitAllReviewMutationTasks()
        await cancelAndAwaitOwnedStoreCommandTasks()
        await waitForAdmittedStoreCommands()
        await awaitAllReviewWorkers()
        await finishAllReviewWaitersForStoreClose()
        do {
            try await backend.stop(store: self)
        } catch {
            failureLedger.record(closePrimaryFailure(
                from: error,
                fallback: .client(error.localizedDescription)
            ))
        }
        await backend.waitUntilStopped()

        for jobID in reviewRegistrationOrder
            where failureLedger.consumedReviewCleanupJobIDs.contains(jobID) == false {
            if let failure = reviewCleanupFailures[jobID] {
                failureLedger.recordReviewCleanupFailure(failure, jobID: jobID)
            }
        }

        if let runningRuntime, runtimePhysicalCloseCompleted == false {
            await applicationCloseRuntime(
                runningRuntime,
                failureLedger: failureLedger
            )
        }

        runtimeState = .stopped(invalidatedGeneration)
        let result: Result<Void, ReviewCloseError>
        if let first = failureLedger.failures.first {
            let closeError = ReviewCloseError(failures: .init(
                first: first,
                additionalInLifecycleOrder: Array(failureLedger.failures.dropFirst())
            ))
            transitionToFailed(closeError.localizedDescription)
            result = .failure(closeError)
        } else {
            transitionToStopped()
            result = .success(())
        }
        return result
    }

    private func applicationCloseRuntime(
        _ runtime: PreparedRuntime,
        failureLedger: ReviewCloseFailureLedger
    ) async {
        _ = await runtime.closeRecord.closeAndWait(
            handle: runtime.handle,
            purpose: .applicationClose
        )
        failureLedger.record(contentsOf: runtime.closeRecord.consumeFailures())
    }

    private func closePrimaryFailure(
        from error: any Error,
        fallback: ReviewLifecycleResourceFailure
    ) -> ReviewClosePrimaryFailure {
        if let failure = error as? ReviewInterruptRequestFailure {
            return .interruptRequest(failure)
        }
        if let failure = error as? ReviewRuntimeCloseFailure {
            return .attemptRuntime(failure)
        }
        if let aggregate = error as? ReviewLifecycleResourceFailureAggregate {
            return .lifecycleResources(aggregate)
        }
        if let failure = error as? ReviewLifecycleResourceFailure {
            return .lifecycleResources(.init(first: failure))
        }
        return .lifecycleResources(.init(first: fallback))
    }

    private func performRuntimeStop(
        previousState: ReviewStoreRuntimeState,
        invalidatedGeneration: ReviewRuntimeGeneration,
        record: ReviewRuntimeTransitionRecord
    ) async {
        defer { lastRuntimeTransitionRecord = record }
        switch previousState {
        case .acquiring(_, let task, let previousRecord):
            task.cancel()
            await stopPreparedMCPServer(record: record)
            await task.value
            record.merge(previousRecord)
        case .running(_, let runtime, _):
            await stopPublishedRuntime(runtime, record: record)
        case .transitioning(_, _, let task, let previousRecord, _):
            task.cancel()
            await task.value
            record.merge(previousRecord)
            await stopPreparedMCPServer(record: record)
        case .failed:
            await stopPreparedMCPServer(record: record)
        case .stopped:
            break
        }
        guard case .transitioning(let currentGeneration, .stop, _, _, _) = runtimeState,
              currentGeneration == invalidatedGeneration
        else {
            return
        }
        runtimeState = .stopped(invalidatedGeneration)
        if let failureDescription = record.failureDescription {
            transitionToFailed(failureDescription)
        } else {
            transitionToStopped()
        }
    }

    private func stopPublishedRuntime(
        _ runtime: PreparedRuntime,
        record: ReviewRuntimeTransitionRecord
    ) async {
        await performPublishedRuntimeSemanticStop(record: record)
        await runtime.handle.closeAdmission()
        await stopPreparedMCPServer(record: record)
        await closeAppServerRuntime(
            runtime,
            purpose: .stop,
            record: record
        )
    }

    private func performPublishedRuntimeSemanticStop(
        record: ReviewRuntimeTransitionRecord
    ) async {
        let cancellation = await requestActiveReviewCancellationsForApplicationClose(
            reason: .system(message: "Review runtime stopped."),
            failureLedger: record
        )
        do {
            try await backend.stop(store: self)
        } catch {
            record.record(error, fallback: .client(error.localizedDescription))
        }
        let remainingLocallyCancelledJobIDs = cancelActiveReviewsLocallyForRuntimeStop(cancelWorkers: false)
        await cancelAndAwaitReviewWorkersForRuntimeStop(
            jobIDs: cancellation.jobIDs + remainingLocallyCancelledJobIDs
        )
        for jobID in cancellation.jobIDs
            where record.consumedReviewCleanupJobIDs.contains(jobID) == false {
            if let failure = reviewCleanupFailures[jobID] {
                record.recordReviewCleanupFailure(failure, jobID: jobID)
            }
        }
        await cancelAccountRateLimitAutoRefreshAndWait()
    }

    private func closeAppServerRuntime(
        _ runtime: PreparedRuntime,
        purpose: ReviewRuntimeTransitionPurpose,
        record: ReviewRuntimeTransitionRecord
    ) async {
        let result = await runtime.closeRecord.closeAndWait(
            handle: runtime.handle,
            purpose: purpose
        )
        record.record(contentsOf: runtime.closeRecord.consumeFailures())
        if result.failures.isEmpty == false {
            writeDiagnosticsIfNeeded()
        }
    }

    public func restart() async {
        await start(forceRestartIfNeeded: true)
    }

    public func waitUntilStopped() async {
        if case .transitioning(_, _, let task, _, _) = runtimeState {
            await task.value
        }
        await backend.waitUntilStopped()
        try? await backend.mcpServerLifecycle.waitUntilStopped()
    }

    private func performRuntimeAcquisition(
        generation: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose,
        record: ReviewRuntimeTransitionRecord
    ) async {
        defer { lastRuntimeTransitionRecord = record }
        guard isCurrentAcquisition(generation) else {
            return
        }
        var preparedMCPServer: PreparedMCPServer?
        var preparedRuntime: PreparedRuntime?
        do {
            let mcpServer = try await backend.mcpServerLifecycle.prepare()
            preparedMCPServer = mcpServer
            guard isCurrentAcquisition(generation) else {
                if currentTransitionOwnsMCPStop == false {
                    await stopPreparedMCPServer(record: record)
                }
                return
            }

            let runtime = try await backend.prepareRuntime(
                generation: generation,
                purpose: purpose
            )
            preparedRuntime = runtime
            guard isCurrentAcquisition(generation) else {
                await closeStaleRuntime(
                    runtime,
                    mcpServerWasPrepared: true,
                    purpose: purpose,
                    record: record
                )
                return
            }

            try await runtime.handle.activate()
            guard isCurrentAcquisition(generation) else {
                await closeStaleRuntime(
                    runtime,
                    mcpServerWasPrepared: true,
                    purpose: purpose,
                    record: record
                )
                return
            }
            publishRuntimeSnapshot(runtime.snapshot)

            let mcpSnapshot = try await backend.mcpServerLifecycle.activate(
                mcpServer.generation
            )
            guard isCurrentAcquisition(generation) else {
                await closeStaleRuntime(
                    runtime,
                    mcpServerWasPrepared: true,
                    purpose: purpose,
                    record: record
                )
                return
            }

            runtimeState = .running(
                generation: generation,
                runtime: runtime,
                mcpGeneration: mcpServer.generation
            )
            publishMCPServer(serverURL: mcpSnapshot.serverURL)
        } catch {
            let visibleFailureDescription: String
            if let preparationFailure = error as? ReviewRuntimePreparationFailure {
                record.record(.lifecycleResources(preparationFailure.cleanupFailures))
                visibleFailureDescription = preparationFailure.preparationDescription
            } else {
                visibleFailureDescription = error.localizedDescription
            }
            if let preparedRuntime {
                await closeStaleRuntime(
                    preparedRuntime,
                    mcpServerWasPrepared: preparedMCPServer != nil,
                    purpose: purpose,
                    record: record
                )
            } else if preparedMCPServer != nil,
                      currentTransitionOwnsMCPStop == false {
                await stopPreparedMCPServer(record: record)
            }
            guard isCurrentAcquisition(generation) else {
                return
            }
            runtimeState = .stopped(generation)
            transitionToFailed(visibleFailureDescription)
        }
    }

    package func performRuntimeAcquisitionForTesting(
        generation: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose
    ) async {
        await performRuntimeAcquisition(
            generation: generation,
            purpose: purpose,
            record: ReviewRuntimeTransitionRecord()
        )
    }

    private func performRuntimeReplacement(
        generation: ReviewRuntimeGeneration,
        previousRuntime: PreparedRuntime?,
        retainedMCPGeneration: MCPServerGeneration,
        retainedServerURL: URL?,
        record: ReviewRuntimeTransitionRecord
    ) async {
        defer { lastRuntimeTransitionRecord = record }
        var preparedRuntime: PreparedRuntime?
        if let previousRuntime {
            await performPublishedRuntimeSemanticStop(record: record)
            await previousRuntime.handle.closeAdmission()
            await closeAppServerRuntime(
                previousRuntime,
                purpose: .restartSameAccount,
                record: record
            )
        }
        guard isCurrentTransition(generation, purpose: .restartSameAccount) else {
            return
        }
        do {
            let runtime = try await backend.prepareRuntime(
                generation: generation,
                purpose: .restartSameAccount
            )
            preparedRuntime = runtime
            guard isCurrentTransition(generation, purpose: .restartSameAccount) else {
                await closeStaleRuntime(
                    runtime,
                    mcpServerWasPrepared: false,
                    purpose: .restartSameAccount,
                    record: record
                )
                return
            }

            try await runtime.handle.activate()
            guard isCurrentTransition(generation, purpose: .restartSameAccount) else {
                await closeStaleRuntime(
                    runtime,
                    mcpServerWasPrepared: false,
                    purpose: .restartSameAccount,
                    record: record
                )
                return
            }

            publishRuntimeSnapshot(runtime.snapshot)
            runtimeState = .running(
                generation: generation,
                runtime: runtime,
                mcpGeneration: retainedMCPGeneration
            )
            publishMCPServer(serverURL: retainedServerURL)
        } catch {
            if let preparedRuntime {
                await closeStaleRuntime(
                    preparedRuntime,
                    mcpServerWasPrepared: false,
                    purpose: .restartSameAccount,
                    record: record
                )
            }
            guard isCurrentTransition(generation, purpose: .restartSameAccount) else {
                return
            }
            runtimeState = .failed(
                generation: generation,
                retainedMCPGeneration: retainedMCPGeneration,
                serverURL: retainedServerURL
            )
            serverURL = retainedServerURL
            serverState = .failed(error.localizedDescription)
            writeDiagnosticsIfNeeded()
        }
    }

    private func isCurrentAcquisition(
        _ generation: ReviewRuntimeGeneration
    ) -> Bool {
        guard case .open = lifetimeState else {
            return false
        }
        guard case .acquiring(let currentGeneration, _, _) = runtimeState else {
            return false
        }
        return currentGeneration == generation
    }

    private func isCurrentTransition(
        _ generation: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose
    ) -> Bool {
        guard case .open = lifetimeState else {
            return false
        }
        guard case .transitioning(
            let currentGeneration,
            let currentPurpose,
            _,
            _,
            _
        ) = runtimeState else {
            return false
        }
        return currentGeneration == generation && currentPurpose == purpose
    }

    private var currentTransitionOwnsMCPStop: Bool {
        switch lifetimeState {
        case .closing, .closed:
            return true
        case .open:
            break
        }
        guard case .transitioning(_, let purpose, _, _, _) = runtimeState else {
            return false
        }
        return purpose == .stop || purpose == .applicationClose
    }

    private func closeStaleRuntime(
        _ runtime: PreparedRuntime,
        mcpServerWasPrepared: Bool,
        purpose: ReviewRuntimeTransitionPurpose,
        record: ReviewRuntimeTransitionRecord
    ) async {
        await runtime.handle.closeAdmission()
        let result = await runtime.closeRecord.closeAndWait(
            handle: runtime.handle,
            purpose: purpose
        )
        record.record(contentsOf: runtime.closeRecord.consumeFailures())
        if result.failures.isEmpty == false {
            writeDiagnosticsIfNeeded()
        }
        if mcpServerWasPrepared, currentTransitionOwnsMCPStop == false {
            await stopPreparedMCPServer(record: record)
        }
    }

    private func stopPreparedMCPServer(
        record: ReviewRuntimeTransitionRecord
    ) async {
        var stopFailureWasRecorded = false
        do {
            try await backend.mcpServerLifecycle.stop()
        } catch {
            stopFailureWasRecorded = true
            record.record(
                error,
                fallback: .mcpServer(error.localizedDescription)
            )
            writeDiagnosticsIfNeeded()
        }
        do {
            try await backend.mcpServerLifecycle.waitUntilStopped()
        } catch {
            if stopFailureWasRecorded == false {
                record.record(
                    error,
                    fallback: .mcpServer(error.localizedDescription)
                )
            }
            writeDiagnosticsIfNeeded()
        }
    }

    private func publishRuntimeSnapshot(_ snapshot: RuntimePublicationSnapshot) {
        settings.apply(snapshot: snapshot.settings)
        applyRuntimeAuthenticationSnapshot(snapshot.authentication)
    }

    private func publishMCPServer(serverURL: URL?) {
        transitionToRunning(serverURL: serverURL)
        startAccountRateLimitAutoRefresh()
    }

    private func applyRuntimeAuthenticationSnapshot(
        _ snapshot: CodexReviewBackendModel.Auth.Snapshot
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

    public func refreshAuthentication() async {
        await performAdmittedStoreCommand {
            await backend.refreshAuth(auth: auth)
        }
    }

    public func signIn() async {
        await performAdmittedStoreCommand {
            await backend.signIn(auth: auth)
        }
    }

    public func addAccount() async {
        await performAdmittedStoreCommand {
            await backend.addAccount(auth: auth)
        }
    }

    public func cancelAuthentication() async {
        await performAdmittedStoreCommand {
            await backend.cancelAuthentication(auth: auth)
        }
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
        await performAdmittedStoreCommand {
            if auth.isAuthenticating, auth.selectedAccount == nil {
                await backend.cancelAuthentication(auth: auth)
                return
            }
            do {
                try await performSignOutActiveAccount()
            } catch {
                if auth.errorMessage == nil, auth.isAuthenticated {
                    auth.updatePhase(.failed(message: error.localizedDescription))
                }
            }
        }
    }

    public func signOutActiveAccount() async throws {
        try await performThrowingAdmittedStoreCommand {
            try await performSignOutActiveAccount()
        }
    }

    private func performSignOutActiveAccount() async throws {
        try await backend.signOutActiveAccount(auth: auth)
    }

    package func switchAccount(_ account: CodexAccount) async throws {
        try await performThrowingAdmittedStoreCommand {
            guard canSwitchAccount(account) else {
                return
            }
            let targetAccount = auth.persistedAccounts.first(where: {
                $0.accountKey == account.accountKey
            })
            if auth.persistedAccounts.contains(where: { $0.isSwitching })
                || auth.selectedAccount?.isSwitching == true {
                return
            }
            targetAccount?.updateIsSwitching(true)
            defer {
                targetAccount?.updateIsSwitching(false)
            }
            try await backend.switchAccount(auth: auth, accountKey: account.accountKey)
        }
    }

    package func requestSwitchAccount(_ account: CodexAccount, requiresConfirmation: Bool) {
        guard case .open = lifetimeState else { return }
        auth.requestSwitchAccount(account, requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func requestSwitchAccountFromUserAction(_ account: CodexAccount) {
        requestSwitchAccount(
            account,
            requiresConfirmation: hasRunningJobs
                && switchActionRequiresRunningJobsConfirmation(for: account)
        )
    }

    package func requestSignOutActiveAccount(requiresConfirmation: Bool) {
        guard case .open = lifetimeState else { return }
        auth.requestSignOutActiveAccount(requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func requestRemoveAccount(_ account: CodexAccount, requiresConfirmation: Bool) {
        guard case .open = lifetimeState else { return }
        auth.requestRemoveAccount(account, requiresConfirmation: requiresConfirmation)
        guard requiresConfirmation == false else {
            return
        }
        confirmPendingAccountAction()
    }

    package func confirmPendingAccountAction() {
        guard case .open = lifetimeState else {
            return
        }
        guard let action = auth.consumePendingAccountAction() else {
            return
        }
        guard let commandID = registerStoreCommand() else {
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.finishStoreCommand(commandID)
            }
            do {
                try await self.executePendingAccountAction(action)
                guard Task.isCancelled == false,
                      case .open = self.lifetimeState
                else {
                    return
                }
                if let warningMessage = self.auth.warningMessage {
                    self.auth.presentAccountActionAlert(
                        title: "Account Updated With Warning",
                        message: warningMessage
                    )
                }
            } catch {
                guard Task.isCancelled == false,
                      case .open = self.lifetimeState
                else {
                    return
                }
                self.auth.presentAccountActionAlert(
                    title: action.failureTitle,
                    message: error.localizedDescription
                )
            }
        }
        installOwnedStoreCommandTask(task, for: commandID)
    }

    package func cancelPendingAccountAction() {
        guard case .open = lifetimeState else { return }
        auth.cancelPendingAccountAction()
    }

    package func dismissAccountActionAlert() {
        guard case .open = lifetimeState else { return }
        auth.dismissAccountActionAlert()
    }

    package func removeAccount(accountKey: String) async throws {
        try await performThrowingAdmittedStoreCommand {
            try await backend.removeAccount(auth: auth, accountKey: accountKey)
        }
    }

    package func reorderPersistedAccount(accountKey: String, toIndex: Int) async throws {
        try await performThrowingAdmittedStoreCommand {
            try await backend.reorderPersistedAccount(
                auth: auth,
                accountKey: accountKey,
                toIndex: toIndex
            )
        }
    }

    package func refreshAccountRateLimits(accountKey: String) async {
        await performAdmittedStoreCommand {
            await backend.refreshAccountRateLimits(auth: auth, accountKey: accountKey)
        }
    }

    package func startStartupAuthRefresh() {
        guard case .open = lifetimeState else { return }
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
        await performAdmittedStoreCommand {
            await settingsService.refresh()
        }
    }

    package func updateSettingsModel(_ model: String) async {
        await performAdmittedStoreCommand {
            await settingsService.updateModel(model)
        }
    }

    package func clearSettingsModelOverride() async {
        await performAdmittedStoreCommand {
            await settingsService.clearModelOverride()
        }
    }

    package func updateSettingsReasoningEffort(_ reasoningEffort: CodexReviewSettings.ReasoningEffort?) async {
        await performAdmittedStoreCommand {
            await settingsService.updateReasoningEffort(reasoningEffort)
        }
    }

    package func clearSettingsReasoningEffort() async {
        await updateSettingsReasoningEffort(nil)
    }

    package func updateSettingsServiceTier(_ serviceTier: CodexReviewSettings.ServiceTier?) async {
        await performAdmittedStoreCommand {
            await settingsService.updateServiceTier(serviceTier)
        }
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
