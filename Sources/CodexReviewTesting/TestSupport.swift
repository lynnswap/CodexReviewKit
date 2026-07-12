import Foundation
import CodexAppServerKit
import CodexAppServerKitTesting
import CodexReviewKit
import Synchronization

package typealias AsyncGate = CodexAppServerTestGate
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

package final class ManualCodexReviewNetworkMonitor: CodexReviewNetworkMonitoring, Sendable {
    private struct State {
        var current: CodexReviewNetworkSnapshot?
        var continuations: [UUID: AsyncStream<CodexReviewNetworkSnapshot>.Continuation] = [:]
        var isFinished = false
    }

    private let state: Mutex<State>

    package init(initialSnapshot: CodexReviewNetworkSnapshot = .satisfied()) {
        self.state = Mutex(State(current: initialSnapshot))
    }

    package func snapshots() -> AsyncStream<CodexReviewNetworkSnapshot> {
        let continuationID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let initial = state.withLock { state in
                if state.isFinished == false {
                    state.continuations[continuationID] = continuation
                }
                return (snapshot: state.current, isFinished: state.isFinished)
            }
            if let snapshot = initial.snapshot {
                continuation.yield(snapshot)
            }
            if initial.isFinished {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: continuationID)
            }
        }
    }

    package func yield(_ snapshot: CodexReviewNetworkSnapshot) {
        let continuations = state.withLock { state in
            guard state.isFinished == false else {
                return [AsyncStream<CodexReviewNetworkSnapshot>.Continuation]()
            }
            state.current = snapshot
            return Array(state.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(snapshot)
        }
    }

    package func finish() {
        let continuations = state.withLock { state in
            guard state.isFinished == false else {
                return [AsyncStream<CodexReviewNetworkSnapshot>.Continuation]()
            }
            state.isFinished = true
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeContinuation(id: UUID) {
        _ = state.withLock { state in
            state.continuations.removeValue(forKey: id)
        }
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

package func makeReviewAttemptForTesting(
    attemptID: String,
    sourceThreadID: String,
    activeTurnThreadID: String,
    turnID: String,
    model: String? = nil
) -> ReviewAttempt {
    do {
        return try ReviewAttempt(
            validatingAttemptID: attemptID,
            sourceThreadID: sourceThreadID,
            activeTurnThreadID: activeTurnThreadID,
            turnID: turnID,
            model: model
        )
    } catch {
        preconditionFailure("Invalid explicit review attempt fixture: \(error)")
    }
}

package enum FakeReviewTerminal: Equatable, Sendable {
    case completed(finalReview: String)
    case interrupted(message: String?)
    case failed(ReviewBackendFailure)
    case cancelled(String)
}

private actor FakeReviewTerminalSource {
    private enum Delivery: Sendable {
        case observed(ReviewBackendObservedTerminal)
        case cancelled
    }

    private let attempt: ReviewAttempt
    private var delivery: Delivery?
    private var waiters: [UUID: CheckedContinuation<Delivery, Never>] = [:]

    init(attempt: ReviewAttempt) {
        self.attempt = attempt
    }

    func observe() async throws -> ReviewBackendObservedTerminal {
        let waiterID = UUID()
        let received: Delivery = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Delivery, Never>) in
                if let delivery = self.delivery {
                    continuation.resume(returning: delivery)
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
        switch received {
        case .observed(let terminal):
            return terminal
        case .cancelled:
            throw CancellationError()
        }
    }

    func observedIfKnown() -> ReviewBackendObservedTerminal? {
        guard case .observed(let terminal) = delivery else {
            return nil
        }
        return terminal
    }

    func yield(_ terminal: FakeReviewTerminal) {
        let observed: ReviewBackendObservedTerminal
        switch terminal {
        case .completed(let finalReview):
            do {
                observed = .completed(.init(
                    turnID: attempt.turnID,
                    expectedOutput: try NonEmptyReviewOutput(validating: finalReview)
                ))
            } catch {
                observed = .failed(.missingReviewOutput(turnID: attempt.turnID))
            }
        case .interrupted(let message):
            observed = .interrupted(message: message)
        case .cancelled(let message):
            observed = .interrupted(message: message)
        case .failed(let failure):
            observed = .failed(failure)
        }
        resolve(.observed(observed))
    }

    func finish(throwing error: (any Error)? = nil) {
        if error is CancellationError {
            resolve(.cancelled)
        } else {
            resolve(.observed(.failed(.protocolViolation(
                message: error.map {
                    "Review terminal source failed without a typed terminal: \($0.localizedDescription)"
                } ?? "Review terminal source finished without a typed terminal."
            ))))
        }
    }

    private func resolve(_ delivery: Delivery) {
        guard self.delivery == nil else {
            return
        }
        self.delivery = delivery
        let waiters = Array(waiters.values)
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: delivery)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .cancelled)
    }
}

package actor FakeCodexReviewBackend: CodexReviewBackend {
    package enum Command: Equatable, Sendable {
        case readSettings
        case applySettings(CodexReviewBackendModel.Settings.Change)
        case readAuth
        case logout(CodexReviewBackendModel.Account.ID)
        case startReview(CodexReviewBackendModel.Review.Start)
        case interruptReview(ReviewAttempt, CodexReviewBackendModel.CancellationReason)
        case prepareReviewRestart(ReviewAttempt)
        case restartPreparedReview(CodexReviewBackendModel.Review.RestartToken, CodexReviewBackendModel.Review.Start)
        case discardPreparedReviewRestart(CodexReviewBackendModel.Review.RestartToken)
        case cleanupReview(ReviewAttempt)
        case cleanupRetainedReviews([ReviewAttempt])
    }

    private var settings: CodexReviewBackendModel.Settings.Snapshot
    private var auth: CodexReviewBackendModel.Auth.Snapshot
    private var commands: [Command] = []
    private var plannedAttempts: [ReviewAttempt]
    private var plannedRecoveredAttempts: [ReviewAttempt] = []
    private var discardedRestartAttempts: [ReviewAttempt] = []
    private var preparedRestartTokens: [String: CodexReviewBackendModel.Review.RestartToken] = [:]
    private var interruptFailureMessage: String?
    private var recoveryFailureMessage: String?
    private var retainedCleanupFailureMessage: String?
    private var retainedCleanupGate: AsyncGate?
    private var retainedCleanupWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var interruptReviewGate: AsyncGate?
    private struct InterruptReviewWaiter {
        var requiredCount: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private var interruptReviewWaiters: [UUID: InterruptReviewWaiter] = [:]
    private var prepareReviewRestartWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var startReviewGate: AsyncGate?
    private var startReviewIgnoresCancellation = false
    private var startReviewWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var restartPreparedReviewGate: AsyncGate?
    private var restartPreparedReviewIgnoresCancellation = false
    private var restartPreparedReviewWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cleanupReviewWaiters: [ReviewAttemptID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var terminalSources: [TerminalSourceKey: FakeReviewTerminalSource] = [:]

    private struct TerminalSourceKey: Hashable, Sendable {
        var attempt: ReviewAttempt

        init(attempt: ReviewAttempt) {
            self.attempt = attempt
        }
    }

    package init(
        settings: CodexReviewBackendModel.Settings.Snapshot = .init(),
        auth: CodexReviewBackendModel.Auth.Snapshot = .init(),
        plannedAttempt: ReviewAttempt? = nil
    ) {
        self.settings = settings
        self.auth = auth
        self.plannedAttempts = plannedAttempt.map { [$0] } ?? []
    }

    package func recordedCommands() -> [Command] {
        commands
    }

    package func holdStartReview(with gate: AsyncGate) {
        startReviewGate = gate
        startReviewIgnoresCancellation = false
    }

    package func holdStartReviewIgnoringCancellation(with gate: AsyncGate) {
        startReviewGate = gate
        startReviewIgnoresCancellation = true
    }

    package func failInterrupts(message: String) {
        interruptFailureMessage = message
    }

    package func failRecovery(message: String) {
        recoveryFailureMessage = message
    }

    package func failRetainedCleanup(message: String?) {
        retainedCleanupFailureMessage = message
    }

    package func holdRetainedCleanup(with gate: AsyncGate) {
        retainedCleanupGate = gate
    }

    package func waitForRetainedCleanup() async {
        if commands.contains(where: {
            if case .cleanupRetainedReviews = $0 { true } else { false }
        }) {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if commands.contains(where: {
                    if case .cleanupRetainedReviews = $0 { true } else { false }
                }) {
                    continuation.resume()
                } else {
                    retainedCleanupWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelRetainedCleanupWaiter(id: waiterID)
            }
        }
    }

    package func waitForRetainedCleanup(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "cleanupRetainedReviews", timeout: timeout) {
            await self.waitForRetainedCleanup()
        }
    }

    package func holdInterruptReview(with gate: AsyncGate) {
        interruptReviewGate = gate
    }

    package func holdRestartPreparedReview(with gate: AsyncGate) {
        restartPreparedReviewGate = gate
        restartPreparedReviewIgnoresCancellation = false
    }

    package func holdRestartPreparedReviewIgnoringCancellation(with gate: AsyncGate) {
        restartPreparedReviewGate = gate
        restartPreparedReviewIgnoresCancellation = true
    }

    package func planNextRecoveredAttempt(_ attempt: ReviewAttempt) {
        plannedRecoveredAttempts.append(attempt)
    }

    package func planNextAttempt(_ attempt: ReviewAttempt) {
        plannedAttempts.append(attempt)
    }

    package func setDiscardedRestartAttempts(_ attempts: [ReviewAttempt]) {
        discardedRestartAttempts = attempts
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
        await waitForInterruptReviews(count: 1)
    }

    package func waitForInterruptReviews(count: Int) async {
        precondition(count > 0, "An interrupt waiter must require at least one command.")
        if interruptReviewCommandCount >= count {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if interruptReviewCommandCount >= count {
                    continuation.resume()
                } else {
                    interruptReviewWaiters[waiterID] = .init(
                        requiredCount: count,
                        continuation: continuation
                    )
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

    package func waitForInterruptReviews(
        count: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        try await withFakeBackendTimeout(operation: "interruptReview", timeout: timeout) {
            await self.waitForInterruptReviews(count: count)
        }
    }

    package func waitForPrepareReviewRestart() async {
        if commands.contains(where: {
            if case .prepareReviewRestart = $0 {
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
                    if case .prepareReviewRestart = $0 {
                        true
                    } else {
                        false
                    }
                }) {
                    continuation.resume()
                } else {
                    prepareReviewRestartWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelPrepareReviewRestartWaiter(id: waiterID)
            }
        }
    }

    package func waitForPrepareReviewRestart(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "prepareReviewRestart", timeout: timeout) {
            await self.waitForPrepareReviewRestart()
        }
    }

    package func waitForRestartPreparedReview() async {
        if commands.contains(where: {
            if case .restartPreparedReview = $0 {
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
                    if case .restartPreparedReview = $0 {
                        true
                    } else {
                        false
                    }
                }) {
                    continuation.resume()
                } else {
                    restartPreparedReviewWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelRestartPreparedReviewWaiter(id: waiterID)
            }
        }
    }

    package func waitForRestartPreparedReview(timeout: Duration = .seconds(2)) async throws {
        try await withFakeBackendTimeout(operation: "restartPreparedReview", timeout: timeout) {
            await self.waitForRestartPreparedReview()
        }
    }

    package func waitForCleanupReview(_ attempt: ReviewAttempt) async {
        if commands.contains(.cleanupReview(attempt)) {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if commands.contains(.cleanupReview(attempt)) {
                    continuation.resume()
                } else {
                    cleanupReviewWaiters[attempt.attemptID, default: [:]][waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelCleanupReviewWaiter(
                    attemptID: attempt.attemptID,
                    waiterID: waiterID
                )
            }
        }
    }

    package func waitForCleanupReview(
        _ attempt: ReviewAttempt,
        timeout: Duration
    ) async throws {
        try await withFakeBackendTimeout(operation: "cleanupReview", timeout: timeout) {
            await self.waitForCleanupReview(attempt)
        }
    }

    package func readSettings() async throws -> CodexReviewBackendModel.Settings.Snapshot {
        commands.append(.readSettings)
        return settings
    }

    package func applySettings(_ change: CodexReviewBackendModel.Settings.Change) async throws
        -> CodexReviewBackendModel.Settings.Snapshot
    {
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

    package func logout(_ account: CodexReviewBackendModel.Account.ID) async throws
        -> CodexReviewBackendModel.Auth.Snapshot
    {
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
        guard plannedAttempts.isEmpty == false else {
            throw FakeCodexReviewBackendError(
                message: "No review attempt was planned for startReview."
            )
        }
        if let startReviewGate {
            if startReviewIgnoresCancellation {
                await startReviewGate.waitIgnoringCancellation()
            } else {
                try await startReviewGate.wait()
            }
        }
        guard plannedAttempts.isEmpty == false else {
            throw FakeCodexReviewBackendError(
                message: "No review attempt remained planned when startReview completed."
            )
        }
        let plannedAttempt = plannedAttempts.removeFirst()
        return backendAttempt(for: plannedAttempt)
    }

    package func interruptReview(
        _ attempt: ReviewAttempt, reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        commands.append(.interruptReview(attempt, reason))
        let interruptReviewCommandCount = interruptReviewCommandCount
        let readyWaiterIDs = interruptReviewWaiters.compactMap { id, waiter in
            waiter.requiredCount <= interruptReviewCommandCount ? id : nil
        }
        for waiterID in readyWaiterIDs {
            interruptReviewWaiters.removeValue(forKey: waiterID)?.continuation.resume()
        }
        if let interruptReviewGate {
            try await interruptReviewGate.wait()
        }
        if let interruptFailureMessage {
            throw FakeCodexReviewBackendError(message: interruptFailureMessage)
        }
    }

    package func prepareReviewRestart(
        _ attempt: ReviewAttempt
    ) async throws -> CodexReviewBackendModel.Review.RestartToken {
        commands.append(.prepareReviewRestart(attempt))
        let waiters = Array(prepareReviewRestartWaiters.values)
        prepareReviewRestartWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let interruptReviewGate {
            try await interruptReviewGate.wait()
        }
        if let interruptFailureMessage {
            throw FakeCodexReviewBackendError(message: interruptFailureMessage)
        }
        let token = CodexReviewBackendModel.Review.RestartToken(
            id: "restart-token-\(attempt.attemptID.rawValue)",
            interruptedAttempt: attempt
        )
        precondition(
            preparedRestartTokens.updateValue(token, forKey: token.id) == nil,
            "A fake restart token identity can only be prepared once."
        )
        return token
    }

    package func restartPreparedReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        commands.append(.restartPreparedReview(token, request))
        guard preparedRestartTokens[token.id] == token else {
            preconditionFailure("A fake restart token must be live and consumed exactly once.")
        }
        let waiters = Array(restartPreparedReviewWaiters.values)
        restartPreparedReviewWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let restartPreparedReviewGate {
            if restartPreparedReviewIgnoresCancellation {
                await restartPreparedReviewGate.waitIgnoringCancellation()
            } else {
                try await restartPreparedReviewGate.wait()
            }
        }
        if let recoveryFailureMessage {
            throw FakeCodexReviewBackendError(message: recoveryFailureMessage)
        }
        guard plannedRecoveredAttempts.isEmpty == false else {
            throw FakeCodexReviewBackendError(
                message: "No review attempt was planned for restartPreparedReview."
            )
        }
        let recoveredAttempt = plannedRecoveredAttempts.removeFirst()
        preparedRestartTokens.removeValue(forKey: token.id)
        return backendAttempt(for: recoveredAttempt)
    }

    package func discardPreparedReviewRestart(
        _ token: CodexReviewBackendModel.Review.RestartToken
    ) async -> [ReviewAttempt] {
        commands.append(.discardPreparedReviewRestart(token))
        guard preparedRestartTokens.removeValue(forKey: token.id) == token else {
            preconditionFailure("A fake restart token must be live and discarded exactly once.")
        }
        let attempts = discardedRestartAttempts
        discardedRestartAttempts = []
        return attempts
    }

    package func cleanupReview(_ attempt: ReviewAttempt) async {
        commands.append(.cleanupReview(attempt))
        let waiters = cleanupReviewWaiters
            .removeValue(forKey: attempt.attemptID)
            .map { Array($0.values) } ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    package func cleanupRetainedReviews(
        _ attempts: [ReviewAttempt],
        additionalThreadIDs _: [ReviewThreadID]
    ) async -> ReviewRetainedThreadCleanupResult {
        commands.append(.cleanupRetainedReviews(attempts))
        let waiters = Array(retainedCleanupWaiters.values)
        retainedCleanupWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        if let retainedCleanupGate {
            try? await retainedCleanupGate.wait()
        }
        guard let retainedCleanupFailureMessage,
              let attempt = attempts.first
        else {
            return .init()
        }
        return .init(failures: [
            .init(
                threadID: attempt.threadIdentity.activeTurnThreadID,
                message: retainedCleanupFailureMessage
            )
        ])
    }

    package func yield(_ terminal: FakeReviewTerminal, for attempt: ReviewAttempt) async {
        await terminalSource(for: attempt).yield(terminal)
    }

    package func finishEvents(for attempt: ReviewAttempt) async {
        await terminalSource(for: attempt).finish()
    }

    package func finishEvents(throwing error: any Error, for attempt: ReviewAttempt) async {
        await terminalSource(for: attempt).finish(throwing: error)
    }

    package func finishEventMailboxes() async {
        let sources = Array(terminalSources.values)
        terminalSources.removeAll(keepingCapacity: false)
        for source in sources {
            await source.finish()
        }
    }

    package func hasEventMailbox(for attempt: ReviewAttempt) -> Bool {
        terminalSources[.init(attempt: attempt)] != nil
    }

    private func terminalSource(for attempt: ReviewAttempt) -> FakeReviewTerminalSource {
        let key = TerminalSourceKey(attempt: attempt)
        if let source = terminalSources[key] {
            return source
        }
        let source = FakeReviewTerminalSource(attempt: attempt)
        terminalSources[key] = source
        return source
    }

    private func backendAttempt(for attempt: ReviewAttempt) -> BackendReviewAttempt {
        let source = terminalSource(for: attempt)
        return BackendReviewAttempt(
            attempt: attempt,
            observeTerminal: {
                try await source.observe()
            },
            observedTerminalIfKnown: {
                await source.observedIfKnown()
            },
            finalizeTerminal: { observed in
                switch observed {
                case .completed(let candidate):
                    .completed(.init(finalReview: candidate.expectedOutput))
                case .interrupted(let message):
                    .interrupted(message: message)
                case .failed(let failure):
                    .failed(failure)
                }
            }
        )
    }

    private func cancelStartReviewWaiter(id: UUID) {
        startReviewWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelInterruptReviewWaiter(id: UUID) {
        interruptReviewWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    private var interruptReviewCommandCount: Int {
        commands.reduce(into: 0) { count, command in
            if case .interruptReview = command {
                count += 1
            }
        }
    }

    private func cancelPrepareReviewRestartWaiter(id: UUID) {
        prepareReviewRestartWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelRestartPreparedReviewWaiter(id: UUID) {
        restartPreparedReviewWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelCleanupReviewWaiter(
        attemptID: ReviewAttemptID,
        waiterID: UUID
    ) {
        cleanupReviewWaiters[attemptID]?.removeValue(forKey: waiterID)?.resume()
        if cleanupReviewWaiters[attemptID]?.isEmpty == true {
            cleanupReviewWaiters.removeValue(forKey: attemptID)
        }
    }

    private func cancelRetainedCleanupWaiter(id: UUID) {
        retainedCleanupWaiters.removeValue(forKey: id)?.resume()
    }

}

@MainActor
package final class StoreSnapshotProbe {
    private let store: CodexReviewStore

    package init(store: CodexReviewStore) {
        self.store = store
    }

    package func snapshot() -> StoreSnapshot {
        let reviewRuns = store.reviewRuns
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.id.rawValue < rhs.id.rawValue
                }
                return lhs.sortOrder > rhs.sortOrder
            }
            .map { runRecord in
                let runtimeState = store.runtimeReviewRunState(runID: runRecord.id)
                return StoreRunSnapshot(
                    runID: runRecord.id.rawValue,
                    status: runRecord.core.status,
                    summary: runRecord.presentation.lifecycle.testingSummary,
                    attempt: runRecord.core.attempt,
                    activeAttempt: runtimeState.activeAttempt,
                    cancellationRequested: runRecord.cancellationRequested
                )
            }
        return StoreSnapshot(reviewRuns: reviewRuns)
    }

    package func waitUntilRunStatus(
        _ status: ReviewRunState,
        runID: String? = nil,
        timeout: Duration = .seconds(2)
    ) async -> StoreSnapshot? {
        await waitUntil(timeout: timeout) { snapshot in
            snapshot.run(runID)?.status == status
        }
    }

    package func waitUntilRunAttempt(
        _ attemptID: String,
        runID: String? = nil,
        timeout: Duration = .seconds(2)
    ) async -> StoreSnapshot? {
        await waitUntil(timeout: timeout) { snapshot in
            snapshot.run(runID)?.activeAttempt?.attemptID.rawValue == attemptID
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
    package var reviewRuns: [StoreRunSnapshot]

    package func run(_ runID: String? = nil) -> StoreRunSnapshot? {
        guard let runID else {
            return reviewRuns.first
        }
        return reviewRuns.first { $0.runID == runID }
    }
}

package struct StoreRunSnapshot: Sendable {
    package var runID: String
    package var status: ReviewRunState
    package var summary: String
    package var attempt: ReviewAttempt?
    package var activeAttempt: ReviewAttempt?
    package var cancellationRequested: Bool
}

private extension ReviewLifecyclePresentation {
    var testingSummary: String {
        switch self {
        case .queued:
            "Queued."
        case .starting:
            "Starting review."
        case .running:
            "Review started."
        case .waitingForNetwork:
            "Network unavailable; waiting to reconnect."
        case .preparingRestart:
            "Preparing review restart."
        case .restarting:
            "Network restored; restarting review."
        case .cancelling(let cancellation), .cancelled(let cancellation):
            cancellation.message
        case .succeeded:
            "Review completed."
        case .failed(let failure):
            failure.message
        }
    }
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

    package func stop(store _: CodexReviewStore, purpose _: CodexReviewRuntimeStopPurpose) async {
        isActive = false
    }

    package func waitUntilStopped() async {}

    package func refreshAuth(auth: CodexReviewAuthModel) async {
        do {
            let snapshot = try await reviewBackend.readAuth()
            let accounts = snapshot.accounts.compactMap { account -> CodexReviewKit.CodexReviewAccount? in
                let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.isEmpty == false else {
                    return nil
                }
                return CodexReviewKit.CodexReviewAccount(email: label)
            }
            auth.applyPersistedAccountStates(
                accounts.map(savedAccountPayload(from:)),
                activeAccountKey: snapshot.activeAccountID?.rawValue
            )
            auth.selectPersistedAccount(snapshot.activeAccountID?.rawValue)
            auth.updatePhase(auth.selectedAccount == nil ? .signedOut : .signedOut)
        } catch {
            auth.updatePhase(.failed(.runtime(message: error.localizedDescription)))
        }
    }

    package func signIn(auth: CodexReviewAuthModel) async throws {
        auth.updatePhase(.signingIn(.init(
            title: "Sign in to Codex",
            detail: "Complete sign in in your browser, then return to ReviewMonitor.",
            browserURL: nil,
            userCode: nil
        )))
    }

    package func addAccount(auth: CodexReviewAuthModel) async throws {
        try await signIn(auth: auth)
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
        _ attempt: ReviewAttempt,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        try await reviewBackend.interruptReview(attempt, reason: reason)
    }

    package func prepareReviewRestart(
        _ attempt: ReviewAttempt
    ) async throws -> CodexReviewBackendModel.Review.RestartToken {
        try await reviewBackend.prepareReviewRestart(attempt)
    }

    package func restartPreparedReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        try await reviewBackend.restartPreparedReview(token, request: request)
    }

    package func discardPreparedReviewRestart(
        _ token: CodexReviewBackendModel.Review.RestartToken
    ) async -> [ReviewAttempt] {
        await reviewBackend.discardPreparedReviewRestart(token)
    }

    package func cleanupReview(_ attempt: ReviewAttempt) async {
        await reviewBackend.cleanupReview(attempt)
    }

    package func cleanupRetainedReviews(
        _ attempts: [ReviewAttempt],
        additionalThreadIDs: [ReviewThreadID]
    ) async -> ReviewRetainedThreadCleanupResult {
        await reviewBackend.cleanupRetainedReviews(
            attempts,
            additionalThreadIDs: additionalThreadIDs
        )
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

package typealias FakeCodexAppServerTransport = CodexAppServerTestTransport
