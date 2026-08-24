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

/// Store must retain this receipt through a joined suppression or committed
/// promotion. `isolated deinit` cancels only as a synchronous misuse backstop;
/// it cannot join work or discard an exact backend resource.
@MainActor
package final class StoreReviewRecoveryReceipt {
    package enum Completion {
        case disposition(ReviewRecoveryDisposition)
        case prepared(PreparedReviewRecovery)
        case staged(StagedReviewRecovery)
        case committed(StagedReviewRecovery)
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
        case preparedForDiscard(PreparedReviewRecovery)
        case staged(StagedReviewRecovery)
        case stagedForDiscard(StagedReviewRecovery)
        case committed(StagedReviewRecovery)
        case failed, finished, suppressed
    }
    private enum OwnedOperation {
        case disposition(Task<ReviewRecoveryDisposition, any Error>)
        case preparation(
            ReviewRecoveryCandidate,
            Task<PreparedReviewRecovery, any Error>
        )
        case staging(
            PreparedReviewRecovery,
            ReviewStartAdmission,
            Task<StagedReviewRecovery, any Error>
        )
        case commit(StagedReviewRecovery, Task<Void, any Error>)

        func cancel() {
            switch self {
            case .disposition(let task): task.cancel()
            case .preparation(_, let task): task.cancel()
            case .staging(_, _, let task): task.cancel()
            case .commit(_, let task): task.cancel()
            }
        }
    }

    package let source: StoreReviewActiveAttempt
    private var phase: Phase = .source
    private var ownedOperation: OwnedOperation?
    private var joinIsReserved = false
    private var cancellation: ReviewCancellation?

    package init(source: StoreReviewActiveAttempt) {
        self.source = source
    }
    isolated deinit {
        ownedOperation?.cancel()
    }

    package func startDisposition(
        _ work: @escaping @MainActor @Sendable () async throws -> ReviewRecoveryDisposition
    ) throws {
        try requireStart("disposition")
        guard case .source = phase else { throw contractFailure("start disposition") }
        ownedOperation = .disposition(Task { @MainActor in try await work() })
    }

    package func startPreparation(
        _ work: @escaping @MainActor @Sendable () async throws -> PreparedReviewRecovery
    ) throws {
        try requireStart("preparation")
        guard case .disposition(.replacement(let candidate)) = phase else {
            throw contractFailure("start preparation")
        }
        ownedOperation = .preparation(
            candidate,
            Task { @MainActor in try await work() }
        )
    }

    package func startStaging(
        admission: ReviewStartAdmission,
        _ work: @escaping @MainActor @Sendable () async throws(ReviewRecoveryStagingFailure) -> StagedReviewRecovery
    ) throws {
        try requireStart("staging")
        guard case .prepared(let prepared) = phase else {
            throw contractFailure("start staging")
        }
        ownedOperation = .staging(
            prepared,
            admission,
            Task { @MainActor in try await work() }
        )
    }

    package func startCommit(
        _ work: @escaping @MainActor @Sendable (StagedReviewRecovery) async throws -> Void
    ) throws {
        try requireStart("commit")
        guard case .staged(let staged) = phase else {
            throw contractFailure("start commit")
        }
        ownedOperation = .commit(
            staged,
            Task { @MainActor in try await work(staged) }
        )
    }

    package func cancelOwnedOperation(_ requested: ReviewCancellation) -> Task<Void, Never> {
        let cancellation = cancellation ?? requested
        self.cancellation = cancellation
        let operation = ownedOperation
        let admission = cancellationAdmission(for: operation)
        return Task { @MainActor in
            await admission.recordCancellation(cancellation)
            operation?.cancel()
        }
    }

    package func joinOwnedOperation() throws -> Task<Completion, any Error> {
        guard joinIsReserved == false else { throw contractFailure("join concurrent operation") }
        guard let operation = ownedOperation else { throw contractFailure("join operation") }
        joinIsReserved = true
        return Task { @MainActor in try await self.completeJoin(operation) }
    }

    package func suppress() throws -> DiscardTarget? {
        guard ownedOperation == nil, joinIsReserved == false else {
            throw contractFailure("discard before joining operation")
        }
        let target: DiscardTarget?
        switch phase {
        case .source, .disposition: target = .source(source)
        case .prepared(let prepared), .preparedForDiscard(let prepared):
            target = .prepared(prepared)
        case .staged(let staged), .stagedForDiscard(let staged):
            target = .staged(staged)
        case .failed: target = nil
        case .committed: throw contractFailure("discard committed recovery before promotion")
        case .finished, .suppressed: throw contractFailure("discard terminal receipt")
        }
        phase = .suppressed
        return target
    }

    package func finishCommitted() throws -> StoreReviewActiveAttempt {
        guard ownedOperation == nil, joinIsReserved == false,
              case .committed(let staged) = phase else {
            throw contractFailure("finish uncommitted receipt")
        }
        phase = .finished
        return .init(attempt: staged.attempt, admission: staged.admission)
    }

    private func completeJoin(_ operation: OwnedOperation) async throws -> Completion {
        defer { joinIsReserved = false }
        switch operation {
        case .disposition(let task):
            phase = .source
            do {
                let disposition = try await task.value
                ownedOperation = nil
                guard disposition.resolved.run == source.run else {
                    throw contractFailure("finish disposition")
                }
                if cancellation != nil { throw CancellationError() }
                phase = .disposition(disposition)
                return .disposition(disposition)
            } catch {
                ownedOperation = nil
                throw error
            }
        case .preparation(let candidate, let task):
            do {
                let prepared = try await task.value
                ownedOperation = nil
                phase = .preparedForDiscard(prepared)
                guard prepared.receipt.sourceRun == source.run,
                      prepared.handoff.candidate == candidate else {
                    throw contractFailure("finish preparation")
                }
                phase = .prepared(prepared)
                if cancellation != nil { throw CancellationError() }
                return .prepared(prepared)
            } catch {
                ownedOperation = nil
                switch phase {
                case .prepared, .preparedForDiscard: break
                default: phase = .failed
                }
                throw error
            }
        case .staging(let prepared, let admission, let task):
            do {
                let staged = try await task.value
                ownedOperation = nil
                phase = .stagedForDiscard(staged)
                guard staged.receipt === prepared.receipt,
                      staged.admission === admission else {
                    throw contractFailure("finish staging")
                }
                if cancellation != nil { throw CancellationError() }
                let permitsPublication = await admission.permitsRecoveryPublication(
                    of: staged.attempt.run
                )
                if cancellation != nil { throw CancellationError() }
                guard permitsPublication else { throw contractFailure("finish staging") }
                phase = .staged(staged)
                return .staged(staged)
            } catch let failure as ReviewRecoveryStagingFailure {
                ownedOperation = nil
                switch phase {
                case .staged, .stagedForDiscard:
                    break
                default:
                    switch failure {
                    case .callerRetainsPreparedRecovery:
                        phase = .prepared(prepared)
                    case .backendOwnsRecovery:
                        phase = .failed
                    }
                }
                throw failure
            } catch {
                ownedOperation = nil
                switch phase {
                case .staged, .stagedForDiscard: break
                default: phase = .failed
                }
                throw error
            }
        case .commit(let staged, let task):
            do {
                try await task.value
                ownedOperation = nil
                phase = .committed(staged)
                return .committed(staged)
            } catch {
                ownedOperation = nil
                phase = .stagedForDiscard(staged)
                throw error
            }
        }
    }

    private func requireStart(_ operation: String) throws {
        if cancellation != nil { throw CancellationError() }
        guard ownedOperation == nil, joinIsReserved == false else {
            throw contractFailure("start concurrent \(operation)")
        }
    }

    private func cancellationAdmission(for operation: OwnedOperation?) -> ReviewStartAdmission {
        switch operation {
        case .staging(_, let admission, _): return admission
        case .commit(let staged, _): return staged.admission
        case .disposition, .preparation, nil: break
        }
        switch phase {
        case .staged(let staged), .stagedForDiscard(let staged),
             .committed(let staged):
            return staged.admission
        case .source, .disposition, .prepared, .preparedForDiscard,
             .failed, .finished, .suppressed:
            return source.admission
        }
    }

    private func contractFailure(_ operation: String) -> ReviewAttemptContractFailure {
        .init(message: "Store recovery receipt cannot \(operation) in its current state.")
    }
}
