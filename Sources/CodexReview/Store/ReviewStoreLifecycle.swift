import Foundation

package enum ReviewStoreWorkKind: Hashable, Sendable {
    case reviewMutation(String)
    case reviewWorker(jobID: String)
    case reviewWaiter(jobID: String)
    case rateLimitWakeUp
    case rateLimitRefresh(accountKey: String)
    case accountAction
    case testing(String)

    package var description: String {
        switch self {
        case .reviewMutation(let operation):
            "Review mutation \(operation)"
        case .reviewWorker(let jobID):
            "Review worker \(jobID)"
        case .reviewWaiter(let jobID):
            "Review waiter \(jobID)"
        case .rateLimitWakeUp:
            "Rate-limit wake-up"
        case .rateLimitRefresh(let accountKey):
            "Rate-limit refresh \(accountKey)"
        case .accountAction:
            "Account action"
        case .testing(let label):
            label
        }
    }
}

package enum ReviewStoreWorkCancelledBeforeEntryPolicy: Sendable {
    case skip
    case runFinalizer(@MainActor @Sendable (CodexReviewStore) -> Void)
}

package enum ReviewStoreWorkFailureCause: LocalizedError, Equatable, Sendable {
    case interruptRequest(ReviewInterruptRequestFailure)
    case runtime(ReviewRuntimeCloseFailure)
    case operation(String)

    package var errorDescription: String? {
        switch self {
        case .interruptRequest(let failure):
            failure.localizedDescription
        case .runtime(let failure):
            failure.localizedDescription
        case .operation(let message):
            message
        }
    }
}

package struct ReviewStoreWorkFailure: LocalizedError, Equatable, Sendable {
    package let ordinal: UInt64
    package let kind: ReviewStoreWorkKind
    package let cause: ReviewStoreWorkFailureCause

    package var errorDescription: String? {
        "\(kind.description) failed: \(cause.localizedDescription)"
    }
}

package struct ReviewStoreWorkFailureAggregate: LocalizedError, Equatable, Sendable {
    package let first: ReviewStoreWorkFailure
    package let additionalInOrdinalOrder: [ReviewStoreWorkFailure]

    package var errorDescription: String? {
        ([first] + additionalInOrdinalOrder)
            .map(\.localizedDescription)
            .joined(separator: "; ")
    }
}

package struct ReviewStoreWorkDrainResult: Equatable, Sendable {
    package let failures: ReviewStoreWorkFailureAggregate?

    package static let success = ReviewStoreWorkDrainResult(failures: nil)
}

package enum ReviewStoreWorkRegistryStatus: Equatable, Sendable {
    case open
    case closing
    case closed
}

@MainActor
package final class ReviewStoreWorkRegistry {
    package struct Admission: Hashable, Sendable {
        package let ordinal: UInt64
        package let kind: ReviewStoreWorkKind
    }

    package struct CloseOperation {
        package let id: UInt64
        package let task: Task<ReviewStoreWorkDrainResult, Never>
    }

    private enum State {
        case open
        case closing(CloseOperation)
        case closed(CloseOperation, ReviewStoreWorkDrainResult)
    }

    @MainActor
    private final class RegisteredTask {
        let admission: Admission
        private let cancelOperation: () -> Void
        private let waitOperation: () async -> (any Error)?

        init<Success: Sendable, Failure: Error>(
            admission: Admission,
            task: Task<Success, Failure>
        ) {
            self.admission = admission
            self.cancelOperation = {
                task.cancel()
            }
            self.waitOperation = {
                switch await task.result {
                case .success:
                    return nil
                case .failure(let error):
                    return error
                }
            }
        }

        func cancel() {
            cancelOperation()
        }

        func waitForFailure() async -> ReviewStoreWorkFailure? {
            guard let error = await waitOperation() else {
                return nil
            }
            guard error is CancellationError == false else {
                return nil
            }
            let cause: ReviewStoreWorkFailureCause
            if let failure = error as? ReviewInterruptRequestFailure {
                cause = .interruptRequest(failure)
            } else if let failure = error as? ReviewRuntimeCloseFailure {
                cause = .runtime(failure)
            } else {
                cause = .operation(error.localizedDescription)
            }
            return .init(
                ordinal: admission.ordinal,
                kind: admission.kind,
                cause: cause
            )
        }
    }

    private var state: State = .open
    private var admissionIsOpen = true
    private var nextWorkOrdinal: UInt64 = 0
    private var nextCloseID: UInt64 = 0
    private var registeredTasks: [UInt64: RegisteredTask] = [:]

    package private(set) var closeTaskCreationCount = 0

    package var status: ReviewStoreWorkRegistryStatus {
        switch state {
        case .open:
            .open
        case .closing:
            .closing
        case .closed:
            .closed
        }
    }

    package var acceptsNewWork: Bool {
        admissionIsOpen
    }

    package var activeOrdinals: [UInt64] {
        registeredTasks.keys.sorted()
    }

    package func register(_ kind: ReviewStoreWorkKind) -> Admission? {
        guard admissionIsOpen else {
            return nil
        }
        guard nextWorkOrdinal < UInt64.max else {
            preconditionFailure("ReviewStoreWorkRegistry work ordinal exhausted.")
        }
        nextWorkOrdinal += 1
        return .init(ordinal: nextWorkOrdinal, kind: kind)
    }

    package func install<Success: Sendable, Failure: Error>(
        _ task: Task<Success, Failure>,
        for admission: Admission
    ) {
        precondition(
            registeredTasks[admission.ordinal] == nil,
            "ReviewStoreWorkRegistry owns exactly one Task for each admitted ordinal."
        )
        registeredTasks[admission.ordinal] = .init(
            admission: admission,
            task: task
        )
    }

    package func finish(_ admission: Admission) {
        registeredTasks.removeValue(forKey: admission.ordinal)
    }

    package func beginClosing(
        onAdmissionClosed: () -> Void,
        beforeTaskCancellation: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> CloseOperation {
        switch state {
        case .open:
            admissionIsOpen = false
            onAdmissionClosed()
            let tasks = registeredTasks.values.sorted {
                $0.admission.ordinal < $1.admission.ordinal
            }
            guard nextCloseID < UInt64.max else {
                preconditionFailure("ReviewStoreWorkRegistry close ordinal exhausted.")
            }
            nextCloseID += 1
            let operation = CloseOperation(
                id: nextCloseID,
                task: Task { @MainActor in
                    await beforeTaskCancellation()
                    for task in tasks {
                        task.cancel()
                    }
                    var failures: [ReviewStoreWorkFailure] = []
                    for task in tasks {
                        if let failure = await task.waitForFailure() {
                            failures.append(failure)
                        }
                    }
                    guard let first = failures.first else {
                        return .success
                    }
                    return .init(failures: .init(
                        first: first,
                        additionalInOrdinalOrder: Array(failures.dropFirst())
                    ))
                }
            )
            closeTaskCreationCount += 1
            state = .closing(operation)
            return operation

        case .closing(let operation):
            return operation

        case .closed(let operation, _):
            return operation
        }
    }

    package func completeClosing(
        _ operation: CloseOperation,
        result: ReviewStoreWorkDrainResult
    ) {
        switch state {
        case .closing(let current) where current.id == operation.id:
            registeredTasks.removeAll(keepingCapacity: false)
            state = .closed(current, result)
        case .closed(let current, _) where current.id == operation.id:
            break
        case .open, .closing, .closed:
            preconditionFailure(
                "ReviewStoreWorkRegistry must complete its one recorded close operation."
            )
        }
    }

    package func cancelWithoutWaiting() {
        admissionIsOpen = false
        for task in registeredTasks.values {
            task.cancel()
        }
    }
}
