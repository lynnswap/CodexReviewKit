import Foundation

package struct CodexReviewRuntimeJobState: Sendable {
    package let activeRun: CodexReviewBackendModel.Review.Run?
    package let hasActiveWorker: Bool
    package let hasDetachedWorker: Bool
    package let isWaitingForNetworkRecovery: Bool
}

@MainActor
final class CodexReviewStoreRuntimeState {
    typealias BackendReviewRun = CodexReviewBackendModel.Review.Run

    private var activeRuns: [String: BackendReviewRun] = [:]
    private var reviewRecoveryWaitingJobIDs: Set<String> = []
    private var startingJobIDs: Set<String> = []
    private var startupCancellations: [String: ReviewCancellation] = [:]
    private var reviewWorkerTasks: [String: Task<Void, Never>] = [:]
    private var runtimeStopDetachedReviewWorkerTasks: [String: Task<Void, Never>] = [:]

    func jobState(for jobID: String) -> CodexReviewRuntimeJobState {
        CodexReviewRuntimeJobState(
            activeRun: activeRuns[jobID],
            hasActiveWorker: reviewWorkerTasks[jobID] != nil,
            hasDetachedWorker: runtimeStopDetachedReviewWorkerTasks[jobID] != nil,
            isWaitingForNetworkRecovery: reviewRecoveryWaitingJobIDs.contains(jobID)
        )
    }

    func activeRun(for jobID: String) -> BackendReviewRun? {
        activeRuns[jobID]
    }

    func setActiveRun(_ run: BackendReviewRun, for jobID: String) {
        activeRuns[jobID] = run
    }

    func removeActiveRun(for jobID: String) {
        activeRuns.removeValue(forKey: jobID)
    }

    func recoveryWaitingRuns() -> [BackendReviewRun] {
        reviewRecoveryWaitingJobIDs
            .sorted()
            .compactMap { activeRuns[$0] }
    }

    func isWaitingForNetworkRecovery(_ jobID: String) -> Bool {
        reviewRecoveryWaitingJobIDs.contains(jobID)
    }

    func markWaitingForNetworkRecovery(_ jobID: String) {
        reviewRecoveryWaitingJobIDs.insert(jobID)
    }

    func clearWaitingForNetworkRecovery(_ jobID: String) {
        reviewRecoveryWaitingJobIDs.remove(jobID)
    }

    func markStarting(_ jobID: String) {
        startingJobIDs.insert(jobID)
    }

    func clearStarting(_ jobID: String) {
        startingJobIDs.remove(jobID)
    }

    func isStarting(_ jobID: String) -> Bool {
        startingJobIDs.contains(jobID)
    }

    func setStartupCancellation(_ cancellation: ReviewCancellation, for jobID: String) {
        startupCancellations[jobID] = cancellation
    }

    func takeStartupCancellation(for jobID: String) -> ReviewCancellation? {
        startupCancellations.removeValue(forKey: jobID)
    }

    func setActiveWorker(_ task: Task<Void, Never>, for jobID: String) {
        reviewWorkerTasks[jobID] = task
    }

    func cancelActiveWorker(for jobID: String) {
        reviewWorkerTasks[jobID]?.cancel()
    }

    func removeActiveWorker(for jobID: String) {
        reviewWorkerTasks.removeValue(forKey: jobID)
    }

    func awaitActiveWorker(for jobID: String) async {
        let task = reviewWorkerTasks[jobID]
        await task?.value
    }

    func cancelAndDetachActiveWorkerForRuntimeStop(jobID: String) {
        if let task = reviewWorkerTasks.removeValue(forKey: jobID) {
            task.cancel()
            runtimeStopDetachedReviewWorkerTasks[jobID] = task
        }
    }

    func removeDetachedWorker(for jobID: String) {
        runtimeStopDetachedReviewWorkerTasks.removeValue(forKey: jobID)
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

    func clearRuntimeStopState(for jobID: String) {
        removeActiveRun(for: jobID)
        clearWaitingForNetworkRecovery(jobID)
        clearStarting(jobID)
        _ = takeStartupCancellation(for: jobID)
    }

    func clearReviewRunState(for jobID: String) {
        removeActiveRun(for: jobID)
        clearWaitingForNetworkRecovery(jobID)
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
        startingJobIDs.removeAll(keepingCapacity: false)
        startupCancellations.removeAll(keepingCapacity: false)
        activeRuns.removeAll(keepingCapacity: false)
        reviewRecoveryWaitingJobIDs.removeAll(keepingCapacity: false)
    }
}

extension CodexReviewStore {
    package func runtimeJobState(jobID: String) -> CodexReviewRuntimeJobState {
        runtimeState.jobState(for: jobID)
    }
}
