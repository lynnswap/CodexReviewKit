import Foundation

private enum ReviewRuntimeSemanticStopBoundedOutcome<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
}

private actor ReviewRuntimeSemanticStopBoundedRace<Value: Sendable> {
    private var result: ReviewRuntimeSemanticStopBoundedOutcome<Value>?
    private var continuation: CheckedContinuation<ReviewRuntimeSemanticStopBoundedOutcome<Value>, Never>?

    func finish(_ value: ReviewRuntimeSemanticStopBoundedOutcome<Value>) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func wait() async -> ReviewRuntimeSemanticStopBoundedOutcome<Value> {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }
}

@MainActor
package final class ReviewRuntimeSemanticStopExecutionOwner {
    package struct Policy: Sendable {
        package let cancellationTimeout: Duration
        package let workerDrainTimeout: Duration
        package let forceCloseAfterCancellationFailure: @MainActor @Sendable () async -> Void
        package let reportCancellationFailure: @MainActor @Sendable (ReviewRuntimeCloseFailure) -> Void
        package let reportTimeout: @MainActor @Sendable () -> Void

        package init(
            cancellationTimeout: Duration,
            workerDrainTimeout: Duration,
            forceCloseAfterCancellationFailure: @escaping @MainActor @Sendable () async -> Void,
            reportCancellationFailure: @escaping @MainActor @Sendable (ReviewRuntimeCloseFailure) -> Void,
            reportTimeout: @escaping @MainActor @Sendable () -> Void
        ) {
            self.cancellationTimeout = cancellationTimeout
            self.workerDrainTimeout = workerDrainTimeout
            self.forceCloseAfterCancellationFailure = forceCloseAfterCancellationFailure
            self.reportCancellationFailure = reportCancellationFailure
            self.reportTimeout = reportTimeout
        }

        package static let defaultPolicy = Policy(
            cancellationTimeout: .seconds(2),
            workerDrainTimeout: .seconds(2),
            forceCloseAfterCancellationFailure: {},
            reportCancellationFailure: { _ in },
            reportTimeout: {}
        )
    }

    private var eventualCleanupTasks: [UUID: Task<Void, Never>] = [:]

    package init() {}

    isolated deinit {
        for task in eventualCleanupTasks.values { task.cancel() }
    }

    package var eventualCleanupTasksForTesting: [Task<Void, Never>] {
        Array(eventualCleanupTasks.values)
    }

    package func stop(
        context: ReviewRuntimeSemanticStopContext,
        intent: ReviewRuntimeTeardownIntent,
        policy: Policy
    ) async {
        let workerJobIDs = context.workerJobIDs
        let cancellationCleanup = await runBounded(
            timeout: policy.cancellationTimeout
        ) {
            await context.requestCancellations()
        }
        let cancellationJobIDs: [String]
        let cancellationTimedOut: Bool
        let didRequestCancellation: Bool
        switch cancellationCleanup {
        case .completed(let outcome):
            cancellationJobIDs = outcome.jobIDs
            cancellationTimedOut = false
            didRequestCancellation = outcome.firstFailure == nil
            if let failure = outcome.firstFailure {
                policy.reportCancellationFailure(failure)
            }
        case .timedOut:
            cancellationJobIDs = []
            cancellationTimedOut = true
            didRequestCancellation = false
        }
        if didRequestCancellation == false {
            await policy.forceCloseAfterCancellationFailure()
        }

        let locallyCancelledJobIDs = context.completeCancellationsLocally(
            reason: intent.reviewCancellation
        )
        let currentWorkerJobIDs = context.workerJobIDs
        let workerCleanup = await runBounded(
            timeout: policy.workerDrainTimeout
        ) {
            await context.cancelWorkers(
                jobIDs: Array(Set(
                    workerJobIDs
                        + cancellationJobIDs
                        + locallyCancelledJobIDs
                        + currentWorkerJobIDs
                )),
                reason: intent.reviewCancellation
            )
            await context.waitForWorkers()
        }
        let workerTimedOut: Bool = switch workerCleanup {
        case .completed: false
        case .timedOut: true
        }
        if cancellationTimedOut || workerTimedOut {
            policy.reportTimeout()
        }
    }

    private func runBounded<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @MainActor @Sendable () async -> Value
    ) async -> ReviewRuntimeSemanticStopBoundedOutcome<Value> {
        let id = UUID()
        let race = ReviewRuntimeSemanticStopBoundedRace<Value>()
        let operationTask = Task { @MainActor [weak self] in
            let value = await operation()
            await race.finish(.completed(value))
            self?.eventualCleanupTasks.removeValue(forKey: id)
        }
        eventualCleanupTasks[id] = operationTask
        let timeoutTask = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            await race.finish(.timedOut)
        }
        let result = await race.wait()
        switch result {
        case .completed: timeoutTask.cancel()
        case .timedOut: operationTask.cancel()
        }
        return result
    }
}
