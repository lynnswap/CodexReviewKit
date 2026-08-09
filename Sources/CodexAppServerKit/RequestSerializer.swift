import Foundation
import Synchronization

package final class RequestOperationState: Sendable {
    package enum PostWriteCallerCancellationPolicy: Equatable, Sendable {
        case performCleanup
        case returnResponse
    }

    package enum ResponseDisposition: Sendable {
        case returnResponse
        case performCleanup(RequestOperationAbandonment)
    }

    package enum DeadlineDisposition: Sendable {
        case ignored
        case awaitPreWriteExit
        case closeConnection
    }

    private enum Phase: Sendable {
        case preWrite
        case written
        case retryWaiting
        case retryReady
        case responseBound
        case cleanupComplete
        case returned
    }

    private struct State: Sendable {
        var phase: Phase = .preWrite
        var abandonment: RequestOperationAbandonment?
        var abandonmentWaiters: [
            UUID: CheckedContinuation<RequestOperationAbandonment?, Never>
        ] = [:]
    }

    private let state = Mutex(State())

    package init() {}

    package func requestCancellation() {
        let waiters = state.withLock { state -> [
            CheckedContinuation<RequestOperationAbandonment?, Never>
        ] in
            guard state.phase != .returned, state.phase != .cleanupComplete,
                  state.abandonment == nil else {
                return []
            }
            state.abandonment = .callerCancellation
            defer { state.abandonmentWaiters.removeAll(keepingCapacity: false) }
            return Array(state.abandonmentWaiters.values)
        }
        for waiter in waiters {
            waiter.resume(returning: .callerCancellation)
        }
    }

    package func requestDeadline() -> DeadlineDisposition {
        let result = state.withLock { state -> (
            DeadlineDisposition,
            [CheckedContinuation<RequestOperationAbandonment?, Never>]
        ) in
            guard state.phase != .returned, state.phase != .cleanupComplete,
                  state.abandonment == nil else {
                return (.ignored, [])
            }
            state.abandonment = .deadline
            let disposition: DeadlineDisposition = switch state.phase {
            case .preWrite:
                .awaitPreWriteExit
            case .written:
                .closeConnection
            case .retryWaiting, .retryReady:
                .awaitPreWriteExit
            case .responseBound:
                .awaitPreWriteExit
            case .cleanupComplete, .returned:
                .ignored
            }
            defer { state.abandonmentWaiters.removeAll(keepingCapacity: false) }
            return (disposition, Array(state.abandonmentWaiters.values))
        }
        for waiter in result.1 {
            waiter.resume(returning: .deadline)
        }
        return result.0
    }

    package func acceptWrite() throws {
        let abandonment = state.withLock { state -> RequestOperationAbandonment? in
            switch state.phase {
            case .preWrite, .retryReady:
                if let abandonment = state.abandonment {
                    return abandonment
                }
                state.phase = .written
                return nil
            case .written, .retryWaiting, .responseBound, .cleanupComplete, .returned:
                preconditionFailure("A request cannot write after binding its response.")
            }
        }
        if let abandonment {
            throw abandonment
        }
    }

    package func beginRetryWait() throws {
        let abandonment = state.withLock { state -> RequestOperationAbandonment? in
            precondition(state.phase == .written, "A retry wait requires a correlated response.")
            state.phase = .retryWaiting
            return state.abandonment
        }
        if let abandonment {
            throw abandonment
        }
    }

    package func finishRetryWait() throws {
        let abandonment = state.withLock { state -> RequestOperationAbandonment? in
            precondition(state.phase == .retryWaiting, "Only a waiting retry can become ready.")
            if let abandonment = state.abandonment {
                return abandonment
            }
            state.phase = .retryReady
            return nil
        }
        if let abandonment {
            throw abandonment
        }
    }

    package func waitForAbandonment() async -> RequestOperationAbandonment? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let abandonment = state.withLock { state -> RequestOperationAbandonment? in
                    if let abandonment = state.abandonment {
                        return abandonment
                    }
                    state.abandonmentWaiters[waiterID] = continuation
                    return nil
                }
                if let abandonment {
                    continuation.resume(returning: abandonment)
                }
            }
        } onCancel: {
            cancelAbandonmentWaiter(waiterID)
        }
    }

    private func cancelAbandonmentWaiter(_ waiterID: UUID) {
        let waiter = state.withLock { state in
            state.abandonmentWaiters.removeValue(forKey: waiterID)
        }
        waiter?.resume(returning: nil)
    }

    package func markResponseBound() {
        state.withLock { state in
            precondition(state.phase == .written, "A response can only bind after write acceptance.")
            state.phase = .responseBound
        }
    }

    package func resolveResponse(
        postWriteCallerCancellationPolicy: PostWriteCallerCancellationPolicy
    ) -> ResponseDisposition {
        state.withLock { state in
            precondition(state.phase == .responseBound, "A request response must be bound before resolution.")
            if let abandonment = state.abandonment {
                if abandonment == .callerCancellation,
                   postWriteCallerCancellationPolicy == .returnResponse {
                    state.phase = .returned
                    return .returnResponse
                }
                return .performCleanup(abandonment)
            }
            state.phase = .returned
            return .returnResponse
        }
    }

    package func markCleanupComplete() {
        state.withLock { state in
            precondition(state.phase == .responseBound, "Cancellation cleanup requires a bound response.")
            precondition(state.abandonment != nil, "Request cleanup requires operation abandonment.")
            state.phase = .cleanupComplete
        }
    }

    package func preWriteCancellationShouldWin() -> Bool {
        state.withLock { state in
            (state.phase == .preWrite || state.phase == .retryReady)
                && state.abandonment == .callerCancellation
        }
    }
}

package enum RequestOperationAbandonment: Error, Equatable, Sendable {
    case callerCancellation
    case deadline
}

package actor RequestSerializer {
    private struct Lane {
        var activeTokenID: UUID
        var waiters: [RequestLaneWaiter]
    }

    package struct LaneToken: Sendable {
        var scope: AppServerAPI.RequestScope
        var id: UUID
    }

    @TaskLocal private static var currentCleanupLaneToken: LaneToken?

    private var lanes: [AppServerAPI.RequestScope: Lane] = [:]
    private var queueCountWaiters: [AppServerAPI.RequestScope: [RequestQueueCountWaiter]] = [:]

    package init() {}

    package func run<Output: Sendable>(
        scope: AppServerAPI.RequestScope?,
        operation: @Sendable (LaneToken?) async throws -> Output
    ) async throws -> Output {
        guard let scope else {
            try Task.checkCancellation()
            return try await operation(nil)
        }
        if let cleanupToken = Self.currentCleanupLaneToken,
           cleanupToken.scope == scope,
           lanes[scope]?.activeTokenID == cleanupToken.id {
            return try await operation(cleanupToken)
        }

        let token = try await enter(scope: scope)
        do {
            try Task.checkCancellation()
            let output = try await operation(token)
            leave(token)
            return output
        } catch {
            leave(token)
            throw error
        }
    }

    package func runCleanup<Output: Sendable>(
        using token: LaneToken?,
        operation: @Sendable () async throws -> Output
    ) async throws -> Output {
        guard let token else {
            return try await operation()
        }
        precondition(
            lanes[token.scope]?.activeTokenID == token.id,
            "Request cleanup requires its active request lane token."
        )
        return try await Self.$currentCleanupLaneToken.withValue(token) {
            try await operation()
        }
    }

    package func laneCountForTesting() -> Int {
        lanes.count
    }

    package func queuedWaiterCountForTesting(
        scope: AppServerAPI.RequestScope
    ) -> Int {
        queuedWaiterCount(scope: scope)
    }

    package func waitForQueuedWaiterCountForTesting(
        scope: AppServerAPI.RequestScope,
        atLeast minimumCount: Int
    ) async throws {
        precondition(minimumCount >= 0, "A request queue count cannot be negative.")
        guard queuedWaiterCount(scope: scope) < minimumCount else {
            return
        }
        let waiter = RequestQueueCountWaiter(minimumCount: minimumCount)
        queueCountWaiters[scope, default: []].append(waiter)
        let satisfied = await waiter.wait()
        guard satisfied, Task.isCancelled == false else {
            removeQueueCountWaiter(waiter.id, scope: scope)
            throw CancellationError()
        }
    }

    private func enter(scope: AppServerAPI.RequestScope) async throws -> LaneToken {
        try Task.checkCancellation()
        guard lanes[scope] != nil else {
            let token = LaneToken(scope: scope, id: UUID())
            lanes[scope] = Lane(activeTokenID: token.id, waiters: [])
            return token
        }

        let waiter = RequestLaneWaiter()
        lanes[scope]?.waiters.append(waiter)
        resumeSatisfiedQueueCountWaiters(scope: scope)
        let acquired = await waiter.wait()
        guard acquired else {
            removeWaiter(waiter.id, scope: scope)
            throw CancellationError()
        }

        let token = LaneToken(scope: scope, id: waiter.id)
        if Task.isCancelled {
            leave(token)
            throw CancellationError()
        }
        return token
    }

    private func leave(_ token: LaneToken) {
        guard var lane = lanes[token.scope] else {
            preconditionFailure("Request lane disappeared while occupied.")
        }
        precondition(
            lane.activeTokenID == token.id,
            "Only the active request operation can release its lane."
        )

        while lane.waiters.isEmpty == false {
            let waiter = lane.waiters.removeFirst()
            if waiter.acquire() {
                lane.activeTokenID = waiter.id
                lanes[token.scope] = lane
                resumeSatisfiedQueueCountWaiters(scope: token.scope)
                return
            }
        }
        lanes.removeValue(forKey: token.scope)
        resumeSatisfiedQueueCountWaiters(scope: token.scope)
    }

    private func removeWaiter(_ waiterID: UUID, scope: AppServerAPI.RequestScope) {
        guard var lane = lanes[scope] else {
            return
        }
        lane.waiters.removeAll { $0.id == waiterID }
        lanes[scope] = lane
        resumeSatisfiedQueueCountWaiters(scope: scope)
    }

    private func queuedWaiterCount(scope: AppServerAPI.RequestScope) -> Int {
        lanes[scope]?.waiters.filter(\.isPending).count ?? 0
    }

    private func resumeSatisfiedQueueCountWaiters(scope: AppServerAPI.RequestScope) {
        guard let waiters = queueCountWaiters[scope] else {
            return
        }
        let count = queuedWaiterCount(scope: scope)
        var remaining: [RequestQueueCountWaiter] = []
        for waiter in waiters {
            if count >= waiter.minimumCount {
                waiter.satisfy()
            } else if waiter.isPending {
                remaining.append(waiter)
            }
        }
        if remaining.isEmpty {
            queueCountWaiters.removeValue(forKey: scope)
        } else {
            queueCountWaiters[scope] = remaining
        }
    }

    private func removeQueueCountWaiter(_ waiterID: UUID, scope: AppServerAPI.RequestScope) {
        guard var waiters = queueCountWaiters[scope] else {
            return
        }
        waiters.removeAll { $0.id == waiterID }
        if waiters.isEmpty {
            queueCountWaiters.removeValue(forKey: scope)
        } else {
            queueCountWaiters[scope] = waiters
        }
    }
}

private final class RequestQueueCountWaiter: Sendable {
    private enum State: Sendable {
        case idle
        case waiting(CheckedContinuation<Bool, Never>)
        case satisfied
        case cancelled
    }

    let id = UUID()
    let minimumCount: Int
    private let state = Mutex(State.idle)

    init(minimumCount: Int) {
        self.minimumCount = minimumCount
    }

    var isPending: Bool {
        state.withLock { state in
            switch state {
            case .idle, .waiting:
                true
            case .satisfied, .cancelled:
                false
            }
        }
    }

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Bool? in
                    switch state {
                    case .idle:
                        if Task.isCancelled {
                            state = .cancelled
                            return false
                        }
                        state = .waiting(continuation)
                        return nil
                    case .satisfied:
                        return true
                    case .cancelled:
                        return false
                    case .waiting:
                        preconditionFailure("A queue-count waiter can only be awaited once.")
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func satisfy() {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            switch state {
            case .idle:
                state = .satisfied
                return nil
            case .waiting(let continuation):
                state = .satisfied
                return continuation
            case .satisfied, .cancelled:
                return nil
            }
        }
        continuation?.resume(returning: true)
    }

    private func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            switch state {
            case .idle:
                state = .cancelled
                return nil
            case .waiting(let continuation):
                state = .cancelled
                return continuation
            case .satisfied, .cancelled:
                return nil
            }
        }
        continuation?.resume(returning: false)
    }
}

private final class RequestLaneWaiter: Sendable {
    private enum State: Sendable {
        case idle
        case waiting(CheckedContinuation<Bool, Never>)
        case acquired
        case cancelled
    }

    let id = UUID()
    private let state = Mutex(State.idle)

    var isPending: Bool {
        state.withLock { state in
            switch state {
            case .idle, .waiting:
                true
            case .acquired, .cancelled:
                false
            }
        }
    }

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Bool? in
                    switch state {
                    case .idle:
                        if Task.isCancelled {
                            state = .cancelled
                            return false
                        }
                        state = .waiting(continuation)
                        return nil
                    case .acquired:
                        return true
                    case .cancelled:
                        return false
                    case .waiting:
                        preconditionFailure("A request lane waiter can only be awaited once.")
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func acquire() -> Bool {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            switch state {
            case .idle:
                state = .acquired
                return nil
            case .waiting(let continuation):
                state = .acquired
                return continuation
            case .cancelled:
                return nil
            case .acquired:
                preconditionFailure("A request lane waiter can only acquire once.")
            }
        }
        continuation?.resume(returning: true)
        return state.withLock { state in
            if case .acquired = state {
                true
            } else {
                false
            }
        }
    }

    private func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            switch state {
            case .idle:
                state = .cancelled
                return nil
            case .waiting(let continuation):
                state = .cancelled
                return continuation
            case .acquired, .cancelled:
                return nil
            }
        }
        continuation?.resume(returning: false)
    }
}
