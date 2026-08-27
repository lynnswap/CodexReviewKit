import Foundation
import Synchronization

@MainActor
package final class ReviewRuntimeRecoveryReplacement {
    package struct SemanticStop {
        package let context: ReviewRuntimeSemanticStopContext
        package let intent: ReviewRuntimeTeardownIntent
    }

    package struct SourceCloseJoin: Sendable {
        fileprivate let waiter: ReviewRuntimeRecoveryJoinWaiter<SourceCloseResult>

        package func value() async -> SourceCloseResult {
            await waiter.value()
        }
    }

    private enum PublishedRuntimeOwnership {
        case awaitingInstallation
        case installed(PreparedRuntime)
        case transferred
    }

    package enum Outcome: Equatable, Sendable {
        case running(ReviewRuntimeGeneration)
        case failed(String)
        case superseded(ReviewRuntimeTransitionPurpose)
    }

    package enum SourceCloseResult: Equatable, Sendable {
        case closed
        case failed(ReviewRuntimeCloseFailure)
    }

    package let sourceGeneration: ReviewRuntimeGeneration
    package let replacementGeneration: ReviewRuntimeGeneration
    package let retainedMCP: RetainedMCPServer

    private var retiringRuntime: PreparedRuntime?
    private var retiringSemanticStop: SemanticStop?
    private var publishedRuntimeOwnership: PublishedRuntimeOwnership = .awaitingInstallation
    private var sourceCloseFailureWasConsumed = false
    private let outcomeOwner = ReviewRuntimeRecoveryReplayOwner<Outcome>()
    private let sourceCloseResultOwner = ReviewRuntimeRecoveryReplayOwner<SourceCloseResult>()

    package init(
        sourceGeneration: ReviewRuntimeGeneration,
        retiringRuntime: PreparedRuntime?,
        retainedMCP: RetainedMCPServer
    ) {
        self.sourceGeneration = sourceGeneration
        self.replacementGeneration = sourceGeneration.successor()
        self.retiringRuntime = retiringRuntime
        self.retainedMCP = retainedMCP
    }

    package func installRetiringSemanticStop(
        context: ReviewRuntimeSemanticStopContext,
        intent: ReviewRuntimeTeardownIntent
    ) {
        precondition(
            retiringSemanticStop == nil,
            "ReviewRuntimeRecoveryReplacement owns at most one transferred retiring semantic stop."
        )
        retiringSemanticStop = .init(context: context, intent: intent)
    }

    package func takeRetiringRuntime() -> (PreparedRuntime, SemanticStop?)? {
        guard let retiringRuntime else { return nil }
        defer {
            self.retiringRuntime = nil
            retiringSemanticStop = nil
        }
        return (retiringRuntime, retiringSemanticStop)
    }

    package func installPublishedRuntime(_ runtime: PreparedRuntime) {
        guard case .awaitingInstallation = publishedRuntimeOwnership else {
            preconditionFailure(
                "ReviewRuntimeRecoveryReplacement installs exactly one published runtime before transfer."
            )
        }
        publishedRuntimeOwnership = .installed(runtime)
    }

    package func closePublishedRuntimeAdmission() {
        guard case .installed(let runtime) = publishedRuntimeOwnership else {
            return
        }
        runtime.handle.closeAdmission()
    }

    package func takePublishedRuntime() -> PreparedRuntime? {
        switch publishedRuntimeOwnership {
        case .awaitingInstallation:
            publishedRuntimeOwnership = .transferred
            return nil
        case .installed(let runtime):
            publishedRuntimeOwnership = .transferred
            return runtime
        case .transferred:
            return nil
        }
    }

    package func ownsPublishedRuntime(
        handle: any RuntimeLifecycleHandle
    ) -> Bool {
        guard case .installed(let runtime) = publishedRuntimeOwnership else {
            return false
        }
        return runtime.handle === handle
    }

    package func sourceCloseResults() -> AsyncStream<SourceCloseResult> {
        sourceCloseResultOwner.values()
    }

    package func sourceCloseJoin() -> SourceCloseJoin {
        .init(waiter: sourceCloseResultOwner.makeJoin())
    }

    package func finishSourceClose(_ result: SourceCloseResult) {
        sourceCloseResultOwner.finish(result)
    }

    package func consumeSourceCloseFailure() -> ReviewRuntimeCloseFailure? {
        guard sourceCloseFailureWasConsumed == false,
              case .failed(let failure) = sourceCloseResultOwner.value
        else {
            return nil
        }
        sourceCloseFailureWasConsumed = true
        return failure
    }

    package func outcomes() -> AsyncStream<Outcome> {
        outcomeOwner.values()
    }

    package func finish(_ outcome: Outcome) {
        outcomeOwner.finish(outcome)
    }

    package var pendingOutcomeWaiterCount: Int {
        outcomeOwner.waiterCount
    }
}

private final class ReviewRuntimeRecoveryReplayOwner<Value: Sendable>: Sendable {
    typealias Continuation = AsyncStream<Value>.Continuation

    private struct State: Sendable {
        var value: Value?
        var continuations: [UUID: Continuation] = [:]
        var joiners: [ReviewRuntimeRecoveryJoinWaiter<Value>] = []
    }

    private let state = Mutex(State())

    var waiterCount: Int {
        state.withLock { $0.continuations.count }
    }

    var value: Value? {
        state.withLock { $0.value }
    }

    func values() -> AsyncStream<Value> {
        let continuationID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: continuationID)
            }
            let value = state.withLock { state -> Value? in
                guard let value = state.value else {
                    state.continuations[continuationID] = continuation
                    return nil
                }
                return value
            }
            if let value {
                continuation.yield(value)
                continuation.finish()
            }
        }
    }

    func makeJoin() -> ReviewRuntimeRecoveryJoinWaiter<Value> {
        let joiner = ReviewRuntimeRecoveryJoinWaiter<Value>()
        let value = state.withLock { state -> Value? in
            guard let value = state.value else {
                state.joiners.append(joiner)
                return nil
            }
            return value
        }
        if let value {
            joiner.finish(value)
        }
        return joiner
    }

    func finish(_ value: Value) {
        let continuations = state.withLock { state -> (
            streams: [Continuation],
            joiners: [ReviewRuntimeRecoveryJoinWaiter<Value>]
        ) in
            guard state.value == nil else {
                return ([], [])
            }
            state.value = value
            defer {
                state.continuations.removeAll(keepingCapacity: false)
                state.joiners.removeAll(keepingCapacity: false)
            }
            return (
                Array(state.continuations.values),
                state.joiners
            )
        }
        for continuation in continuations.streams {
            continuation.yield(value)
            continuation.finish()
        }
        for joiner in continuations.joiners {
            joiner.finish(value)
        }
    }

    private func removeContinuation(id: UUID) {
        _ = state.withLock { state in
            state.continuations.removeValue(forKey: id)
        }
    }
}

private final class ReviewRuntimeRecoveryJoinWaiter<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var value: Value?
        var continuations: [CheckedContinuation<Value, Never>] = []
    }

    private let state = Mutex(State())

    func finish(_ value: Value) {
        let continuations = state.withLock { state -> [CheckedContinuation<Value, Never>] in
            guard state.value == nil else {
                return []
            }
            state.value = value
            defer { state.continuations.removeAll(keepingCapacity: false) }
            return state.continuations
        }
        for continuation in continuations {
            continuation.resume(returning: value)
        }
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let value = state.withLock { state -> Value? in
                guard let value = state.value else {
                    state.continuations.append(continuation)
                    return nil
                }
                return value
            }
            if let value {
                continuation.resume(returning: value)
            }
        }
    }
}
