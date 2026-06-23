import Foundation
import CodexAppServerKit
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
        case beginReviewRecovery(CodexReviewBackendModel.Review.Run, CodexReviewBackendModel.CancellationReason)
        case resumeReviewRecovery(CodexReviewBackendModel.Review.RecoveryToken, CodexReviewBackendModel.Review.Start)
        case cleanupReview(CodexReviewBackendModel.Review.Run)
    }

    private var settings: CodexReviewBackendModel.Settings.Snapshot
    private var auth: CodexReviewBackendModel.Auth.Snapshot
    private var commands: [Command] = []
    private var nextRun: CodexReviewBackendModel.Review.Run
    private var nextRecoveredRun: CodexReviewBackendModel.Review.Run?
    private var interruptFailureMessage: String?
    private var recoveryFailureMessage: String?
    private var interruptReviewGate: AsyncGate?
    private var interruptReviewWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var beginReviewRecoveryWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var startReviewGate: AsyncGate?
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
    }

    package func failInterrupts(message: String) {
        interruptFailureMessage = message
    }

    package func failRecovery(message: String) {
        recoveryFailureMessage = message
    }

    package func holdInterruptReview(with gate: AsyncGate) {
        interruptReviewGate = gate
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

    package func waitForBeginReviewRecovery() async {
        if commands.contains(where: {
            if case .beginReviewRecovery = $0 {
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
                    if case .beginReviewRecovery = $0 {
                        true
                    } else {
                        false
                    }
                }) {
                    continuation.resume()
                } else {
                    beginReviewRecoveryWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelBeginReviewRecoveryWaiter(id: waiterID)
            }
        }
    }

    package func waitForBeginReviewRecovery(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "beginReviewRecovery", timeout: timeout) {
            await self.waitForBeginReviewRecovery()
        }
    }

    package func waitForResumeReviewRecovery() async {
        if commands.contains(where: {
            if case .resumeReviewRecovery = $0 {
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
                    if case .resumeReviewRecovery = $0 {
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

    package func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt {
        commands.append(.startReview(request))
        let waiters = Array(startReviewWaiters.values)
        startReviewWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let startReviewGate {
            await startReviewGate.wait()
        }
        return .init(run: nextRun, events: eventMailbox(for: nextRun))
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

    package func beginReviewRecovery(
        _ run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws -> CodexReviewBackendModel.Review.RecoveryToken {
        commands.append(.beginReviewRecovery(run, reason))
        let waiters = Array(beginReviewRecoveryWaiters.values)
        beginReviewRecoveryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let interruptReviewGate {
            await interruptReviewGate.wait()
        }
        if let interruptFailureMessage {
            throw FakeCodexReviewBackendError(message: interruptFailureMessage)
        }
        return .init(interruptedRun: run, rollbackThreadID: run.reviewThreadID ?? run.threadID)
    }

    package func resumeReviewRecovery(
        _ token: CodexReviewBackendModel.Review.RecoveryToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        commands.append(.resumeReviewRecovery(token, request))
        let waiters = Array(resumeReviewRecoveryWaiters.values)
        resumeReviewRecoveryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let resumeReviewRecoveryGate {
            await resumeReviewRecoveryGate.wait()
        }
        if let recoveryFailureMessage {
            throw FakeCodexReviewBackendError(message: recoveryFailureMessage)
        }
        let run = token.interruptedRun
        let recoveredRun = nextRecoveredRun ?? .init(
            attemptID: "attempt-recovered",
            threadID: run.threadID,
            turnID: "turn-recovered",
            reviewThreadID: run.reviewThreadID,
            model: run.model ?? request.model
        )
        return .init(run: recoveredRun, events: eventMailbox(for: recoveredRun))
    }

    package func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        commands.append(.cleanupReview(run))
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

    private func cancelBeginReviewRecoveryWaiter(id: UUID) {
        beginReviewRecoveryWaiters.removeValue(forKey: id)?.resume()
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
                    activeRun: store.activeRuns[job.id],
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
package final class TestingCodexReviewStoreBackend: CodexReviewStoreBackend {
    package let reviewBackend: FakeCodexReviewBackend
    package let seed: CodexReviewStoreSeed
    package var currentSettingsSnapshot: CodexReviewSettings.Snapshot
    package private(set) var isActive = false
    package private(set) var startRequests: [Bool] = []

    package init(
        reviewBackend: FakeCodexReviewBackend,
        seed: CodexReviewStoreSeed = .init()
    ) {
        self.reviewBackend = reviewBackend
        self.seed = seed
        self.currentSettingsSnapshot = seed.initialSettingsSnapshot
    }

    package var initialSettingsSnapshot: CodexReviewSettings.Snapshot {
        currentSettingsSnapshot
    }

    package func attachStore(_: CodexReviewStore) {}

    package func start(store: CodexReviewStore, forceRestartIfNeeded: Bool) async {
        startRequests.append(forceRestartIfNeeded)
        isActive = true
        store.transitionToRunning(serverURL: nil)
    }

    package func stop(store _: CodexReviewStore) async {
        isActive = false
    }

    package func waitUntilStopped() async {}

    package func refreshAuth(auth: CodexReviewAuthModel) async {
        do {
            let snapshot = try await reviewBackend.readAuth()
            let accounts = snapshot.accounts.compactMap { account -> CodexReview.CodexAccount? in
                let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.isEmpty == false else {
                    return nil
                }
                return CodexReview.CodexAccount(email: label)
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

    package func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt {
        try await reviewBackend.startReview(request)
    }

    package func interruptReview(
        _ run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        try await reviewBackend.interruptReview(run, reason: reason)
    }

    package func beginReviewRecovery(
        _ run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws -> CodexReviewBackendModel.Review.RecoveryToken {
        try await reviewBackend.beginReviewRecovery(run, reason: reason)
    }

    package func resumeReviewRecovery(
        _ token: CodexReviewBackendModel.Review.RecoveryToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        try await reviewBackend.resumeReviewRecovery(token, request: request)
    }

    package func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        await reviewBackend.cleanupReview(run)
    }

    package func refreshSettings() async throws -> CodexReviewSettings.Snapshot {
        let snapshot = try await reviewBackend.readSettings()
        currentSettingsSnapshot = .init(
            model: snapshot.model,
            fallbackModel: snapshot.fallbackModel,
            reasoningEffort: snapshot.reasoningEffort.flatMap(CodexReviewSettings.ReasoningEffort.init(rawValue:)),
            serviceTier: snapshot.serviceTier.flatMap(CodexReviewSettings.ServiceTier.init(rawValue:)),
            models: snapshot.models
        )
        return currentSettingsSnapshot
    }

    package func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewSettings.ReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewSettings.ServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        var change = CodexReviewBackendModel.Settings.Change(model: model)
        if persistReasoningEffort {
            change.reasoningEffort = reasoningEffort?.rawValue
        }
        if persistServiceTier {
            change.serviceTier = serviceTier?.rawValue
        }
        _ = try await reviewBackend.applySettings(change)
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewSettings.ReasoningEffort?
    ) async throws {
        _ = try await reviewBackend.applySettings(.init(reasoningEffort: reasoningEffort?.rawValue))
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewSettings.ServiceTier?
    ) async throws {
        _ = try await reviewBackend.applySettings(.init(serviceTier: serviceTier?.rawValue))
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
    }

    private var responses: [String: [QueuedResponse]]
    private var requests: [JSONRPC.Request] = []
    private var notifications: [JSONRPC.Notification] = []
    private var serverNotificationContinuations: [AsyncThrowingStream<JSONRPC.Notification, Error>.Continuation] = []
    private var activeByMethod: [String: Int] = [:]
    private var maxActiveByMethod: [String: Int] = [:]
    private var gatesByMethod: [String: RequestGate] = [:]
    private var oneShotGatesByMethod: [String: [RequestGate]] = [:]
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var notificationStreamCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var closed = false

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

    package func hold(method: String, gate: AsyncGate) {
        gatesByMethod[method] = .init(gate: gate, ignoresCancellation: false)
    }

    package func holdNext(method: String, gate: AsyncGate) {
        oneShotGatesByMethod[method, default: []].append(.init(gate: gate, ignoresCancellation: false))
    }

    package func holdNextIgnoringCancellation(method: String, gate: AsyncGate) {
        oneShotGatesByMethod[method, default: []].append(.init(gate: gate, ignoresCancellation: true))
    }

    package func send(_ request: JSONRPC.Request) async throws -> Data {
        guard closed == false else {
            throw JSONRPC.Error.closed
        }
        requests.append(request)
        resumeRequestCountWaiters()
        activeByMethod[request.method, default: 0] += 1
        maxActiveByMethod[request.method] = max(
            maxActiveByMethod[request.method] ?? 0,
            activeByMethod[request.method] ?? 0
        )
        let queuedResponse = dequeueResponse(for: request.method)
        if let gate = dequeueOneShotGate(for: request.method) ?? gatesByMethod[request.method] {
            await gate.wait()
        }
        activeByMethod[request.method, default: 1] -= 1
        if let queuedResponse {
            switch queuedResponse {
            case .success(let data):
                return data
            case .failure(let error):
                throw error
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
        for continuation in serverNotificationContinuations {
            continuation.finish()
        }
        serverNotificationContinuations.removeAll()
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
