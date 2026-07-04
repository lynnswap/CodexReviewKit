import Foundation

package struct CodexReviewRuntimeRunState: Sendable {
    package let activeRun: CodexReviewBackendModel.Review.Run?
    package let hasActiveWorker: Bool
    package let hasDetachedWorker: Bool
    package let isWaitingForNetworkRecovery: Bool
}

@MainActor
final class CodexReviewStoreRuntimeState {
    typealias BackendReviewRun = CodexReviewBackendModel.Review.Run

    private var activeRuns: [String: BackendReviewRun] = [:]
    private var reviewRecoveryWaitingRunIDs: Set<String> = []
    private var startingRunIDs: Set<String> = []
    private var startupCancellations: [String: ReviewCancellation] = [:]
    private var reviewWorkerTasks: [String: Task<Void, Never>] = [:]
    private var runtimeStopDetachedReviewWorkerTasks: [String: Task<Void, Never>] = [:]

    func runState(for runID: String) -> CodexReviewRuntimeRunState {
        CodexReviewRuntimeRunState(
            activeRun: activeRuns[runID],
            hasActiveWorker: reviewWorkerTasks[runID] != nil,
            hasDetachedWorker: runtimeStopDetachedReviewWorkerTasks[runID] != nil,
            isWaitingForNetworkRecovery: reviewRecoveryWaitingRunIDs.contains(runID)
        )
    }

    func activeRun(for runID: String) -> BackendReviewRun? {
        activeRuns[runID]
    }

    func setActiveRun(_ run: BackendReviewRun, for runID: String) {
        activeRuns[runID] = run
    }

    func removeActiveRun(for runID: String) {
        activeRuns.removeValue(forKey: runID)
    }

    func recoveryWaitingRuns() -> [BackendReviewRun] {
        reviewRecoveryWaitingRunIDs
            .sorted()
            .compactMap { activeRuns[$0] }
    }

    func isWaitingForNetworkRecovery(_ runID: String) -> Bool {
        reviewRecoveryWaitingRunIDs.contains(runID)
    }

    func markWaitingForNetworkRecovery(_ runID: String) {
        reviewRecoveryWaitingRunIDs.insert(runID)
    }

    func clearWaitingForNetworkRecovery(_ runID: String) {
        reviewRecoveryWaitingRunIDs.remove(runID)
    }

    func markStarting(_ runID: String) {
        startingRunIDs.insert(runID)
    }

    func clearStarting(_ runID: String) {
        startingRunIDs.remove(runID)
    }

    func isStarting(_ runID: String) -> Bool {
        startingRunIDs.contains(runID)
    }

    func setStartupCancellation(_ cancellation: ReviewCancellation, for runID: String) {
        startupCancellations[runID] = cancellation
    }

    func takeStartupCancellation(for runID: String) -> ReviewCancellation? {
        startupCancellations.removeValue(forKey: runID)
    }

    func setActiveWorker(_ task: Task<Void, Never>, for runID: String) {
        reviewWorkerTasks[runID] = task
    }

    func cancelActiveWorker(for runID: String) {
        reviewWorkerTasks[runID]?.cancel()
    }

    func removeActiveWorker(for runID: String) {
        reviewWorkerTasks.removeValue(forKey: runID)
    }

    func awaitActiveWorker(for runID: String) async {
        let task = reviewWorkerTasks[runID]
        await task?.value
    }

    func cancelAndDetachActiveWorkerForRuntimeStop(runID: String) {
        if let task = reviewWorkerTasks.removeValue(forKey: runID) {
            task.cancel()
            runtimeStopDetachedReviewWorkerTasks[runID] = task
        }
    }

    func removeDetachedWorker(for runID: String) {
        runtimeStopDetachedReviewWorkerTasks.removeValue(forKey: runID)
    }

    func activeWorkerTasks() -> [Task<Void, Never>] {
        Array(reviewWorkerTasks.values)
    }

    func detachedWorkerTasks() -> [Task<Void, Never>] {
        Array(runtimeStopDetachedReviewWorkerTasks.values)
    }

    func allWorkerTasks() -> [Task<Void, Never>] {
        activeWorkerTasks() + detachedWorkerTasks()
    }

    func clearRuntimeStopState(for runID: String) {
        removeActiveRun(for: runID)
        clearWaitingForNetworkRecovery(runID)
        clearStarting(runID)
        _ = takeStartupCancellation(for: runID)
    }

    func clearReviewRunState(for runID: String) {
        removeActiveRun(for: runID)
        clearWaitingForNetworkRecovery(runID)
    }

    func cancelAllWorkers() {
        for task in allWorkerTasks() {
            task.cancel()
        }
    }

    func cancelAndDrainAllWorkersForTesting() async {
        let tasks = allWorkerTasks()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    func clearForTesting() {
        reviewWorkerTasks.removeAll(keepingCapacity: false)
        runtimeStopDetachedReviewWorkerTasks.removeAll(keepingCapacity: false)
        startingRunIDs.removeAll(keepingCapacity: false)
        startupCancellations.removeAll(keepingCapacity: false)
        activeRuns.removeAll(keepingCapacity: false)
        reviewRecoveryWaitingRunIDs.removeAll(keepingCapacity: false)
    }
}

extension CodexReviewStore {
    package func runtimeReviewRunState(runID: String) -> CodexReviewRuntimeRunState {
        runtimeState.runState(for: runID)
    }
}
