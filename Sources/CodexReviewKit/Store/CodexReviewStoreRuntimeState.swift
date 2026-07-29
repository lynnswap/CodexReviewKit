import Foundation
import Synchronization

package struct CodexReviewRuntimeRunState: Sendable {
    package let activeAttempt: ReviewAttempt?
    package let hasActiveWorker: Bool
    package let isWaitingForNetworkRecovery: Bool
}

package struct CodexReviewSessionCloseResult: Equatable, Sendable {
    package let terminalAndDrainedRunIDs: Set<ReviewRunID>
    package let failedRunIDs: Set<ReviewRunID>

    package init(
        terminalAndDrainedRunIDs: Set<ReviewRunID>,
        failedRunIDs: Set<ReviewRunID> = []
    ) {
        self.terminalAndDrainedRunIDs = terminalAndDrainedRunIDs
        self.failedRunIDs = failedRunIDs
    }
}

struct ReviewWorkerGeneration: Hashable, Sendable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

struct ReviewCancellationOperationToken: Hashable, Sendable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

enum ReviewCancellationOperationResult: Sendable {
    case completed
    case failed(ReviewBackendFailure)
}

enum ReviewWorkerCancellationAuthority: Sendable {
    case interrupt(ReviewAttempt)
    case workerCleanup
}

private enum ReviewCancellationWaitResult: Sendable {
    case operation(ReviewCancellationOperationResult)
    case callerCancelled
}

private final class ReviewCancellationWaiter: Sendable {
    private enum State: Sendable {
        case idle
        case waiting(CheckedContinuation<ReviewCancellationWaitResult, Never>)
        case finished(ReviewCancellationWaitResult)
    }

    private let state = Mutex<State>(.idle)

    func wait() async -> ReviewCancellationWaitResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> ReviewCancellationWaitResult? in
                    switch state {
                    case .idle where Task.isCancelled:
                        state = .finished(.callerCancelled)
                        return .callerCancelled
                    case .idle:
                        state = .waiting(continuation)
                        return nil
                    case .waiting:
                        preconditionFailure("A cancellation completion waiter is single-consumer.")
                    case .finished(let result):
                        return result
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            finish(.callerCancelled)
        }
    }

    func finish(_ result: ReviewCancellationWaitResult) {
        let continuation = state.withLock { state
            -> CheckedContinuation<ReviewCancellationWaitResult, Never>? in
            switch state {
            case .idle:
                state = .finished(result)
                return nil
            case .waiting(let continuation):
                state = .finished(result)
                return continuation
            case .finished:
                return nil
            }
        }
        continuation?.resume(returning: result)
    }
}

final class ReviewCancellationCompletion: Sendable {
    private struct State: Sendable {
        var result: ReviewCancellationOperationResult?
        var waiters: [ReviewCancellationWaiter] = []
    }

    private let state = Mutex(State())

    func wait() async throws {
        let waiter = ReviewCancellationWaiter()
        let immediate = state.withLock { state -> ReviewCancellationOperationResult? in
            if let result = state.result {
                return result
            }
            state.waiters.append(waiter)
            return nil
        }
        let waitResult: ReviewCancellationWaitResult
        if let immediate {
            waitResult = .operation(immediate)
        } else {
            waitResult = await waiter.wait()
        }
        switch waitResult {
        case .operation(.completed):
            return
        case .operation(.failed(let failure)):
            throw failure
        case .callerCancelled:
            throw CancellationError()
        }
    }

    func finish(_ result: ReviewCancellationOperationResult) {
        let waiters = state.withLock { state -> [ReviewCancellationWaiter] in
            guard state.result == nil else {
                preconditionFailure("A cancellation operation completion can only resolve once.")
            }
            state.result = result
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.finish(.operation(result))
        }
    }

    var resultIfFinished: ReviewCancellationOperationResult? {
        state.withLock { $0.result }
    }
}

struct ReviewCancellationJoin: Sendable {
    let token: ReviewCancellationOperationToken
    let task: Task<Void, Never>
    let completion: ReviewCancellationCompletion
}

@MainActor
final class ReviewStoreRuntime {
    private struct WorkerEntry {
        let generation: ReviewWorkerGeneration
        let task: Task<Void, Never>
    }

    private struct CancellationEntry {
        let join: ReviewCancellationJoin
    }

    private var activeAttempts: [ReviewRunID: ReviewAttempt] = [:]
    private var reviewRecoveryWaitingRunIDs: Set<ReviewRunID> = []
    private var startingRunIDs: Set<ReviewRunID> = []
    private var startupCancellations: [ReviewRunID: ReviewCancellation] = [:]
    private var cancellationAuthorities: [ReviewRunID: ReviewWorkerCancellationAuthority] = [:]
    private var workers: [ReviewRunID: WorkerEntry] = [:]
    private var cancellationOperations: [ReviewRunID: CancellationEntry] = [:]

    isolated deinit {
        signalCancellation()
    }

    func runState(for runID: ReviewRunID) -> CodexReviewRuntimeRunState {
        CodexReviewRuntimeRunState(
            activeAttempt: activeAttempts[runID],
            hasActiveWorker: workers[runID] != nil,
            isWaitingForNetworkRecovery: reviewRecoveryWaitingRunIDs.contains(runID)
        )
    }

    func activeAttempt(for runID: ReviewRunID) -> ReviewAttempt? {
        activeAttempts[runID]
    }

    func setActiveAttempt(_ attempt: ReviewAttempt, for runID: ReviewRunID) {
        activeAttempts[runID] = attempt
    }

    func removeActiveAttempt(for runID: ReviewRunID) {
        activeAttempts.removeValue(forKey: runID)
    }

    func recoveryWaitingAttempts() -> [ReviewAttempt] {
        reviewRecoveryWaitingRunIDs
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { activeAttempts[$0] }
    }

    func isWaitingForNetworkRecovery(_ runID: ReviewRunID) -> Bool {
        reviewRecoveryWaitingRunIDs.contains(runID)
    }

    func markWaitingForNetworkRecovery(_ runID: ReviewRunID) {
        reviewRecoveryWaitingRunIDs.insert(runID)
    }

    func clearWaitingForNetworkRecovery(_ runID: ReviewRunID) {
        reviewRecoveryWaitingRunIDs.remove(runID)
    }

    func markStarting(_ runID: ReviewRunID) {
        startingRunIDs.insert(runID)
    }

    func clearStarting(_ runID: ReviewRunID) {
        startingRunIDs.remove(runID)
    }

    func isStarting(_ runID: ReviewRunID) -> Bool {
        startingRunIDs.contains(runID)
    }

    func setStartupCancellation(_ cancellation: ReviewCancellation, for runID: ReviewRunID) {
        startupCancellations[runID] = cancellation
    }

    func startupCancellation(for runID: ReviewRunID) -> ReviewCancellation? {
        startupCancellations[runID]
    }

    func takeStartupCancellation(for runID: ReviewRunID) -> ReviewCancellation? {
        startupCancellations.removeValue(forKey: runID)
    }

    func setCancellationAuthority(
        _ authority: ReviewWorkerCancellationAuthority,
        for runID: ReviewRunID
    ) {
        cancellationAuthorities[runID] = authority
    }

    func cancellationAuthority(for runID: ReviewRunID) -> ReviewWorkerCancellationAuthority? {
        cancellationAuthorities[runID]
    }

    @discardableResult
    func installWorker(
        for runID: ReviewRunID,
        generation: ReviewWorkerGeneration,
        task: Task<Void, Never>
    ) -> Task<Void, Never> {
        precondition(
            workers[runID] == nil,
            "A review run can only own one worker generation."
        )
        workers[runID] = WorkerEntry(generation: generation, task: task)
        return task
    }

    func workerTask(for runID: ReviewRunID) -> Task<Void, Never>? {
        workers[runID]?.task
    }

    func cancelActiveWorker(for runID: ReviewRunID) {
        workers[runID]?.task.cancel()
    }

    func workerFinished(for runID: ReviewRunID, generation: ReviewWorkerGeneration) {
        if workers[runID]?.generation == generation {
            workers.removeValue(forKey: runID)
        }
    }

    func awaitActiveWorker(for runID: ReviewRunID) async {
        await workerTask(for: runID)?.value
    }

    func activeWorkerTasks() -> [Task<Void, Never>] {
        workers.values.map(\.task)
    }

    func allWorkerTasks() -> [Task<Void, Never>] {
        activeWorkerTasks()
    }

    func existingCancellationOperation(for runID: ReviewRunID) -> ReviewCancellationJoin? {
        cancellationOperations[runID]?.join
    }

    func installCancellationOperation(
        _ join: ReviewCancellationJoin,
        for runID: ReviewRunID
    ) {
        precondition(
            cancellationOperations[runID] == nil,
            "A review run can only own one accepted cancellation operation."
        )
        cancellationOperations[runID] = CancellationEntry(join: join)
    }

    func cancellationOperationFinished(
        for runID: ReviewRunID,
        token: ReviewCancellationOperationToken
    ) {
        guard cancellationOperations[runID]?.join.token == token else {
            return
        }
        cancellationOperations.removeValue(forKey: runID)
    }

    func cancellationOperationTasks() -> [Task<Void, Never>] {
        cancellationOperations.values.map(\.join.task)
    }

    func ownedTasks(for runIDs: Set<ReviewRunID>) -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        for runID in runIDs {
            if let task = workerTask(for: runID) {
                tasks.append(task)
            }
            if let task = cancellationOperations[runID]?.join.task {
                tasks.append(task)
            }
        }
        return tasks
    }

    func isDrained(_ runID: ReviewRunID) -> Bool {
        workers[runID] == nil
            && cancellationOperations[runID] == nil
            && activeAttempts[runID] == nil
    }

    func clearReviewRunState(for runID: ReviewRunID) {
        removeActiveAttempt(for: runID)
        clearWaitingForNetworkRecovery(runID)
        clearStarting(runID)
        _ = takeStartupCancellation(for: runID)
        cancellationAuthorities.removeValue(forKey: runID)
    }

    func signalCancellation() {
        for task in allWorkerTasks() {
            task.cancel()
        }
        for task in cancellationOperationTasks() {
            task.cancel()
        }
    }

    func cancelAndDrainAllWorkersForTesting() async {
        signalCancellation()
        let tasks = allWorkerTasks() + cancellationOperationTasks()
        for task in tasks {
            await task.value
        }
    }

    func clearForTesting() {
        precondition(
            allWorkerTasks().allSatisfy(\.isCancelled),
            "Testing cleanup must signal every review worker before clearing runtime ownership."
        )
        workers.removeAll(keepingCapacity: false)
        cancellationOperations.removeAll(keepingCapacity: false)
        startingRunIDs.removeAll(keepingCapacity: false)
        startupCancellations.removeAll(keepingCapacity: false)
        cancellationAuthorities.removeAll(keepingCapacity: false)
        activeAttempts.removeAll(keepingCapacity: false)
        reviewRecoveryWaitingRunIDs.removeAll(keepingCapacity: false)
    }
}

extension CodexReviewStore {
    package func runtimeReviewRunState(runID: ReviewRunID) -> CodexReviewRuntimeRunState {
        runtimeState.runState(for: runID)
    }
}
