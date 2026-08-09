import Foundation
import Synchronization

package final class FetchedResultsLoadCoordinator: Sendable {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var activeID: UUID?
        var waiters: [Waiter] = []
        var cancelledBeforeRegistration: Set<UUID> = []
        var pendingLoadWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    package init() {}

    package func waitUntilPendingLoad() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard state.waiters.isEmpty else {
                    state.pendingLoadWaiters.append(continuation)
                    return false
                }
                return true
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    package func withPermit<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        let id = UUID()
        try await acquire(id: id)
        defer {
            release(id: id)
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(id: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: (ResumeAction, [CheckedContinuation<Void, Never>]) = state.withLock {
                    state in
                    if state.cancelledBeforeRegistration.remove(id) != nil {
                        return (.cancelled(continuation), [])
                    }
                    guard state.activeID != nil else {
                        state.activeID = id
                        return (.acquired(continuation), [])
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    let pendingLoadWaiters = state.pendingLoadWaiters
                    state.pendingLoadWaiters.removeAll(keepingCapacity: false)
                    return (.pending, pendingLoadWaiters)
                }
                result.0.resume()
                for waiter in result.1 {
                    waiter.resume()
                }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    private func cancel(id: UUID) {
        let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
            if state.activeID == id {
                return nil
            }
            if let index = state.waiters.firstIndex(where: { $0.id == id }) {
                return state.waiters.remove(at: index).continuation
            }
            state.cancelledBeforeRegistration.insert(id)
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func release(id: UUID) {
        let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
            precondition(
                state.activeID == id,
                "FetchedResultsLoadCoordinator released a non-active permit."
            )
            guard state.waiters.isEmpty == false else {
                state.activeID = nil
                return nil
            }
            let waiter = state.waiters.removeFirst()
            state.activeID = waiter.id
            return waiter.continuation
        }
        continuation?.resume()
    }

    private enum ResumeAction {
        case acquired(CheckedContinuation<Void, any Error>)
        case cancelled(CheckedContinuation<Void, any Error>)
        case pending

        func resume() {
            switch self {
            case .acquired(let continuation):
                continuation.resume()
            case .cancelled(let continuation):
                continuation.resume(throwing: CancellationError())
            case .pending:
                break
            }
        }
    }
}
