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
        case applySettings(BackendSettingsChange)
        case readAuth
        case startLogin(BackendLoginRequest)
        case cancelLogin(BackendLoginChallenge)
        case completeLogin(BackendLoginResponse)
        case logout(BackendAccountID)
        case startReview(BackendReviewStart)
        case interruptReview(BackendReviewRun, BackendCancellationReason)
        case beginReviewRecovery(BackendReviewRun, BackendCancellationReason)
        case resumeReviewRecovery(BackendReviewRecoveryToken, BackendReviewStart)
        case cleanupReview(BackendReviewRun)
        case events(BackendReviewRun)
    }

    private var settings: BackendSettingsSnapshot
    private var auth: BackendAuthSnapshot
    private var commands: [Command] = []
    private var nextRun: BackendReviewRun
    private var nextRecoveredRun: BackendReviewRun?
    private var interruptFailureMessage: String?
    private var recoveryFailureMessage: String?
    private var interruptReviewGate: AsyncGate?
    private var interruptReviewWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var beginReviewRecoveryWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var startReviewGate: AsyncGate?
    private var startReviewWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var resumeReviewRecoveryGate: AsyncGate?
    private var resumeReviewRecoveryWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var eventsGate: AsyncGate?
    private let eventStreamRequestGate = AsyncGate()
    private let eventStreamReturnGate = AsyncGate()
    private var eventContinuations: [EventContinuationKey: EventContinuation] = [:]
    private var eventRegistrationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var terminatedEventContinuationIDs: Set<UUID> = []

    private struct EventContinuationKey: Hashable, Sendable {
        var attemptID: String
        var threadID: String
        var turnID: String?
        var reviewThreadID: String?
        var model: String?

        init(run: BackendReviewRun) {
            self.attemptID = run.attemptID
            self.threadID = run.threadID
            self.turnID = run.turnID
            self.reviewThreadID = run.reviewThreadID
            self.model = run.model
        }
    }

    private struct EventContinuation: Sendable {
        var id: UUID
        var continuation: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation
    }

    package init(
        settings: BackendSettingsSnapshot = .init(),
        auth: BackendAuthSnapshot = .init(),
        nextRun: BackendReviewRun = .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1")
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

    package func holdEvents(with gate: AsyncGate) {
        eventsGate = gate
    }

    package func setNextRecoveredRun(_ run: BackendReviewRun) {
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

    package func waitForEventsRequest() async {
        await eventStreamRequestGate.wait()
    }

    package func waitForEventsRequest(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "events request", timeout: timeout) {
            await self.waitForEventsRequest()
        }
    }

    package func waitForEventsReturn() async {
        await eventStreamReturnGate.wait()
    }

    package func waitForEventsReturn(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "events return", timeout: timeout) {
            await self.waitForEventsReturn()
        }
    }

    package func readSettings() async throws -> BackendSettingsSnapshot {
        commands.append(.readSettings)
        return settings
    }

    package func applySettings(_ change: BackendSettingsChange) async throws -> BackendSettingsSnapshot {
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

    package func readAuth() async throws -> BackendAuthSnapshot {
        commands.append(.readAuth)
        return auth
    }

    package func startLogin(_ request: BackendLoginRequest) async throws -> BackendLoginChallenge {
        commands.append(.startLogin(request))
        return .init(id: "challenge-1")
    }

    package func cancelLogin(_ challenge: BackendLoginChallenge) async throws {
        commands.append(.cancelLogin(challenge))
    }

    package func completeLogin(_ response: BackendLoginResponse) async throws -> BackendAuthSnapshot {
        commands.append(.completeLogin(response))
        let account = BackendAccountSnapshot(id: .init("account-1"), label: "Codex", isActive: true)
        auth = .init(accounts: [account], activeAccountID: account.id)
        return auth
    }

    package func logout(_ account: BackendAccountID) async throws -> BackendAuthSnapshot {
        commands.append(.logout(account))
        auth = .init()
        return auth
    }

    package func startReview(_ request: BackendReviewStart) async throws -> BackendReviewRun {
        commands.append(.startReview(request))
        let waiters = Array(startReviewWaiters.values)
        startReviewWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let startReviewGate {
            await startReviewGate.wait()
        }
        return nextRun
    }

    package func interruptReview(_ run: BackendReviewRun, reason: BackendCancellationReason) async throws {
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
        _ run: BackendReviewRun,
        reason: BackendCancellationReason
    ) async throws -> BackendReviewRecoveryToken {
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
        _ token: BackendReviewRecoveryToken,
        request: BackendReviewStart
    ) async throws -> BackendReviewRun {
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
        return nextRecoveredRun ?? .init(
            attemptID: "attempt-recovered",
            threadID: run.threadID,
            turnID: "turn-recovered",
            reviewThreadID: run.reviewThreadID,
            model: run.model ?? request.model
        )
    }

    package func cleanupReview(_ run: BackendReviewRun) async {
        commands.append(.cleanupReview(run))
    }

    package func events(for run: BackendReviewRun) async -> AsyncThrowingStream<BackendReviewEvent, Error> {
        let gate = await noteEventsRequest()
        if let gate {
            await gate.wait()
        }
        await noteEventsReturn()
        let continuationID = UUID()
        let (stream, continuation) = AsyncThrowingStream<BackendReviewEvent, Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation.onTermination = { @Sendable _ in
            Task {
                await self.unregisterEventContinuation(id: continuationID, run: run)
            }
        }
        register(continuation: continuation, id: continuationID, run: run)
        return stream
    }

    package func hasEventContinuation(for run: BackendReviewRun) -> Bool {
        eventContinuation(for: run) != nil
    }

    package func yield(_ event: BackendReviewEvent, for run: BackendReviewRun? = nil) async {
        eventContinuation(for: run ?? nextRun)?.continuation.yield(event)
        await Task.yield()
    }

    package func finishEvents(for run: BackendReviewRun? = nil) {
        guard let key = eventContinuationKey(for: run ?? nextRun) else {
            return
        }
        eventContinuations.removeValue(forKey: key)?.continuation.finish()
    }

    package func finishEvents(throwing error: any Error, for run: BackendReviewRun? = nil) {
        guard let key = eventContinuationKey(for: run ?? nextRun) else {
            return
        }
        eventContinuations.removeValue(forKey: key)?.continuation.finish(throwing: error)
    }

    package func finishAllEvents() {
        let continuations = eventContinuations.values.map(\.continuation)
        eventContinuations.removeAll(keepingCapacity: false)
        terminatedEventContinuationIDs.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.finish()
        }
        let waiters = Array(eventRegistrationWaiters.values)
        eventRegistrationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    package func waitForEventStream() async {
        if eventContinuations.isEmpty == false {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if eventContinuations.isEmpty == false {
                    continuation.resume()
                } else {
                    eventRegistrationWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelEventRegistrationWaiter(id: waiterID)
            }
        }
    }

    package func waitForEventStream(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "event stream registration", timeout: timeout) {
            await self.waitForEventStream()
        }
    }

    private func register(
        continuation: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation,
        id: UUID,
        run: BackendReviewRun
    ) {
        guard terminatedEventContinuationIDs.remove(id) == nil else {
            continuation.finish()
            return
        }
        commands.append(.events(run))
        eventContinuations[.init(run: run)] = .init(id: id, continuation: continuation)
        let waiters = Array(eventRegistrationWaiters.values)
        eventRegistrationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func eventContinuation(for run: BackendReviewRun) -> EventContinuation? {
        guard let key = eventContinuationKey(for: run) else {
            return nil
        }
        return eventContinuations[key]
    }

    private func eventContinuationKey(for run: BackendReviewRun) -> EventContinuationKey? {
        let exactKey = EventContinuationKey(run: run)
        if eventContinuations[exactKey] != nil {
            return exactKey
        }
        return nil
    }

    private func unregisterEventContinuation(id: UUID, run: BackendReviewRun) {
        let key = EventContinuationKey(run: run)
        guard let registered = eventContinuations[key] else {
            terminatedEventContinuationIDs.insert(id)
            return
        }
        guard registered.id == id else {
            return
        }
        eventContinuations.removeValue(forKey: key)
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

    private func cancelEventRegistrationWaiter(id: UUID) {
        eventRegistrationWaiters.removeValue(forKey: id)?.resume()
    }

    private func noteEventsRequest() async -> AsyncGate? {
        await eventStreamRequestGate.open()
        return eventsGate
    }

    private func noteEventsReturn() async {
        await eventStreamReturnGate.open()
    }
}

@MainActor
package final class TestingCodexReviewStoreBackend: CodexReviewStoreBackend {
    package let reviewBackend: FakeCodexReviewBackend
    package let seed: CodexReviewStoreSeed
    package var currentSettingsSnapshot: CodexReviewSettingsSnapshot
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

    package var initialSettingsSnapshot: CodexReviewSettingsSnapshot {
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

    package func startReview(_ request: BackendReviewStart) async throws -> BackendReviewRun {
        try await reviewBackend.startReview(request)
    }

    package func interruptReview(
        _ run: BackendReviewRun,
        reason: BackendCancellationReason
    ) async throws {
        try await reviewBackend.interruptReview(run, reason: reason)
    }

    package func beginReviewRecovery(
        _ run: BackendReviewRun,
        reason: BackendCancellationReason
    ) async throws -> BackendReviewRecoveryToken {
        try await reviewBackend.beginReviewRecovery(run, reason: reason)
    }

    package func resumeReviewRecovery(
        _ token: BackendReviewRecoveryToken,
        request: BackendReviewStart
    ) async throws -> BackendReviewRun {
        try await reviewBackend.resumeReviewRecovery(token, request: request)
    }

    package func cleanupReview(_ run: BackendReviewRun) async {
        await reviewBackend.cleanupReview(run)
    }

    package func events(for run: BackendReviewRun) async -> AsyncThrowingStream<BackendReviewEvent, Error> {
        await reviewBackend.events(for: run)
    }

    package func refreshSettings() async throws -> CodexReviewSettingsSnapshot {
        let snapshot = try await reviewBackend.readSettings()
        currentSettingsSnapshot = .init(
            model: snapshot.model,
            fallbackModel: snapshot.fallbackModel,
            reasoningEffort: snapshot.reasoningEffort.flatMap(CodexReviewReasoningEffort.init(rawValue:)),
            serviceTier: snapshot.serviceTier.flatMap(CodexReviewServiceTier.init(rawValue:)),
            models: snapshot.models
        )
        return currentSettingsSnapshot
    }

    package func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
        persistServiceTier: Bool
    ) async throws {
        var change = BackendSettingsChange(model: model)
        if persistReasoningEffort {
            change.reasoningEffort = reasoningEffort?.rawValue
        }
        if persistServiceTier {
            change.serviceTier = serviceTier?.rawValue
        }
        _ = try await reviewBackend.applySettings(change)
    }

    package func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async throws {
        _ = try await reviewBackend.applySettings(.init(reasoningEffort: reasoningEffort?.rawValue))
    }

    package func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async throws {
        _ = try await reviewBackend.applySettings(.init(serviceTier: serviceTier?.rawValue))
    }
}

package actor FakeJSONRPCTransport: JSONRPCTransport {
    private enum QueuedResponse: Sendable {
        case success(Data)
        case failure(JSONRPCError)
    }

    private var responses: [String: [QueuedResponse]]
    private var requests: [JSONRPCRequest] = []
    private var notifications: [JSONRPCNotification] = []
    private var serverNotificationContinuations: [AsyncThrowingStream<JSONRPCNotification, Error>.Continuation] = []
    private var activeByMethod: [String: Int] = [:]
    private var maxActiveByMethod: [String: Int] = [:]
    private var gatesByMethod: [String: AsyncGate] = [:]
    private var oneShotGatesByMethod: [String: [AsyncGate]] = [:]
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
        _ error: JSONRPCError,
        for method: String
    ) {
        responses[method, default: []].append(.failure(error))
    }

    package func hold(method: String, gate: AsyncGate) {
        gatesByMethod[method] = gate
    }

    package func holdNext(method: String, gate: AsyncGate) {
        oneShotGatesByMethod[method, default: []].append(gate)
    }

    package func send(_ request: JSONRPCRequest) async throws -> Data {
        guard closed == false else {
            throw JSONRPCError.closed
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

    private func dequeueOneShotGate(for method: String) -> AsyncGate? {
        guard var gates = oneShotGatesByMethod[method], gates.isEmpty == false else {
            return nil
        }
        let gate = gates.removeFirst()
        oneShotGatesByMethod[method] = gates
        return gate
    }

    package func notify(_ notification: JSONRPCNotification) async throws {
        notifications.append(notification)
    }

    package func notificationStream() -> AsyncThrowingStream<JSONRPCNotification, Error> {
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

    package func recordedRequests() -> [JSONRPCRequest] {
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

    package func recordedNotifications() -> [JSONRPCNotification] {
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
        let notification = JSONRPCNotification(
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
