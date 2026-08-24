package struct StoreReviewActiveAttempt: Sendable {
    package let attempt: BackendReviewAttempt
    package let admission: ReviewStartAdmission
    package var run: CodexReviewBackendModel.Review.Run { attempt.run }
    package init(attempt: BackendReviewAttempt, admission: ReviewStartAdmission) {
        self.attempt = attempt
        self.admission = admission
    }
    package func matches(_ other: Self) -> Bool {
        run == other.run
            && attempt.events === other.attempt.events
            && admission === other.admission
    }
}
/// Store must retain this receipt until it reaches a joined finish or suppression.
/// `isolated deinit` sends cancellation only as a synchronous misuse backstop; it
/// cannot replace joining the owned task and discarding its exact backend resource.
@MainActor
package final class StoreReviewRecoveryReceipt {
    package enum Operation {
        case disposition
        case preparation
        case staging(ReviewStartAdmission)
    }
    package enum Transition: Sendable {
        case disposition(Result<ReviewRecoveryDisposition, any Error>)
        case prepared(Result<PreparedReviewRecovery, any Error>)
        case staged(Result<StagedReviewRecovery, any Error>)
    }
    package enum Completion {
        case disposition(ReviewRecoveryDisposition)
        case prepared(PreparedReviewRecovery)
        case staged(StagedReviewRecovery)
    }
    package enum DiscardTarget {
        case source(StoreReviewActiveAttempt)
        case prepared(PreparedReviewRecovery)
        case staged(StagedReviewRecovery)
    }
    private enum Phase {
        case source
        case disposition(ReviewRecoveryDisposition)
        case prepared(PreparedReviewRecovery)
        case staged(StagedReviewRecovery)
        case failed, finished, suppressed
    }
    package let source: StoreReviewActiveAttempt
    private var phase: Phase = .source
    private var ownedOperation: (Operation, Task<Transition, Never>)?
    private var joinIsReserved = false
    private var cancellation: ReviewCancellation?
    package init(source: StoreReviewActiveAttempt) {
        self.source = source
    }
    isolated deinit {
        ownedOperation?.1.cancel()
    }
    package func start(
        _ operation: Operation,
        work: @escaping @MainActor @Sendable () async -> Transition
    ) throws {
        guard ownedOperation == nil, joinIsReserved == false, cancellation == nil else {
            throw contractFailure("start concurrent operation")
        }
        switch (operation, phase) {
        case (.disposition, .source),
             (.preparation, .disposition(.replacement)),
             (.staging, .prepared):
            ownedOperation = (operation, Task { @MainActor in await work() })
        case (.disposition, _), (.preparation, _), (.staging, _):
            throw contractFailure("start operation")
        }
    }
    package func cancelOwnedOperation(_ cancellation: ReviewCancellation) -> Task<Void, Never> {
        let cancellation = self.cancellation ?? cancellation
        self.cancellation = cancellation
        let admission = cancellationAdmission()
        let task = ownedOperation?.1
        return Task { @MainActor in
            await admission.recordCancellation(cancellation)
            task?.cancel()
        }
    }
    package func joinOwnedOperation() throws -> Task<Completion, any Error> {
        guard joinIsReserved == false else {
            throw contractFailure("join concurrent operation")
        }
        guard let (operation, task) = ownedOperation else { throw contractFailure("join operation") }
        joinIsReserved = true
        return Task { @MainActor in
            let transition = await task.value
            return try await completeJoin(operation, transition: transition)
        }
    }
    private func completeJoin(
        _ operation: Operation,
        transition: Transition
    ) async throws -> Completion {
        defer { joinIsReserved = false }
        ownedOperation = nil
        switch (operation, transition) {
        case (.disposition, .disposition(let result)):
            phase = .source
            let disposition = try result.get()
            guard disposition.resolved.run == source.run else {
                throw contractFailure("finish disposition")
            }
            if cancellation != nil { throw CancellationError() }
            phase = .disposition(disposition)
            return .disposition(disposition)
        case (.preparation, .prepared(let result)):
            let candidate = try replacementCandidate()
            phase = .failed
            let prepared = try result.get()
            phase = .prepared(prepared)
            guard prepared.receipt.sourceRun == source.run,
                  prepared.handoff.candidate == candidate else {
                throw contractFailure("finish preparation")
            }
            if cancellation != nil { throw CancellationError() }
            return .prepared(prepared)
        case (.staging(let destinationAdmission), .staged(let result)):
            let prepared = try preparedRecovery()
            phase = .failed
            let staged = try result.get()
            phase = .staged(staged)
            guard staged.receipt === prepared.receipt,
                  staged.admission === destinationAdmission,
                  cancellation == nil,
                  await staged.admission.permitsRecoveryPublication(of: staged.attempt.run),
                  cancellation == nil else {
                throw contractFailure("finish staging")
            }
            return .staged(staged)
        default:
            phase = .failed
            throw contractFailure("finish mismatched operation")
        }
    }
    package func suppress() throws -> DiscardTarget? {
        guard ownedOperation == nil, joinIsReserved == false else {
            throw contractFailure("discard before joining operation")
        }
        let target: DiscardTarget?
        switch phase {
        case .source, .disposition: target = .source(source)
        case .prepared(let value): target = .prepared(value)
        case .staged(let value): target = .staged(value)
        case .failed: target = nil
        case .finished, .suppressed: throw contractFailure("discard terminal receipt")
        }
        phase = .suppressed
        return target
    }
    package func finish(_ staged: StagedReviewRecovery) throws -> StoreReviewActiveAttempt {
        guard ownedOperation == nil, joinIsReserved == false, cancellation == nil,
              case .staged(let current) = phase,
              current === staged else { throw contractFailure("finish receipt") }
        phase = .finished
        return .init(attempt: staged.attempt, admission: staged.admission)
    }
    private func cancellationAdmission() -> ReviewStartAdmission {
        if case .staging(let admission) = ownedOperation?.0 { return admission }
        if case .staged(let staged) = phase { return staged.admission }
        return source.admission
    }
    private func replacementCandidate() throws -> ReviewRecoveryCandidate {
        guard case .disposition(.replacement(let value)) = phase else {
            throw contractFailure("finish preparation")
        }
        return value
    }
    private func preparedRecovery() throws -> PreparedReviewRecovery {
        guard case .prepared(let value) = phase else {
            throw contractFailure("finish staging")
        }
        return value
    }
    private func contractFailure(_ operation: String) -> ReviewAttemptContractFailure {
        .init(message: "Store recovery receipt cannot \(operation) in its current state.")
    }
}
