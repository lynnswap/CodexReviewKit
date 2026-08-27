import Foundation
import CodexReview
import CodexReviewAppServer

package actor AsyncGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    package init() {}

    package func wait() async {
        if isOpen {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    package func waitIgnoringCancellation() async {
        if isOpen {
            return
        }
        let waiterID = UUID()
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters[waiterID] = continuation
            }
        }
    }

    package func open() {
        guard isOpen == false else {
            return
        }
        isOpen = true
        let waiters = Array(waiters.values)
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

package typealias OneShotGate = AsyncGate

package actor ManualClock {
    private var current: Date

    package init(start: Date = Date(timeIntervalSince1970: 0)) {
        self.current = start
    }

    package func now() -> Date {
        current
    }

    package func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }
}

package final class ManualCodexReviewNetworkMonitor: CodexReviewNetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var current: CodexReviewNetworkSnapshot?
    private var continuations: [UUID: AsyncStream<CodexReviewNetworkSnapshot>.Continuation] = [:]

    package init(initialSnapshot: CodexReviewNetworkSnapshot = .satisfied()) {
        self.current = initialSnapshot
    }

    package func snapshots() -> AsyncStream<CodexReviewNetworkSnapshot> {
        let continuationID = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let snapshot: CodexReviewNetworkSnapshot?
            lock.lock()
            continuations[continuationID] = continuation
            snapshot = current
            lock.unlock()
            if let snapshot {
                continuation.yield(snapshot)
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: continuationID)
            }
        }
    }

    package func yield(_ snapshot: CodexReviewNetworkSnapshot) {
        let continuations: [AsyncStream<CodexReviewNetworkSnapshot>.Continuation]
        lock.lock()
        current = snapshot
        continuations = Array(self.continuations.values)
        lock.unlock()
        for continuation in continuations {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

package struct FakeCodexReviewBackendError: LocalizedError, Sendable {
    package var message: String

    package init(message: String) {
        self.message = message
    }

    package var errorDescription: String? {
        message
    }
}

package struct FakeCodexReviewBackendTimeout: LocalizedError, Sendable {
    package var operation: String

    package init(operation: String) {
        self.operation = operation
    }

    package var errorDescription: String? {
        "Timed out waiting for \(operation)."
    }
}

private func withFakeBackendTimeout(
    operation: String,
    timeout: Duration,
    wait: @escaping @Sendable () async -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            await wait()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw FakeCodexReviewBackendTimeout(operation: operation)
        }
        defer {
            group.cancelAll()
        }
        _ = try await group.next()
    }
}

package actor FakeCodexReviewBackend: CodexReviewBackend {
    package enum Command: Equatable, Sendable {
        case readSettings
        case applySettings(CodexReviewBackendModel.Settings.Change)
        case readAuth
        case startLogin(CodexReviewBackendModel.Login.Request)
        case cancelLogin(CodexReviewBackendModel.Login.Challenge)
        case completeLogin(CodexReviewBackendModel.Login.Response)
        case logout(CodexReviewBackendModel.Account.ID)
        case startReview(CodexReviewBackendModel.Review.Start)
        case interruptReview(CodexReviewBackendModel.Review.Run, CodexReviewBackendModel.CancellationReason)
        case interruptReviewAdmission(ReviewInterruptRequestAdmission, CodexReviewBackendModel.CancellationReason)
        case prepareReviewRecovery(ReviewRecoveryCandidate)
        case resumeReviewRecoveryHandoff(ReviewRecoveryHandoff, CodexReviewBackendModel.Review.Start)
        case cleanupReview(CodexReviewBackendModel.Review.Run)
    }

    private var settings: CodexReviewBackendModel.Settings.Snapshot
    private var settingsUpdateFailureMessage: String?
    private var settingsUpdateIsCancelled = false
    private var settingsUpdateGate: AsyncGate?
    private var settingsUpdateStartedGate = AsyncGate()
    private var settingsUpdateChecksCancellationAfterGate = false
    private var auth: CodexReviewBackendModel.Auth.Snapshot
    private var commands: [Command] = []
    private var startAdmissionIdentities: [ObjectIdentifier] = []
    private var nextRun: CodexReviewBackendModel.Review.Run
    private var nextRecoveredRun: CodexReviewBackendModel.Review.Run?
    private var interruptFailureMessage: String?
    private var interruptRejectionMessage: String?
    private var recoveryFailureMessage: String?
    private var cleanupFailure: ReviewRuntimeCloseFailure?
    private var cleanupReviewTaskWasCancelled = false
    private var cleanupReviewStartedGate = AsyncGate()
    private var interruptReviewGate: AsyncGate?
    private var cleanupReviewGate: AsyncGate?
    private var interruptReviewWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var prepareReviewRecoveryWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var startReviewGate: AsyncGate?
    private var startReviewGateIgnoresCancellation = false
    private var startReviewWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var resumeReviewRecoveryGate: AsyncGate?
    private var resumeReviewRecoveryWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var eventMailboxes: [EventMailboxKey: BackendReviewEventMailbox] = [:]

    private struct EventMailboxKey: Hashable, Sendable {
        var attemptID: String
        var threadID: String
        var turnID: String?
        var reviewThreadID: String?
        var model: String?

        init(run: CodexReviewBackendModel.Review.Run) {
            self.attemptID = run.attemptID
            self.threadID = run.threadID
            self.turnID = run.turnID
            self.reviewThreadID = run.reviewThreadID
            self.model = run.model
        }
    }

    package init(
        settings: CodexReviewBackendModel.Settings.Snapshot = .init(),
        auth: CodexReviewBackendModel.Auth.Snapshot = .init(),
        nextRun: CodexReviewBackendModel.Review.Run = .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1")
    ) {
        self.settings = settings
        self.auth = auth
        self.nextRun = nextRun
    }

    package func recordedCommands() -> [Command] {
        commands
    }

    package func holdStartReview(with gate: AsyncGate) {
        startReviewGate = gate
        startReviewGateIgnoresCancellation = false
    }

    package func holdStartReviewIgnoringCancellation(with gate: AsyncGate) {
        startReviewGate = gate
        startReviewGateIgnoresCancellation = true
    }

    package func failInterrupts(message: String) {
        interruptFailureMessage = message
    }
    package func rejectInterrupts(message: String) { interruptRejectionMessage = message }

    package func failRecovery(message: String) {
        recoveryFailureMessage = message
    }

    package func failCleanup(message: String) {
        cleanupFailure = .cleanup(message)
    }

    package func failNextSettingsUpdate(message: String) {
        settingsUpdateFailureMessage = message
    }

    package func cancelNextSettingsUpdate() {
        settingsUpdateIsCancelled = true
    }

    package func holdNextSettingsUpdate(with gate: AsyncGate) {
        settingsUpdateGate = gate
        settingsUpdateStartedGate = AsyncGate()
        settingsUpdateChecksCancellationAfterGate = false
    }

    package func holdNextSettingsUpdateCheckingCancellationAfterGate(with gate: AsyncGate) {
        settingsUpdateGate = gate
        settingsUpdateStartedGate = AsyncGate()
        settingsUpdateChecksCancellationAfterGate = true
    }

    package func waitForSettingsUpdate() async {
        await settingsUpdateStartedGate.wait()
    }

    package func settingsSnapshot() -> CodexReviewBackendModel.Settings.Snapshot {
        settings
    }

    package func setSettingsSnapshot(_ snapshot: CodexReviewBackendModel.Settings.Snapshot) {
        settings = snapshot
    }

    package func holdInterruptReview(with gate: AsyncGate) {
        interruptReviewGate = gate
    }

    package func setNextRun(_ run: CodexReviewBackendModel.Review.Run) {
        nextRun = run
    }

    package func holdCleanupReview(with gate: AsyncGate) {
        cleanupReviewGate = gate
        cleanupReviewStartedGate = AsyncGate()
    }

    package func waitForCleanupReview() async {
        await cleanupReviewStartedGate.wait()
    }

    package func cleanupReviewWasCancelled() -> Bool {
        cleanupReviewTaskWasCancelled
    }

    package func holdResumeReviewRecovery(with gate: AsyncGate) {
        resumeReviewRecoveryGate = gate
    }

    package func setNextRecoveredRun(_ run: CodexReviewBackendModel.Review.Run) {
        nextRecoveredRun = run
    }

    package func waitForStartReview() async {
        if commands.contains(where: {
            if case .startReview = $0 {
                true
            } else {
                false
            }
        }) {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if commands.contains(where: {
                    if case .startReview = $0 {
                        true
                    } else {
                        false
                    }
                }) {
                    continuation.resume()
                } else {
                    startReviewWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelStartReviewWaiter(id: waiterID)
            }
        }
    }

    package func waitForStartReview(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "startReview", timeout: timeout) {
            await self.waitForStartReview()
        }
    }

    package func waitForInterruptReview() async {
        if commands.contains(where: {
            if case .interruptReview = $0 {
                true
            } else if case .interruptReviewAdmission = $0 {
                true
            } else {
                false
            }
        }) {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if commands.contains(where: {
                    if case .interruptReview = $0 {
                        true
                    } else if case .interruptReviewAdmission = $0 {
                        true
                    } else {
                        false
                    }
                }) {
                    continuation.resume()
                } else {
                    interruptReviewWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelInterruptReviewWaiter(id: waiterID)
            }
        }
    }

    package func waitForInterruptReview(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "interruptReview", timeout: timeout) {
            await self.waitForInterruptReview()
        }
    }

    package func waitForPrepareReviewRecovery() async {
        if commands.contains(where: {
            if case .prepareReviewRecovery = $0 {
                true
            } else {
                false
            }
        }) {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if commands.contains(where: {
                    if case .prepareReviewRecovery = $0 {
                        true
                    } else {
                        false
                    }
                }) {
                    continuation.resume()
                } else {
                    prepareReviewRecoveryWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelPrepareReviewRecoveryWaiter(id: waiterID)
            }
        }
    }

    package func waitForPrepareReviewRecovery(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "prepareReviewRecovery", timeout: timeout) {
            await self.waitForPrepareReviewRecovery()
        }
    }

    package func waitForResumeReviewRecovery() async {
        if commands.contains(where: {
            if case .resumeReviewRecoveryHandoff = $0 {
                true
            } else {
                false
            }
        }) {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if commands.contains(where: {
                    if case .resumeReviewRecoveryHandoff = $0 {
                        true
                    } else {
                        false
                    }
                }) {
                    continuation.resume()
                } else {
                    resumeReviewRecoveryWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelResumeReviewRecoveryWaiter(id: waiterID)
            }
        }
    }

    package func waitForResumeReviewRecovery(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "resumeReviewRecovery", timeout: timeout) {
            await self.waitForResumeReviewRecovery()
        }
    }

    package func readSettings() async throws -> CodexReviewBackendModel.Settings.Snapshot {
        commands.append(.readSettings)
        return settings
    }

    package func applySettings(_ change: CodexReviewBackendModel.Settings.Change) async throws -> CodexReviewBackendModel.Settings.Snapshot {
        commands.append(.applySettings(change))
        await settingsUpdateStartedGate.open()
        await settingsUpdateGate?.waitIgnoringCancellation()
        settingsUpdateGate = nil
        let checksCancellation = settingsUpdateChecksCancellationAfterGate
        settingsUpdateChecksCancellationAfterGate = false
        if checksCancellation {
            try Task.checkCancellation()
        }
        if settingsUpdateIsCancelled {
            settingsUpdateIsCancelled = false
            throw CancellationError()
        }
        if let settingsUpdateFailureMessage {
            self.settingsUpdateFailureMessage = nil
            throw FakeCodexReviewBackendError(message: settingsUpdateFailureMessage)
        }
        settings = .init(
            model: change.updatesModel ? change.model : settings.model,
            fallbackModel: settings.fallbackModel,
            reasoningEffort: change.updatesReasoningEffort ? change.reasoningEffort : settings.reasoningEffort,
            serviceTier: change.updatesServiceTier ? change.serviceTier : settings.serviceTier,
            models: settings.models
        )
        return settings
    }

    package func readAuth() async throws -> CodexReviewBackendModel.Auth.Snapshot {
        commands.append(.readAuth)
        return auth
    }

    package func startLogin(_ request: CodexReviewBackendModel.Login.Request) async throws -> CodexReviewBackendModel.Login.Challenge {
        commands.append(.startLogin(request))
        return .init(id: "challenge-1")
    }

    package func cancelLogin(_ challenge: CodexReviewBackendModel.Login.Challenge) async throws {
        commands.append(.cancelLogin(challenge))
    }

    package func completeLogin(_ response: CodexReviewBackendModel.Login.Response) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        commands.append(.completeLogin(response))
        let account = CodexReviewBackendModel.Account.Snapshot(id: .init("account-1"), label: "Codex", isActive: true)
        auth = .init(accounts: [account], activeAccountID: account.id)
        return auth
    }

    package func logout(_ account: CodexReviewBackendModel.Account.ID) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        commands.append(.logout(account))
        auth = .init()
        return auth
    }

    package func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        startAdmissionIdentities.append(ObjectIdentifier(admission))
        try await admission.admitThreadStartDispatch()
        commands.append(.startReview(request))
        let waiters = Array(startReviewWaiters.values)
        startReviewWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: nextRun.attemptID,
            threadID: nextRun.threadID,
            reviewThreadID: nextRun.threadID,
            model: nextRun.model
        )
        try await admission.recordPreparedThread(provisionalRun)
        do {
            try await admission.admitReviewStartDispatch(for: provisionalRun)
        } catch {
            commands.append(.cleanupReview(provisionalRun))
            throw error
        }
        if let startReviewGate {
            if startReviewGateIgnoresCancellation {
                await startReviewGate.waitIgnoringCancellation()
            } else {
                await startReviewGate.wait()
            }
        }
        try await admission.recordActiveRun(nextRun)
        return .init(run: nextRun, events: eventMailbox(for: nextRun))
    }

    package func receivedStartAdmission(_ admission: ReviewStartAdmission) -> Bool {
        startAdmissionIdentities.contains(ObjectIdentifier(admission))
    }

    package func interruptReview(_ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason) async throws {
        commands.append(.interruptReview(run, reason))
        let waiters = Array(interruptReviewWaiters.values)
        interruptReviewWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let interruptReviewGate {
            await interruptReviewGate.wait()
        }
        if let interruptFailureMessage {
            throw FakeCodexReviewBackendError(message: interruptFailureMessage)
        }
    }

    package func interruptReview(
        _ admission: ReviewInterruptRequestAdmission,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        commands.append(.interruptReviewAdmission(admission, reason))
        let waiters = Array(interruptReviewWaiters.values)
        interruptReviewWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await interruptReviewGate?.wait()
        if let interruptRejectionMessage { throw ReviewInterruptRequestFailure(outcome: .rejected(code: nil, message: interruptRejectionMessage)) }
        if let interruptFailureMessage {
            throw ReviewInterruptRequestFailure(
                outcome: .outcomeUnknown(message: interruptFailureMessage)
            )
        }
    }

    package func prepareReviewRecovery(
        _ candidate: ReviewRecoveryCandidate
    ) async throws -> ReviewRecoveryHandoff {
        commands.append(.prepareReviewRecovery(candidate))
        let waiters = Array(prepareReviewRecoveryWaiters.values)
        prepareReviewRecoveryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let recoveryFailureMessage {
            throw FakeCodexReviewBackendError(message: recoveryFailureMessage)
        }
        let run = candidate.resolved.run
        return try await candidate.prepareHandoff(token: .init(
            interruptedRun: run,
            rollbackThreadID: run.reviewThreadID ?? run.threadID
        ))
    }

    package func resumeReviewRecovery(
        _ handoff: ReviewRecoveryHandoff,
        request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        commands.append(.resumeReviewRecoveryHandoff(handoff, request))
        let waiters = Array(resumeReviewRecoveryWaiters.values)
        resumeReviewRecoveryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        let consumedHandoff = try await handoff.consume()
        let interruptedRun = consumedHandoff.token.interruptedRun
        try await admission.admitRecoveryRollbackDispatch(for: interruptedRun)
        let recoveredRun = nextRecoveredRun ?? .init(
            attemptID: "attempt-recovered",
            threadID: interruptedRun.threadID,
            turnID: "turn-recovered",
            reviewThreadID: interruptedRun.reviewThreadID,
            model: interruptedRun.model ?? request.model
        )
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: recoveredRun.attemptID,
            threadID: recoveredRun.threadID,
            reviewThreadID: recoveredRun.threadID,
            model: recoveredRun.model
        )
        if let resumeReviewRecoveryGate {
            await resumeReviewRecoveryGate.wait()
        }
        if let recoveryFailureMessage {
            throw FakeCodexReviewBackendError(message: recoveryFailureMessage)
        }
        try await admission.recordRecoveryRollbackAcknowledged(for: interruptedRun)
        try await admission.recordPreparedRecoveryRun(provisionalRun)
        try await admission.admitReviewStartDispatch(for: provisionalRun)
        try await admission.recordActiveRun(recoveredRun)
        return .init(
            run: recoveredRun,
            events: eventMailbox(for: recoveredRun)
        )
    }

    package func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async throws {
        commands.append(.cleanupReview(run))
        await cleanupReviewStartedGate.open()
        if let cleanupReviewGate {
            await cleanupReviewGate.waitIgnoringCancellation()
        }
        cleanupReviewTaskWasCancelled = Task.isCancelled
        if let cleanupFailure {
            throw cleanupFailure
        }
    }

    package func yield(_ event: CodexReviewBackendModel.Review.Event, for run: CodexReviewBackendModel.Review.Run? = nil) async {
        await eventMailbox(for: run ?? nextRun).append(event)
    }

    package func finishEvents(for run: CodexReviewBackendModel.Review.Run? = nil) async {
        await eventMailbox(for: run ?? nextRun).finish()
    }

    package func finishEvents(throwing error: any Error, for run: CodexReviewBackendModel.Review.Run? = nil) async {
        await eventMailbox(for: run ?? nextRun).fail(error)
    }

    package func finishEventMailboxes() async {
        let mailboxes = Array(eventMailboxes.values)
        eventMailboxes.removeAll(keepingCapacity: false)
        for mailbox in mailboxes {
            await mailbox.finish()
        }
    }

    package func hasEventMailbox(for run: CodexReviewBackendModel.Review.Run) -> Bool {
        eventMailboxes[.init(run: run)] != nil
    }

    private func eventMailbox(for run: CodexReviewBackendModel.Review.Run) -> BackendReviewEventMailbox {
        let key = EventMailboxKey(run: run)
        if let mailbox = eventMailboxes[key] {
            return mailbox
        }
        let mailbox = BackendReviewEventMailbox()
        eventMailboxes[key] = mailbox
        return mailbox
    }

    private func cancelStartReviewWaiter(id: UUID) {
        startReviewWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelInterruptReviewWaiter(id: UUID) {
        interruptReviewWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelPrepareReviewRecoveryWaiter(id: UUID) {
        prepareReviewRecoveryWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelResumeReviewRecoveryWaiter(id: UUID) {
        resumeReviewRecoveryWaiters.removeValue(forKey: id)?.resume()
    }

}

@MainActor
package final class StoreSnapshotProbe {
    private let store: CodexReviewStore

    package init(store: CodexReviewStore) {
        self.store = store
    }

    package func snapshot() -> StoreSnapshot {
        let jobs = store.jobs
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.id < rhs.id
                }
                return lhs.sortOrder > rhs.sortOrder
            }
            .map { job in
                StoreJobSnapshot(
                    jobID: job.id,
                    status: job.core.lifecycle.status,
                    summary: job.core.output.summary,
                    lastAgentMessage: job.core.output.lastAgentMessage,
                    logs: job.logEntries,
                    run: job.core.run,
                    activeRun: store.reviewAttemptOwnerships[job.id]?.run,
                    cancellationRequested: job.cancellationRequested
                )
            }
        return StoreSnapshot(jobs: jobs)
    }

    package func waitUntilJobStatus(
        _ status: ReviewJobState,
        jobID: String? = nil,
        timeout: Duration = .seconds(2)
    ) async -> StoreSnapshot? {
        await waitUntil(timeout: timeout) { snapshot in
            snapshot.job(jobID)?.status == status
        }
    }

    package func waitUntilLogs(
        jobID: String? = nil,
        timeout: Duration = .seconds(2),
        matching predicate: @escaping @MainActor (Array<ReviewLogEntry>) -> Bool
    ) async -> StoreSnapshot? {
        await waitUntil(timeout: timeout) { snapshot in
            guard let job = snapshot.job(jobID) else {
                return false
            }
            return predicate(job.logs)
        }
    }

    package func waitUntilRunAttempt(
        _ attemptID: String,
        jobID: String? = nil,
        timeout: Duration = .seconds(2)
    ) async -> StoreSnapshot? {
        await waitUntil(timeout: timeout) { snapshot in
            snapshot.job(jobID)?.activeRun?.attemptID == attemptID
        }
    }

    package func waitUntil(
        timeout: Duration = .seconds(2),
        matching predicate: @escaping @MainActor (StoreSnapshot) -> Bool
    ) async -> StoreSnapshot? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let current = snapshot()
            if predicate(current) {
                return current
            }
            if clock.now >= deadline {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

package struct StoreSnapshot: Sendable {
    package var jobs: [StoreJobSnapshot]

    package func job(_ jobID: String? = nil) -> StoreJobSnapshot? {
        guard let jobID else {
            return jobs.first
        }
        return jobs.first { $0.jobID == jobID }
    }
}

package struct StoreJobSnapshot: Sendable {
    package var jobID: String
    package var status: ReviewJobState
    package var summary: String
    package var lastAgentMessage: String?
    package var logs: [ReviewLogEntry]
    package var run: ReviewJobCore.Run
    package var activeRun: CodexReviewBackendModel.Review.Run?
    package var cancellationRequested: Bool
}

@MainActor
package final class TestingRuntimeLifecycleHandle: RuntimeLifecycleHandle {
    package private(set) var activateCallCount = 0
    package private(set) var closeAdmissionCallCount = 0
    package private(set) var closePurposes: [ReviewRuntimeTransitionPurpose] = []
    package private(set) var waitUntilClosedCallCount = 0

    private let onActivate: @MainActor @Sendable () -> Void
    private let onClose: @MainActor @Sendable (TestingRuntimeLifecycleHandle) -> Void
    private var closeGate: AsyncGate?
    private var closeStartedGate = AsyncGate()
    private var didClose = false
    private var closeFailure: ReviewRuntimeCloseFailure?

    package init(
        onActivate: @escaping @MainActor @Sendable () -> Void = {},
        onClose: @escaping @MainActor @Sendable (TestingRuntimeLifecycleHandle) -> Void = { _ in }
    ) {
        self.onActivate = onActivate
        self.onClose = onClose
    }

    package func activate() async throws {
        activateCallCount += 1
        onActivate()
    }

    package func closeAdmission() {
        closeAdmissionCallCount += 1
    }

    package func holdClose(with gate: AsyncGate) {
        closeGate = gate
        closeStartedGate = AsyncGate()
    }

    package func waitForClose() async {
        await closeStartedGate.wait()
    }

    package func failClose(with failure: ReviewRuntimeCloseFailure) {
        closeFailure = failure
    }

    package func close(purpose: ReviewRuntimeTransitionPurpose) async throws {
        closePurposes.append(purpose)
        await closeStartedGate.open()
        await closeGate?.waitIgnoringCancellation()
        closeGate = nil
        guard didClose == false else {
            return
        }
        didClose = true
        onClose(self)
        if let closeFailure {
            throw closeFailure
        }
    }

    package func waitUntilClosed() async throws {
        waitUntilClosedCallCount += 1
        guard didClose else {
            throw CancellationError()
        }
    }
}

@MainActor
package final class TestingMCPServerLifecycleOwner: MCPServerLifecycleOwner {
    package private(set) var preparedServers: [PreparedMCPServer] = []
    package private(set) var activatedServers: [PreparedMCPServer] = []
    package private(set) var stopCallCount = 0

    private let serverURL: URL?
    private var preparedServer: PreparedMCPServer?
    private var runningServer: PreparedMCPServer?
    private var preparationGate: AsyncGate?
    private var preparationStartedGate = AsyncGate()
    private var preparationCancellationGate = AsyncGate()
    private var stopGate: AsyncGate?
    private var stopStartedGate = AsyncGate()

    package init(serverURL: URL? = nil) {
        self.serverURL = serverURL
    }

    package func holdPreparation(with gate: AsyncGate) {
        preparationGate = gate
        preparationStartedGate = AsyncGate()
        preparationCancellationGate = AsyncGate()
    }

    package func waitForPreparation() async {
        await preparationStartedGate.wait()
    }

    package func waitForPreparationCancellation() async {
        await preparationCancellationGate.wait()
    }

    package func holdStop(with gate: AsyncGate) {
        stopGate = gate
        stopStartedGate = AsyncGate()
    }

    package func waitForStop() async {
        await stopStartedGate.wait()
    }

    package func prepare() async throws -> PreparedMCPServer {
        let preparation = PreparedMCPServer()
        preparedServer = preparation
        preparedServers.append(preparation)
        await preparationStartedGate.open()
        if let preparationGate {
            let cancellationGate = preparationCancellationGate
            await withTaskCancellationHandler {
                await preparationGate.waitIgnoringCancellation()
            } onCancel: {
                Task { await cancellationGate.open() }
            }
            self.preparationGate = nil
        }
        try Task.checkCancellation()
        return preparation
    }

    package func activate(
        _ preparation: PreparedMCPServer
    ) async throws -> MCPServerPublicationSnapshot {
        guard preparedServer === preparation else {
            throw CancellationError()
        }
        preparedServer = nil
        runningServer = preparation
        activatedServers.append(preparation)
        return .init(serverURL: serverURL)
    }

    package func stop() async throws {
        guard preparedServer != nil || runningServer != nil else {
            return
        }
        await stopStartedGate.open()
        await stopGate?.waitIgnoringCancellation()
        stopGate = nil
        preparedServer = nil
        runningServer = nil
        stopCallCount += 1
    }
}

@MainActor
package final class TestingCodexReviewStoreBackend: CodexReviewStoreBackend {
    private enum ScriptedReviewRecoveryRoute {
        case ready(ReviewRuntimeGeneration, ReviewRuntimeGeneration)
        case preparing
        case prepared(PreparedReviewRecovery, ReviewRuntimeGeneration)
        case staging
        case staged(StagedReviewRecovery)
        case discardingPrepared(PreparedReviewRecovery, ReviewRuntimeGeneration)
    }
    package enum ReviewRecoveryCommand {
        case prepare(ReviewRecoveryCandidate, ReviewRuntimeGeneration)
        case stage(PreparedReviewRecovery, ReviewRuntimeGeneration, ReviewStartAdmission)
        case commit(StagedReviewRecovery)
        case discardPrepared(PreparedReviewRecovery)
        case discardStaged(StagedReviewRecovery)
    }
    package let reviewBackend: FakeCodexReviewBackend
    package let seed: CodexReviewStoreSeed
    package var currentSettingsSnapshot: CodexReviewSettings.Snapshot
    package private(set) var isActive = false
    package private(set) var startRequests: [Bool] = []
    package private(set) var reviewRecoveryCommands: [ReviewRecoveryCommand] = []
    package let mcpServerLifecycle: any MCPServerLifecycleOwner
    package private(set) var lastPreparedRuntimeHandle: TestingRuntimeLifecycleHandle?
    private var runtimePreparationGate: AsyncGate?
    private var runtimePreparationFailureMessage: String?
    private var throwsCancellationAfterHeldRuntimePreparation = false
    private var runtimePreparationStartedGate = AsyncGate()
    private var runtimePreparationCancellationGate = AsyncGate()
    private var runtimePublicationAction: (@MainActor @Sendable () async -> Void)?
    private var runtimePublicationIsHeld = false
    private var runtimePublicationHandle: TestingRuntimeLifecycleHandle?
    private var runtimePublicationEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var runtimePublicationReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var semanticStopGate: AsyncGate?
    private var semanticStopStartedGate = AsyncGate()
    private var semanticStopCancellationGate = AsyncGate()
    private var scriptedReviewRecoveryRoute: ScriptedReviewRecoveryRoute?
    private var reviewRecoveryStageGate: AsyncGate?
    private var reviewRecoveryStageStartedGate = AsyncGate()
    private var reviewRecoveryCommitGate: AsyncGate?
    private var reviewRecoveryCommitStartedGate = AsyncGate()

    package init(
        reviewBackend: FakeCodexReviewBackend,
        seed: CodexReviewStoreSeed = .init(),
        mcpServerLifecycle: (any MCPServerLifecycleOwner)? = nil
    ) {
        self.reviewBackend = reviewBackend
        self.seed = seed
        self.currentSettingsSnapshot = seed.initialSettingsSnapshot
        self.mcpServerLifecycle = mcpServerLifecycle ?? NoMCPServerLifecycleOwner()
    }

    package var initialSettingsSnapshot: CodexReviewSettings.Snapshot {
        currentSettingsSnapshot
    }

    package func attachStore(_: CodexReviewStore) {}

    package func scriptReviewRecoveryRoute(
        sourceGeneration: ReviewRuntimeGeneration,
        destinationGeneration: ReviewRuntimeGeneration
    ) throws {
        guard min(sourceGeneration.rawValue, destinationGeneration.rawValue) > 0,
              scriptedReviewRecoveryRoute == nil else {
            throw ReviewAttemptContractFailure(
                message: "Testing recovery requires one explicit unused generation route."
            )
        }
        scriptedReviewRecoveryRoute = .ready(sourceGeneration, destinationGeneration)
    }

    package func holdReviewRecoveryStage(with gate: AsyncGate) {
        reviewRecoveryStageGate = gate
        reviewRecoveryStageStartedGate = AsyncGate()
    }

    package func waitForReviewRecoveryStage() async {
        await reviewRecoveryStageStartedGate.wait()
    }

    package func holdReviewRecoveryCommit(with gate: AsyncGate) {
        reviewRecoveryCommitGate = gate
        reviewRecoveryCommitStartedGate = AsyncGate()
    }

    package func waitForReviewRecoveryCommit() async {
        await reviewRecoveryCommitStartedGate.wait()
    }

    package func holdRuntimePreparation(with gate: AsyncGate) {
        runtimePreparationGate = gate
        runtimePreparationStartedGate = AsyncGate()
        runtimePreparationCancellationGate = AsyncGate()
    }

    package func waitForRuntimePreparation() async {
        await runtimePreparationStartedGate.wait()
    }

    package func waitForRuntimePreparationCancellation() async {
        await runtimePreparationCancellationGate.wait()
    }

    package func failNextRuntimePreparation(message: String) {
        runtimePreparationFailureMessage = message
    }

    package func throwCancellationAfterHeldRuntimePreparation() {
        throwsCancellationAfterHeldRuntimePreparation = true
    }

    package func runOnNextRuntimePublication(
        _ action: @escaping @MainActor @Sendable () async -> Void
    ) {
        precondition(
            runtimePublicationAction == nil,
            "TestingCodexReviewStoreBackend owns one runtime publication action at a time."
        )
        runtimePublicationAction = action
    }

    package func holdRuntimePublication() {
        precondition(
            runtimePublicationIsHeld == false && runtimePublicationReleaseWaiters.isEmpty,
            "TestingCodexReviewStoreBackend owns one held runtime publication at a time."
        )
        runtimePublicationIsHeld = true
        runtimePublicationHandle = nil
    }

    package func holdSemanticStop(with gate: AsyncGate) {
        semanticStopGate = gate
        semanticStopStartedGate = AsyncGate()
        semanticStopCancellationGate = AsyncGate()
    }

    package func waitForSemanticStop() async { await semanticStopStartedGate.wait() }
    package func waitForSemanticStopCancellation() async {
        await semanticStopCancellationGate.wait()
    }

    package func waitForRuntimePublicationEntry() async {
        if runtimePublicationHandle != nil {
            return
        }
        await withCheckedContinuation { continuation in
            if runtimePublicationHandle != nil {
                continuation.resume()
            } else {
                runtimePublicationEntryWaiters.append(continuation)
            }
        }
    }

    package func releaseRuntimePublication() {
        guard runtimePublicationIsHeld else {
            return
        }
        runtimePublicationIsHeld = false
        let waiters = runtimePublicationReleaseWaiters
        runtimePublicationReleaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    package func prepareRuntime(
        generation _: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose
    ) async throws -> PreparedRuntime {
        startRequests.append(purpose == .restartSameAccount)
        let handle = TestingRuntimeLifecycleHandle(
            onActivate: { [weak self] in self?.isActive = true },
            onClose: { [weak self] handle in
                guard let self else {
                    return
                }
                self.isActive = false
                if self.runtimePublicationHandle === handle {
                    self.releaseRuntimePublication()
                }
            }
        )
        lastPreparedRuntimeHandle = handle
        await runtimePreparationStartedGate.open()
        if let runtimePreparationGate {
            let cancellationGate = runtimePreparationCancellationGate
            await withTaskCancellationHandler {
                await runtimePreparationGate.waitIgnoringCancellation()
            } onCancel: {
                Task { await cancellationGate.open() }
            }
            self.runtimePreparationGate = nil
        }
        if throwsCancellationAfterHeldRuntimePreparation {
            throwsCancellationAfterHeldRuntimePreparation = false
            try Task.checkCancellation()
        }
        if let runtimePreparationFailureMessage {
            self.runtimePreparationFailureMessage = nil
            throw FakeCodexReviewBackendError(message: runtimePreparationFailureMessage)
        }
        let settings = try await monitoredSettingsSnapshot()
        currentSettingsSnapshot = settings
        return PreparedRuntime(
            snapshot: .init(
                authentication: try await reviewBackend.readAuth(),
                settings: settings
            ),
            handle: handle
        )
    }

    package func waitForRuntimePublication(
        handle: any RuntimeLifecycleHandle
    ) async {
        let action = runtimePublicationAction
        runtimePublicationAction = nil
        await action?()
        guard let handle = handle as? TestingRuntimeLifecycleHandle else {
            return
        }
        runtimePublicationHandle = handle
        let entryWaiters = runtimePublicationEntryWaiters
        runtimePublicationEntryWaiters.removeAll(keepingCapacity: false)
        for waiter in entryWaiters {
            waiter.resume()
        }
        if runtimePublicationIsHeld {
            await withCheckedContinuation { continuation in
                if runtimePublicationIsHeld {
                    runtimePublicationReleaseWaiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
        if runtimePublicationHandle === handle {
            runtimePublicationHandle = nil
        }
    }

    package func stop(
        context: ReviewRuntimeSemanticStopContext,
        intent: ReviewRuntimeTeardownIntent
    ) async {
        await semanticStopStartedGate.open()
        if let semanticStopGate {
            let cancellationGate = semanticStopCancellationGate
            await withTaskCancellationHandler {
                await semanticStopGate.waitIgnoringCancellation()
            } onCancel: {
                Task { @MainActor in
                    context.cancelTransferredWorkers()
                    await cancellationGate.open()
                }
            }
            self.semanticStopGate = nil
        }
        await context.stopUsingDefaultPolicy(intent: intent)
        isActive = false
    }

    package func waitUntilStopped() async {}

    package func refreshAuth(auth: CodexReviewAuthModel) async {
        do {
            let snapshot = try await reviewBackend.readAuth()
            let accounts = snapshot.accounts.compactMap { account -> CodexAccount? in
                let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.isEmpty == false else {
                    return nil
                }
                return CodexAccount(email: label)
            }
            auth.applyPersistedAccountStates(
                accounts.map(savedAccountPayload(from:)),
                activeAccountKey: snapshot.activeAccountID?.rawValue
            )
            auth.selectPersistedAccount(snapshot.activeAccountID?.rawValue)
            auth.updatePhase(auth.selectedAccount == nil ? .signedOut : .signedOut)
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
    }

    package func signIn(auth: CodexReviewAuthModel) async {
        do {
            let challenge = try await reviewBackend.startLogin(.init())
            auth.updatePhase(.signingIn(.init(
                title: "Sign in to Codex",
                detail: "Complete sign in in your browser, then return to ReviewMonitor.",
                browserURL: challenge.verificationURL?.absoluteString,
                userCode: challenge.userCode
            )))
        } catch {
            auth.updatePhase(.failed(message: error.localizedDescription))
        }
    }

    package func addAccount(auth: CodexReviewAuthModel) async {
        await signIn(auth: auth)
    }

    package func cancelAuthentication(auth: CodexReviewAuthModel) async {
        auth.updatePhase(auth.selectedAccount == nil ? .signedOut : .signedOut)
    }

    package func switchAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        guard auth.persistedAccounts.contains(where: { $0.accountKey == accountKey }) else {
            return
        }
        auth.applyPersistedAccountStates(
            auth.persistedAccounts.map(savedAccountPayload(from:)),
            activeAccountKey: accountKey
        )
        auth.selectPersistedAccount(auth.persistedAccounts.first(where: { $0.accountKey == accountKey })?.id)
        auth.updatePhase(.signedOut)
    }

    package func removeAccount(auth: CodexReviewAuthModel, accountKey: String) async throws {
        let filteredAccounts = auth.persistedAccounts.filter { $0.accountKey != accountKey }
        auth.applyPersistedAccountStates(filteredAccounts.map(savedAccountPayload(from:)))
        if auth.selectedAccount?.accountKey == accountKey {
            auth.selectPersistedAccount(nil)
            auth.updatePhase(.signedOut)
        }
    }

    package func reorderPersistedAccount(
        auth: CodexReviewAuthModel,
        accountKey: String,
        toIndex: Int
    ) async throws {
        var reorderedAccounts = auth.persistedAccounts
        guard let sourceIndex = reorderedAccounts.firstIndex(where: { $0.accountKey == accountKey }) else {
            return
        }
        let destinationIndex = max(0, min(toIndex, reorderedAccounts.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }
        let account = reorderedAccounts.remove(at: sourceIndex)
        reorderedAccounts.insert(account, at: destinationIndex)
        auth.applyPersistedAccountStates(reorderedAccounts.map(savedAccountPayload(from:)))
    }

    package func signOutActiveAccount(auth: CodexReviewAuthModel) async throws {
        if let account = auth.selectedAccount {
            _ = try await reviewBackend.logout(.init(account.accountKey))
        }
        auth.updatePhase(.signedOut)
        auth.selectPersistedAccount(nil)
        auth.applyPersistedAccountStates([])
    }

    package func refreshAccountRateLimits(auth _: CodexReviewAuthModel, accountKey _: String) async {}

    package func requiresCurrentSessionRecovery(auth _: CodexReviewAuthModel, accountKey _: String) -> Bool {
        false
    }

    package func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        try await reviewBackend.startReview(request, admission: admission)
    }

    package func interruptReview(
        _ run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        try await reviewBackend.interruptReview(run, reason: reason)
    }

    package func interruptReview(
        _ admission: ReviewInterruptRequestAdmission,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        try await reviewBackend.interruptReview(admission, reason: reason)
    }

    package func prepareReviewRecovery(
        _ candidate: ReviewRecoveryCandidate
    ) async throws -> PreparedReviewRecovery {
        guard case .ready(let sourceGeneration, let destinationGeneration) = scriptedReviewRecoveryRoute else {
            throw recoveryRouteFailure("prepare")
        }
        let receipt = ReviewRecoveryRouteReceipt(
            sourceRun: candidate.resolved.run,
            sourceGeneration: sourceGeneration
        )
        scriptedReviewRecoveryRoute = .preparing
        reviewRecoveryCommands.append(.prepare(candidate, sourceGeneration))
        do {
            let prepared = PreparedReviewRecovery(
                receipt: receipt,
                handoff: try await reviewBackend.prepareReviewRecovery(candidate)
            )
            scriptedReviewRecoveryRoute = .prepared(prepared, destinationGeneration)
            return prepared
        } catch {
            scriptedReviewRecoveryRoute = nil
            throw await recoveryFailure(error, cleanupRun: candidate.resolved.run)
        }
    }

    package func stageReviewRecovery(
        _ prepared: PreparedReviewRecovery,
        destinationGeneration: ReviewRuntimeGeneration,
        request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery {
        let admissionPhase = await admission.currentPhase()
        guard case .prepared(let current, let expectedGeneration) = scriptedReviewRecoveryRoute,
              current.receipt === prepared.receipt,
              current.handoff == prepared.handoff else {
            throw .backendOwnsRecovery(
                message: "Testing recovery staging lost its exact scripted prepared route."
            )
        }
        guard admissionPhase == .preparingThread(.notSent) else {
            throw .callerRetainsPreparedRecovery(
                message: "Testing recovery staging requires one fresh destination admission."
            )
        }
        if prepared.handoff.candidate.trigger == .sameAccountRestart,
           destinationGeneration == prepared.receipt.sourceGeneration {
            throw .callerRetainsPreparedRecovery(
                message: "Testing same-account recovery requires a replacement generation."
            )
        }
        guard destinationGeneration == expectedGeneration else {
            throw .callerRetainsPreparedRecovery(
                message: "Testing recovery destination generation was not scripted exactly."
            )
        }
        scriptedReviewRecoveryRoute = .staging
        reviewRecoveryCommands.append(.stage(prepared, destinationGeneration, admission))
        await reviewRecoveryStageStartedGate.open()
        await reviewRecoveryStageGate?.waitIgnoringCancellation()
        reviewRecoveryStageGate = nil
        do {
            let attempt = try await reviewBackend.resumeReviewRecovery(
                prepared.handoff,
                request: request,
                admission: admission
            )
            guard attempt.run.attemptID != prepared.receipt.sourceRun.attemptID,
                  await admission.currentPhase() == .active(attempt.run) else {
                throw recoveryRouteFailure("finish stage")
            }
            let staged = StagedReviewRecovery(
                receipt: prepared.receipt,
                destinationGeneration: destinationGeneration,
                attempt: attempt,
                admission: admission
            )
            scriptedReviewRecoveryRoute = .staged(staged)
            return staged
        } catch {
            scriptedReviewRecoveryRoute = nil
            let failure = await recoveryFailure(
                error,
                invalidating: prepared.handoff,
                cleanupRun: await provisionalRecoveryRun(admission) ?? prepared.receipt.sourceRun
            )
            throw .backendOwnsRecovery(message: failure.localizedDescription)
        }
    }

    package func commitReviewRecovery(_ staged: StagedReviewRecovery) async throws {
        guard case .staged(let current) = scriptedReviewRecoveryRoute,
              current === staged,
              await staged.admission.permitsRecoveryPublication(of: staged.attempt.run),
              case .staged(let revalidated) = scriptedReviewRecoveryRoute,
              revalidated === staged else {
            throw recoveryRouteFailure("commit")
        }
        scriptedReviewRecoveryRoute = nil
        reviewRecoveryCommands.append(.commit(staged))
        await reviewRecoveryCommitStartedGate.open()
        await reviewRecoveryCommitGate?.waitIgnoringCancellation()
        reviewRecoveryCommitGate = nil
    }

    package func discardReviewRecovery(_ prepared: PreparedReviewRecovery) async throws {
        guard case .prepared(let current, let destinationGeneration) = scriptedReviewRecoveryRoute,
              current.receipt === prepared.receipt,
              current.handoff == prepared.handoff else {
            throw recoveryRouteFailure("discard prepared")
        }
        scriptedReviewRecoveryRoute = .discardingPrepared(current, destinationGeneration)
        do {
            try await prepared.handoff.discard()
        } catch {
            scriptedReviewRecoveryRoute = .prepared(current, destinationGeneration)
            throw error
        }
        scriptedReviewRecoveryRoute = nil
        reviewRecoveryCommands.append(.discardPrepared(prepared))
        try await reviewBackend.cleanupReview(prepared.receipt.sourceRun)
    }

    package func discardReviewRecovery(_ staged: StagedReviewRecovery) async throws {
        guard case .staged(let current) = scriptedReviewRecoveryRoute,
              current === staged else { throw recoveryRouteFailure("discard staged") }
        scriptedReviewRecoveryRoute = nil
        reviewRecoveryCommands.append(.discardStaged(staged))
        try await reviewBackend.cleanupReview(staged.attempt.run)
    }

    private func provisionalRecoveryRun(
        _ admission: ReviewStartAdmission
    ) async -> CodexReviewBackendModel.Review.Run? {
        switch await admission.currentPhase() {
        case .startingReview(let run, _), .active(let run),
             .interrupting(let run, _, _), .finishing(let run, _, _, _),
             .recovering(let run, _, _), .finishingRecovery(let run, _, _, _): run
        case .terminal(.active(let resolution)): resolution.run
        case .preparingThread, .rollingBackRecovery, .terminal: nil
        }
    }

    private func recoveryFailure(
        _ original: any Error,
        invalidating handoff: ReviewRecoveryHandoff? = nil,
        cleanupRun: CodexReviewBackendModel.Review.Run
    ) async -> any Error {
        var primary = original
        if let handoff {
            do { try await handoff.discard() } catch is ReviewRecoveryHandoffAlreadyConsumed {} catch {
                primary = ReviewAttemptContractFailure(
                    message: "\(primary.localizedDescription) Handoff invalidation also failed: \(error.localizedDescription)"
                )
            }
        }
        do {
            try await reviewBackend.cleanupReview(cleanupRun)
            return primary
        } catch {
            return ReviewAttemptContractFailure(
                message: "\(primary.localizedDescription) Exact recovery cleanup also failed: \(error.localizedDescription)"
            )
        }
    }

    private func recoveryRouteFailure(_ operation: String) -> ReviewAttemptContractFailure {
        .init(message: "Testing recovery cannot \(operation) without its exact scripted route.")
    }

    package func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async throws {
        try await reviewBackend.cleanupReview(run)
    }

    package func refreshSettings() async throws -> CodexReviewSettings.Snapshot {
        currentSettingsSnapshot = try await monitoredSettingsSnapshot()
        return currentSettingsSnapshot
    }

    private func monitoredSettingsSnapshot() async throws -> CodexReviewSettings.Snapshot {
        let snapshot = try await reviewBackend.readSettings()
        return .init(
            model: snapshot.model,
            fallbackModel: snapshot.fallbackModel,
            reasoningEffort: snapshot.reasoningEffort.flatMap(CodexReviewSettings.ReasoningEffort.init(rawValue:)),
            serviceTier: snapshot.serviceTier.flatMap(CodexReviewSettings.ServiceTier.init(rawValue:)),
            models: snapshot.models
        )
    }

    package func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewSettings.ReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewSettings.ServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        var change = CodexReviewBackendModel.Settings.Change(model: model, updatesModel: true)
        if persistReasoningEffort {
            change.reasoningEffort = reasoningEffort?.rawValue
            change.updatesReasoningEffort = true
        }
        if persistServiceTier {
            change.serviceTier = serviceTier?.rawValue
            change.updatesServiceTier = true
        }
        _ = try await reviewBackend.applySettings(change)
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewSettings.ReasoningEffort?
    ) async throws {
        _ = try await reviewBackend.applySettings(.init(reasoningEffort: reasoningEffort?.rawValue, updatesReasoningEffort: true))
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewSettings.ServiceTier?
    ) async throws {
        _ = try await reviewBackend.applySettings(.init(serviceTier: serviceTier?.rawValue, updatesServiceTier: true))
    }
}

package actor FakeJSONRPCTransport: JSONRPC.Transport {
    private struct RequestGate: Sendable {
        var gate: AsyncGate
        var ignoresCancellation: Bool

        func wait() async {
            if ignoresCancellation {
                await gate.waitIgnoringCancellation()
            } else {
                await gate.wait()
            }
        }
    }

    private enum QueuedResponse: Sendable {
        case success(Data)
        case failure(JSONRPC.Error)
        case cancellation
        case transportFailure(String)
    }

    private var responses: [String: [QueuedResponse]]
    private var requests: [JSONRPC.Request] = []
    private var notifications: [JSONRPC.Notification] = []
    private var serverNotificationContinuations: [AsyncThrowingStream<JSONRPC.Notification, Error>.Continuation] = []
    private var activeByMethod: [String: Int] = [:]
    private var maxActiveByMethod: [String: Int] = [:]
    private var gatesByMethod: [String: RequestGate] = [:]
    private var oneShotGatesByMethod: [String: [RequestGate]] = [:]
    private var activeRequestGates: [UUID: AsyncGate] = [:]
    private var beforeReturningResponseByMethod: [String: [@Sendable () async -> Void]] = [:]
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var activeRequestWaiters: [String: [(Int, CheckedContinuation<Void, Never>)]] = [:]
    private var notificationStreamCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var closeCompleted = false

    package init(responses: [String: [Data]] = [:]) {
        self.responses = responses
            .mapValues { $0.map(QueuedResponse.success) }
    }

    package func enqueue<Response: Encodable & Sendable>(
        _ response: Response,
        for method: String
    ) throws {
        let data = try JSONEncoder().encode(response)
        responses[method, default: []].append(.success(data))
    }

    package func enqueueFailure(
        _ error: JSONRPC.Error,
        for method: String
    ) {
        responses[method, default: []].append(.failure(error))
    }

    package func enqueueCancellation(for method: String) {
        responses[method, default: []].append(.cancellation)
    }

    package func enqueueRawResponse(_ response: Data, for method: String) {
        responses[method, default: []].append(.success(response))
    }

    package func enqueueTransportFailure(message: String, for method: String) {
        responses[method, default: []].append(.transportFailure(message))
    }

    package func hold(method: String, gate: AsyncGate) {
        gatesByMethod[method] = .init(gate: gate, ignoresCancellation: false)
    }

    package func holdNext(method: String, gate: AsyncGate) {
        oneShotGatesByMethod[method, default: []].append(.init(gate: gate, ignoresCancellation: false))
    }

    package func holdNextIgnoringCancellation(method: String, gate: AsyncGate) {
        oneShotGatesByMethod[method, default: []].append(.init(gate: gate, ignoresCancellation: true))
    }

    package func beforeReturningNextResponse(
        method: String,
        _ operation: @escaping @Sendable () async -> Void
    ) {
        beforeReturningResponseByMethod[method, default: []].append(operation)
    }

    package func send(_ request: JSONRPC.Request) async throws -> Data {
        guard closed == false else {
            throw JSONRPC.Error.closed
        }
        requests.append(request)
        resumeRequestCountWaiters()
        activeByMethod[request.method, default: 0] += 1
        resumeActiveRequestWaiters(for: request.method)
        defer { activeByMethod[request.method, default: 1] -= 1 }
        maxActiveByMethod[request.method] = max(
            maxActiveByMethod[request.method] ?? 0,
            activeByMethod[request.method] ?? 0
        )
        let queuedResponse = dequeueResponse(for: request.method)
        if let gate = dequeueOneShotGate(for: request.method) ?? gatesByMethod[request.method] {
            let gateID = UUID()
            activeRequestGates[gateID] = gate.gate
            await gate.wait()
            activeRequestGates.removeValue(forKey: gateID)
            guard closed == false else { throw JSONRPC.Error.closed }
        }
        if let operation = dequeueBeforeReturningResponse(for: request.method) {
            await operation()
        }
        guard closed == false else { throw JSONRPC.Error.closed }
        if let queuedResponse {
            switch queuedResponse {
            case .success(let data):
                return data
            case .failure(let error):
                throw error
            case .cancellation:
                throw CancellationError()
            case .transportFailure(let message):
                throw FakeCodexReviewBackendError(message: message)
            }
        }
        return try JSONEncoder().encode(EmptyResponse())
    }

    private func dequeueResponse(for method: String) -> QueuedResponse? {
        guard var queued = responses[method], queued.isEmpty == false else {
            return nil
        }
        let response = queued.removeFirst()
        responses[method] = queued
        return response
    }

    private func dequeueOneShotGate(for method: String) -> RequestGate? {
        guard var gates = oneShotGatesByMethod[method], gates.isEmpty == false else {
            return nil
        }
        let gate = gates.removeFirst()
        oneShotGatesByMethod[method] = gates
        return gate
    }

    private func dequeueBeforeReturningResponse(
        for method: String
    ) -> (@Sendable () async -> Void)? {
        guard var operations = beforeReturningResponseByMethod[method],
              operations.isEmpty == false
        else {
            return nil
        }
        let operation = operations.removeFirst()
        beforeReturningResponseByMethod[method] = operations
        return operation
    }

    package func notify(_ notification: JSONRPC.Notification) async throws {
        notifications.append(notification)
    }

    package func notificationStream() -> AsyncThrowingStream<JSONRPC.Notification, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            serverNotificationContinuations.append(continuation)
            resumeNotificationStreamCountWaiters()
        }
    }

    package func close() async {
        closed = true
        let requestGates = Array(activeRequestGates.values)
        activeRequestGates.removeAll(keepingCapacity: false)
        for gate in requestGates {
            await gate.open()
        }
        for continuation in serverNotificationContinuations {
            continuation.finish()
        }
        serverNotificationContinuations.removeAll()
        closeCompleted = true
        for waiter in closeWaiters {
            waiter.resume()
        }
        closeWaiters.removeAll(keepingCapacity: false)
    }

    package func finishNotificationStreams(throwing error: any Error) {
        for continuation in serverNotificationContinuations {
            continuation.finish(throwing: error)
        }
        serverNotificationContinuations.removeAll()
    }

    package func recordedRequests() -> [JSONRPC.Request] {
        requests
    }

    package func waitForRequestCount(_ count: Int) async {
        if requests.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if requests.count >= count {
                continuation.resume()
            } else {
                requestCountWaiters.append((count, continuation))
            }
        }
    }

    package func waitForActiveRequests(
        method: String,
        count: Int = 1
    ) async {
        if activeByMethod[method, default: 0] >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if activeByMethod[method, default: 0] >= count {
                continuation.resume()
            } else {
                activeRequestWaiters[method, default: []].append((count, continuation))
            }
        }
    }

    package func recordedNotifications() -> [JSONRPC.Notification] {
        notifications
    }

    package func waitForNotificationStreamCount(_ count: Int) async {
        if serverNotificationContinuations.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if serverNotificationContinuations.count >= count {
                continuation.resume()
            } else {
                notificationStreamCountWaiters.append((count, continuation))
            }
        }
    }

    package func notificationStreamCount() -> Int {
        serverNotificationContinuations.count
    }

    package func isClosedForTesting() -> Bool {
        closed
    }

    package func waitUntilClosedForTesting() async {
        guard closeCompleted == false else {
            return
        }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    private func resumeActiveRequestWaiters(for method: String) {
        guard let waiters = activeRequestWaiters[method] else {
            return
        }
        let activeCount = activeByMethod[method, default: 0]
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in waiters {
            if activeCount >= count {
                continuation.resume()
            } else {
                pending.append((count, continuation))
            }
        }
        if pending.isEmpty {
            activeRequestWaiters.removeValue(forKey: method)
        } else {
            activeRequestWaiters[method] = pending
        }
    }

    package func maxActiveCount(for method: String) -> Int {
        maxActiveByMethod[method] ?? 0
    }

    package func emitServerNotification<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) throws {
        let notification = JSONRPC.Notification(
            method: method,
            params: try JSONEncoder().encode(params)
        )
        for continuation in serverNotificationContinuations {
            continuation.yield(notification)
        }
    }

    private func resumeRequestCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if requests.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestCountWaiters = remaining
    }

    private func resumeNotificationStreamCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in notificationStreamCountWaiters {
            if serverNotificationContinuations.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        notificationStreamCountWaiters = remaining
    }
}
