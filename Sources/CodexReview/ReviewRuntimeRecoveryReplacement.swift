import Foundation
import Synchronization

@MainActor
package final class ReviewRuntimeRecoveryReplacement {
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
    private var publishedRuntime: PreparedRuntime?
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

    package func takeRetiringRuntime() -> PreparedRuntime? {
        defer { retiringRuntime = nil }
        return retiringRuntime
    }

    package func installPublishedRuntime(_ runtime: PreparedRuntime) {
        precondition(
            publishedRuntime == nil,
            "ReviewRuntimeRecoveryReplacement owns at most one published runtime before transfer."
        )
        publishedRuntime = runtime
    }

    package func closePublishedRuntimeAdmission() {
        publishedRuntime?.handle.closeAdmission()
    }

    package func takePublishedRuntime() -> PreparedRuntime? {
        defer { publishedRuntime = nil }
        return publishedRuntime
    }

    package func ownsPublishedRuntime(
        handle: any RuntimeLifecycleHandle
    ) -> Bool {
        publishedRuntime?.handle === handle
    }

    package func sourceCloseResults() -> AsyncStream<SourceCloseResult> {
        sourceCloseResultOwner.values()
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

    func finish(_ value: Value) {
        let continuations = state.withLock { state -> [Continuation] in
            guard state.value == nil else {
                return []
            }
            state.value = value
            defer { state.continuations.removeAll(keepingCapacity: false) }
            return Array(state.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(value)
            continuation.finish()
        }
    }

    private func removeContinuation(id: UUID) {
        _ = state.withLock { state in
            state.continuations.removeValue(forKey: id)
        }
    }
}
