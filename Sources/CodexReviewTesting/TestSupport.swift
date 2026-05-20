import Foundation
import CodexReview
import CodexReviewAppServer

package actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    package func open() {
        guard isOpen == false else {
            return
        }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
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

package struct FakeCodexReviewBackendError: LocalizedError, Sendable {
    package var message: String

    package init(message: String) {
        self.message = message
    }

    package var errorDescription: String? {
        message
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
        case cleanupReview(BackendReviewRun)
        case events(BackendReviewRun)
    }

    private var settings: BackendSettingsSnapshot
    private var auth: BackendAuthSnapshot
    private var commands: [Command] = []
    private var nextRun: BackendReviewRun
    private var interruptFailureMessage: String?
    private var interruptReviewGate: AsyncGate?
    private var interruptReviewWaiters: [CheckedContinuation<Void, Never>] = []
    private var startReviewGate: AsyncGate?
    private var startReviewWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventContinuations: [String: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation] = [:]
    private var eventRegistrationWaiters: [CheckedContinuation<Void, Never>] = []

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

    package func holdInterruptReview(with gate: AsyncGate) {
        interruptReviewGate = gate
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
                startReviewWaiters.append(continuation)
            }
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
                interruptReviewWaiters.append(continuation)
            }
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
        let waiters = startReviewWaiters
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
        let waiters = interruptReviewWaiters
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

    package func cleanupReview(_ run: BackendReviewRun) async {
        commands.append(.cleanupReview(run))
    }

    package nonisolated func events(for run: BackendReviewRun) async -> AsyncThrowingStream<BackendReviewEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            Task {
                await self.register(continuation: continuation, run: run)
            }
        }
    }

    package func yield(_ event: BackendReviewEvent, for run: BackendReviewRun? = nil) {
        let key = run?.threadID ?? nextRun.threadID
        eventContinuations[key]?.yield(event)
    }

    package func finishEvents(for run: BackendReviewRun? = nil) {
        let key = run?.threadID ?? nextRun.threadID
        eventContinuations.removeValue(forKey: key)?.finish()
    }

    package func finishEvents(throwing error: any Error, for run: BackendReviewRun? = nil) {
        let key = run?.threadID ?? nextRun.threadID
        eventContinuations.removeValue(forKey: key)?.finish(throwing: error)
    }

    package func waitForEventStream() async {
        if eventContinuations.isEmpty == false {
            return
        }
        await withCheckedContinuation { continuation in
            if eventContinuations.isEmpty == false {
                continuation.resume()
            } else {
                eventRegistrationWaiters.append(continuation)
            }
        }
    }

    private func register(
        continuation: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation,
        run: BackendReviewRun
    ) {
        commands.append(.events(run))
        eventContinuations[run.threadID] = continuation
        let waiters = eventRegistrationWaiters
        eventRegistrationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
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
        if let gate = gatesByMethod[request.method] {
            await gate.wait()
        }
        activeByMethod[request.method, default: 1] -= 1
        if var queued = responses[request.method], queued.isEmpty == false {
            let response = queued.removeFirst()
            responses[request.method] = queued
            switch response {
            case .success(let data):
                return data
            case .failure(let error):
                throw error
            }
        }
        return try JSONEncoder().encode(EmptyResponse())
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
