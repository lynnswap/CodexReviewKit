import Foundation
import OSLog
import Synchronization

private let reviewRestartLogger = Logger(
    subsystem: "CodexAppServerKit",
    category: "review-restart"
)

private func sameReviewLifecycleIdentity(
    _ lhs: CodexReviewIdentity,
    _ rhs: CodexReviewIdentity
) -> Bool {
    lhs.sourceThreadID == rhs.sourceThreadID
        && lhs.turnID == rhs.turnID
        && lhs.reviewThreadID == rhs.reviewThreadID
}

package final class ReviewRestartIdentityAccumulator: Sendable {
    private let identities = Mutex<[CodexReviewIdentity]>([])

    package init() {}

    package func record(_ identity: CodexReviewIdentity) {
        identities.withLock { identities in
            if identities.contains(where: {
                sameReviewLifecycleIdentity($0, identity)
            }) == false {
                identities.append(identity)
            }
        }
    }

    fileprivate func snapshot() -> [CodexReviewIdentity] {
        identities.withLock { $0 }
    }
}

package actor ReviewRestartCoordinator {
    package struct Context: Sendable {
        package let token: CodexReviewRestartToken
        package let interruptedIdentity: CodexReviewIdentity
        package var rollbackThreadID: CodexThreadID
        package var rollbackModel: String?
        package var rollbackCompleted: Bool
        package var restartAttemptsUsed: Int

        fileprivate init(token: CodexReviewRestartToken) {
            self.token = token
            self.interruptedIdentity = token.interruptedIdentity
            self.rollbackThreadID = token.interruptedIdentity.activeTurnThreadID
            self.rollbackModel = token.interruptedIdentity.model
            self.rollbackCompleted = false
            self.restartAttemptsUsed = 0
        }
    }

    package struct Preparation: Sendable {
        package var rollbackThreadID: CodexThreadID
        package var rollbackModel: String?

        package init(rollbackThreadID: CodexThreadID, rollbackModel: String?) {
            self.rollbackThreadID = rollbackThreadID
            self.rollbackModel = rollbackModel
        }
    }

    package struct PreparationOperations: Sendable {
        fileprivate let execute: @Sendable (
            ReviewRestartIdentityAccumulator
        ) async throws -> Preparation

        package init(
            execute: @escaping @Sendable (
                ReviewRestartIdentityAccumulator
            ) async throws -> Preparation
        ) {
            self.execute = execute
        }
    }

    package struct RestartInvocationSignature: Equatable, Sendable {
        package var target: CodexReviewTarget
        package var delivery: CodexReviewDelivery
        package var threadOptions: CodexThread.ResumeOptions

        package init(
            target: CodexReviewTarget,
            delivery: CodexReviewDelivery,
            threadOptions: CodexThread.ResumeOptions
        ) {
            self.target = target
            self.delivery = delivery
            self.threadOptions = threadOptions
        }
    }

    package struct RestartOperations: Sendable {
        fileprivate let loadRollbackThread: @Sendable (Context) async throws -> CodexThread
        fileprivate let rollback: @Sendable (CodexThread) async throws -> Void
        fileprivate let loadSourceThread: @Sendable (Context) async throws -> CodexThread
        fileprivate let startReview: @Sendable (
            CodexThread,
            ReviewRestartIdentityAccumulator
        ) async throws -> CodexReviewSession
        fileprivate let cleanupLateSession: @Sendable (CodexReviewSession) async throws -> Void

        package init(
            loadRollbackThread: @escaping @Sendable (Context) async throws -> CodexThread,
            rollback: @escaping @Sendable (CodexThread) async throws -> Void,
            loadSourceThread: @escaping @Sendable (Context) async throws -> CodexThread,
            startReview: @escaping @Sendable (
                CodexThread,
                ReviewRestartIdentityAccumulator
            ) async throws -> CodexReviewSession,
            cleanupLateSession: @escaping @Sendable (CodexReviewSession) async throws -> Void
        ) {
            self.loadRollbackThread = loadRollbackThread
            self.rollback = rollback
            self.loadSourceThread = loadSourceThread
            self.startReview = startReview
            self.cleanupLateSession = cleanupLateSession
        }
    }

    package enum State: Sendable {
        case preparing(Context, completion: PreparationCompletion)
        case prepared(Context)
        case restarting(
            Context,
            signature: RestartInvocationSignature,
            completion: RestartCompletion
        )
        case invalidating(Context, completion: InvalidationCompletion)
    }

    private static let maximumRestartAttempts = 2

    private var statesByTokenID: [CodexReviewRestartToken.ID: State] = [:]
    private var retainedIdentityRecordsBySourceThreadID: [
        CodexThreadID: [RetainedIdentityRecord]
    ] = [:]
    private var acceptsNewWork = true

    package init() {}

    package func prepare(
        _ identity: CodexReviewIdentity,
        operations: PreparationOperations
    ) async throws -> CodexReviewRestartToken {
        try Task.checkCancellation()
        guard acceptsNewWork else {
            throw CodexAppServerError.reviewRestartUnavailable("coordinator-closed")
        }
        if let existing = statesByTokenID.values.first(where: {
            Self.context(from: $0).interruptedIdentity.sourceThreadID
                == identity.sourceThreadID
        }) {
            throw CodexAppServerError.reviewRestartUnavailable(
                Self.context(from: existing).token.id
            )
        }

        let token = CodexReviewRestartToken(
            id: UUID().uuidString,
            interruptedIdentity: identity
        )
        let context = Context(token: token)
        let invalidation = InvalidationSignal()
        let accumulator = ReviewRestartIdentityAccumulator()
        let operationID = UUID()
        let task = Task<PreparationExecutionOutcome, Never> {
            do {
                return .succeeded(
                    try await operations.execute(accumulator),
                    retainedIdentities: accumulator.snapshot()
                )
            } catch {
                return .failed(
                    error,
                    retainedIdentities: accumulator.snapshot()
                )
            }
        }
        let completion = PreparationCompletion(
            id: operationID,
            invalidation: invalidation,
            task: task
        )
        statesByTokenID[token.id] = .preparing(context, completion: completion)

        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            invalidation.request()
            task.cancel()
        }
        return try finishPreparation(
            tokenID: token.id,
            completion: completion,
            outcome: outcome,
            callerWasCancelled: Task.isCancelled
        )
    }

    package func restart(
        _ token: CodexReviewRestartToken,
        signature: RestartInvocationSignature,
        operations: RestartOperations
    ) async throws -> CodexReviewSession {
        try Task.checkCancellation()
        guard acceptsNewWork else {
            throw CodexAppServerError.reviewRestartUnavailable(token.id)
        }

        let completion: RestartCompletion
        switch statesByTokenID[token.id] {
        case .prepared(var context):
            try requireMatchingToken(token, context: context)
            guard context.restartAttemptsUsed < Self.maximumRestartAttempts else {
                statesByTokenID.removeValue(forKey: token.id)
                throw CodexAppServerError.reviewRestartUnavailable(token.id)
            }
            context.restartAttemptsUsed += 1
            let operationID = UUID()
            let invalidation = InvalidationSignal()
            let resultCell = SharedResultCell<RestartExecutionOutcome>()
            let task = Task<RestartExecutionOutcome, Never> { [self] in
                let outcome = await executeRestart(
                    operationID: operationID,
                    context: context,
                    operations: operations
                )
                resultCell.resolve(outcome)
                return outcome
            }
            completion = RestartCompletion(
                id: operationID,
                invalidation: invalidation,
                task: task,
                resultCell: resultCell,
                cleanupLateSession: operations.cleanupLateSession
            )
            statesByTokenID[token.id] = .restarting(
                context,
                signature: signature,
                completion: completion
            )
        case .restarting(let context, let existingSignature, let existingCompletion):
            try requireMatchingToken(token, context: context)
            guard existingSignature == signature,
                  existingCompletion.invalidation.isRequested == false else {
                throw CodexAppServerError.reviewRestartUnavailable(token.id)
            }
            completion = existingCompletion
        case .preparing(let context, _), .invalidating(let context, _):
            try requireMatchingToken(token, context: context)
            throw CodexAppServerError.reviewRestartUnavailable(token.id)
        case nil:
            throw CodexAppServerError.reviewRestartUnavailable(token.id)
        }

        let outcome = try await completion.wait()
        return try await finishRestart(
            tokenID: token.id,
            completion: completion,
            outcome: outcome
        )
    }

    package func invalidate(
        _ token: CodexReviewRestartToken
    ) async -> [CodexReviewIdentity] {
        guard let state = statesByTokenID[token.id] else {
            return takeRetainedIdentities(ownerToken: token)
        }
        let context = Self.context(from: state)
        guard context.token == token else {
            return []
        }
        let completion = transitionToInvalidating(
            tokenID: token.id,
            state: state
        )
        _ = await completion.task.value
        return await finishInvalidation(
            tokenID: token.id,
            context: context,
            completion: completion
        )
    }

    package func invalidateAllAndWait()
        async -> [CodexThreadID: [CodexReviewIdentity]] {
        acceptsNewWork = false
        let stateSnapshot = Array(statesByTokenID)
        let invalidations = stateSnapshot.map { tokenID, state in
            let context = Self.context(from: state)
            let completion = transitionToInvalidating(
                tokenID: tokenID,
                state: state
            )
            return (tokenID, context, completion)
        }

        var result: [CodexThreadID: [CodexReviewIdentity]] = [:]
        for (tokenID, context, completion) in invalidations {
            _ = await completion.task.value
            let identities = await finishInvalidation(
                tokenID: tokenID,
                context: context,
                completion: completion
            )
            Self.merge(
                identities,
                into: &result[context.interruptedIdentity.sourceThreadID, default: []]
            )
        }
        for sourceThreadID in Array(retainedIdentityRecordsBySourceThreadID.keys) {
            Self.merge(
                takeRetainedIdentities(sourceThreadID: sourceThreadID),
                into: &result[sourceThreadID, default: []]
            )
        }
        return result.filter { $0.value.isEmpty == false }
    }

    package func invalidateAndTakeRetainedIdentities(
        sourceThreadID: CodexThreadID
    ) async -> [CodexReviewIdentity] {
        let stateSnapshot = Array(statesByTokenID)
        let invalidations = stateSnapshot.compactMap { tokenID, state -> (
            CodexReviewRestartToken.ID,
            Context,
            InvalidationCompletion
        )? in
            let context = Self.context(from: state)
            guard context.interruptedIdentity.sourceThreadID == sourceThreadID else {
                return nil
            }
            return (
                tokenID,
                context,
                transitionToInvalidating(tokenID: tokenID, state: state)
            )
        }
        var identities: [CodexReviewIdentity] = []
        for (tokenID, context, completion) in invalidations {
            _ = await completion.task.value
            Self.merge(
                await finishInvalidation(
                    tokenID: tokenID,
                    context: context,
                    completion: completion
                ),
                into: &identities
            )
        }
        Self.merge(
            takeRetainedIdentities(sourceThreadID: sourceThreadID),
            into: &identities
        )
        return identities
    }

    package func restoreRetainedIdentities(
        _ identities: [CodexReviewIdentity]
    ) {
        retain(identities, ownerToken: nil)
    }

    package func waitForRestartWaiterCountForTesting(
        tokenID: CodexReviewRestartToken.ID,
        atLeast minimumCount: Int
    ) async {
        guard case .restarting(_, _, let completion) = statesByTokenID[tokenID] else {
            preconditionFailure("A restart waiter can only be observed while restarting.")
        }
        await completion.waitForWaiterCount(atLeast: minimumCount)
    }

    package func waitForInvalidationRequestForTesting(
        tokenID: CodexReviewRestartToken.ID
    ) async {
        switch statesByTokenID[tokenID] {
        case .preparing(_, let completion):
            await completion.invalidation.waitUntilRequested()
        case .restarting(_, _, let completion):
            await completion.invalidation.waitUntilRequested()
        case .invalidating, nil:
            return
        case .prepared:
            preconditionFailure("An invalidation request cannot be observed before it starts.")
        }
    }

    private func finishPreparation(
        tokenID: CodexReviewRestartToken.ID,
        completion: PreparationCompletion,
        outcome: PreparationExecutionOutcome,
        callerWasCancelled: Bool
    ) throws -> CodexReviewRestartToken {
        guard case .preparing(var context, let currentCompletion) = statesByTokenID[tokenID],
              currentCompletion.id == completion.id else {
            if callerWasCancelled || completion.invalidation.isRequested {
                throw CancellationError()
            }
            throw CodexAppServerError.reviewRestartUnavailable(tokenID)
        }
        retain(outcome.retainedIdentities, ownerToken: context.token)
        if callerWasCancelled || completion.invalidation.isRequested {
            statesByTokenID.removeValue(forKey: tokenID)
            throw CancellationError()
        }
        switch outcome {
        case .succeeded(let preparation, _):
            context.rollbackThreadID = preparation.rollbackThreadID
            context.rollbackModel = preparation.rollbackModel
            statesByTokenID[tokenID] = .prepared(context)
            return context.token
        case .failed(let error, _):
            statesByTokenID.removeValue(forKey: tokenID)
            throw error
        }
    }

    private func executeRestart(
        operationID: UUID,
        context initialContext: Context,
        operations: RestartOperations
    ) async -> RestartExecutionOutcome {
        var context = initialContext
        let accumulator = ReviewRestartIdentityAccumulator()

        if context.rollbackCompleted == false {
            let rollbackThread: CodexThread
            do {
                rollbackThread = try await operations.loadRollbackThread(context)
            } catch {
                return .failed(
                    error,
                    phase: .loadingRollbackThread,
                    context: context,
                    retainedIdentities: accumulator.snapshot()
                )
            }
            do {
                try await operations.rollback(rollbackThread)
            } catch {
                return .failed(
                    error,
                    phase: .rollingBack,
                    context: context,
                    retainedIdentities: accumulator.snapshot()
                )
            }
            context.rollbackCompleted = true
            guard commitRollback(
                tokenID: context.token.id,
                operationID: operationID,
                context: context
            ) else {
                return .failed(
                    CancellationError(),
                    phase: .rollingBack,
                    context: context,
                    retainedIdentities: accumulator.snapshot()
                )
            }
        }

        do {
            try Task.checkCancellation()
        } catch {
            return .failed(
                error,
                phase: .loadingSourceThread,
                context: context,
                retainedIdentities: accumulator.snapshot()
            )
        }

        let sourceThread: CodexThread
        do {
            sourceThread = try await operations.loadSourceThread(context)
        } catch {
            return .failed(
                error,
                phase: .loadingSourceThread,
                context: context,
                retainedIdentities: accumulator.snapshot()
            )
        }

        do {
            try Task.checkCancellation()
        } catch {
            return .failed(
                error,
                phase: .startingReview,
                context: context,
                retainedIdentities: accumulator.snapshot()
            )
        }

        do {
            let review = try await operations.startReview(sourceThread, accumulator)
            do {
                try Task.checkCancellation()
            } catch {
                accumulator.record(review.identity)
                await Self.cleanLateSession(
                    review,
                    using: operations.cleanupLateSession
                )
                return .failed(
                    error,
                    phase: .startingReview,
                    context: context,
                    retainedIdentities: accumulator.snapshot()
                )
            }
            return .succeeded(
                review,
                context: context,
                retainedIdentities: accumulator.snapshot()
            )
        } catch {
            return .failed(
                error,
                phase: .startingReview,
                context: context,
                retainedIdentities: accumulator.snapshot()
            )
        }
    }

    private func commitRollback(
        tokenID: CodexReviewRestartToken.ID,
        operationID: UUID,
        context: Context
    ) -> Bool {
        guard case .restarting(_, let signature, let completion) = statesByTokenID[tokenID],
              completion.id == operationID,
              completion.invalidation.isRequested == false else {
            return false
        }
        precondition(
            context.rollbackCompleted,
            "A review restart must commit rollback before continuing."
        )
        statesByTokenID[tokenID] = .restarting(
            context,
            signature: signature,
            completion: completion
        )
        return true
    }

    private func finishRestart(
        tokenID: CodexReviewRestartToken.ID,
        completion: RestartCompletion,
        outcome: RestartExecutionOutcome
    ) async throws -> CodexReviewSession {
        if let settlement = completion.settlement {
            return try Self.value(from: settlement, tokenID: tokenID)
        }

        guard case .restarting(_, _, let currentCompletion) = statesByTokenID[tokenID],
              currentCompletion.id == completion.id else {
            if let settlement = completion.settlement {
                return try Self.value(from: settlement, tokenID: tokenID)
            }
            if completion.invalidation.isRequested {
                throw CodexAppServerError.reviewRestartUnavailable(tokenID)
            }
            preconditionFailure("A shared review restart must settle exactly once.")
        }

        if completion.invalidation.isRequested {
            let state = statesByTokenID[tokenID]!
            let invalidation = transitionToInvalidating(
                tokenID: tokenID,
                state: state
            )
            _ = await invalidation.task.value
            _ = await finishInvalidation(
                tokenID: tokenID,
                context: Self.context(from: state),
                completion: invalidation
            )
            return try Self.value(
                from: completion.settlement ?? .unavailable,
                tokenID: tokenID
            )
        }

        retain(
            outcome.retainedIdentities,
            ownerToken: outcome.context.token
        )
        switch outcome {
        case .succeeded(let review, let context, _):
            retain([review.identity], ownerToken: context.token)
            statesByTokenID.removeValue(forKey: tokenID)
            completion.setSettlement(.succeeded(review))
        case .failed(let error, let phase, let context, _):
            let disposition = Self.failureDisposition(error: error, phase: phase)
            if disposition == .retryPrepared,
               context.restartAttemptsUsed < Self.maximumRestartAttempts {
                statesByTokenID[tokenID] = .prepared(context)
                completion.setSettlement(.failed(error))
            } else {
                statesByTokenID.removeValue(forKey: tokenID)
                if disposition == .retryPrepared {
                    completion.setSettlement(.unavailable)
                } else {
                    completion.setSettlement(.failed(error))
                }
            }
        }
        return try Self.value(
            from: completion.settlement!,
            tokenID: tokenID
        )
    }

    private func transitionToInvalidating(
        tokenID: CodexReviewRestartToken.ID,
        state: State
    ) -> InvalidationCompletion {
        if case .invalidating(_, let completion) = state {
            return completion
        }

        let context = Self.context(from: state)
        let operationID = UUID()
        let task: Task<[CodexReviewIdentity], Never>
        let restartCompletion: RestartCompletion?
        switch state {
        case .prepared:
            task = Task { [] }
            restartCompletion = nil
        case .preparing(_, let preparation):
            preparation.invalidation.request()
            preparation.task.cancel()
            task = Task {
                let outcome = await preparation.task.value
                return outcome.retainedIdentities
            }
            restartCompletion = nil
        case .restarting(_, _, let restart):
            restart.invalidation.request()
            restart.task.cancel()
            task = Task {
                let outcome = await restart.task.value
                var identities = outcome.retainedIdentities
                if case .succeeded(let review, _, _) = outcome {
                    Self.merge([review.identity], into: &identities)
                    await Self.cleanLateSession(
                        review,
                        using: restart.cleanupLateSession
                    )
                }
                return identities
            }
            restartCompletion = restart
        case .invalidating:
            preconditionFailure("An existing invalidation must be joined.")
        }
        let completion = InvalidationCompletion(
            id: operationID,
            task: task,
            restartCompletion: restartCompletion
        )
        statesByTokenID[tokenID] = .invalidating(
            context,
            completion: completion
        )
        return completion
    }

    private func finishInvalidation(
        tokenID: CodexReviewRestartToken.ID,
        context: Context,
        completion: InvalidationCompletion
    ) async -> [CodexReviewIdentity] {
        if let result = completion.result {
            return result
        }
        let lateIdentities = await completion.task.value
        retain(lateIdentities, ownerToken: context.token)

        if case .invalidating(_, let currentCompletion) = statesByTokenID[tokenID],
           currentCompletion.id == completion.id {
            statesByTokenID.removeValue(forKey: tokenID)
        }
        completion.restartCompletion?.setSettlementIfUnset(.unavailable)
        let identities = takeRetainedIdentities(ownerToken: context.token)
        completion.setResultIfUnset(identities)
        return completion.result ?? identities
    }

    private func retain(
        _ identities: [CodexReviewIdentity],
        ownerToken: CodexReviewRestartToken?
    ) {
        for identity in identities {
            let sourceThreadID = identity.sourceThreadID
            let record = RetainedIdentityRecord(
                identity: identity,
                ownerToken: ownerToken
            )
            if retainedIdentityRecordsBySourceThreadID[sourceThreadID, default: []]
                .contains(where: {
                    $0.ownerToken == record.ownerToken
                        && sameReviewLifecycleIdentity($0.identity, record.identity)
                }) == false {
                retainedIdentityRecordsBySourceThreadID[sourceThreadID, default: []]
                    .append(record)
            }
        }
    }

    private func takeRetainedIdentities(
        sourceThreadID: CodexThreadID
    ) -> [CodexReviewIdentity] {
        let records = retainedIdentityRecordsBySourceThreadID.removeValue(
            forKey: sourceThreadID
        ) ?? []
        var identities: [CodexReviewIdentity] = []
        Self.merge(records.map(\.identity), into: &identities)
        return identities
    }

    private func takeRetainedIdentities(
        ownerToken: CodexReviewRestartToken
    ) -> [CodexReviewIdentity] {
        let sourceThreadID = ownerToken.interruptedIdentity.sourceThreadID
        guard var records = retainedIdentityRecordsBySourceThreadID[sourceThreadID] else {
            return []
        }
        let matching = records.filter { $0.ownerToken == ownerToken }
        guard matching.isEmpty == false else {
            return []
        }
        records.removeAll { $0.ownerToken == ownerToken }
        if records.isEmpty {
            retainedIdentityRecordsBySourceThreadID.removeValue(forKey: sourceThreadID)
        } else {
            retainedIdentityRecordsBySourceThreadID[sourceThreadID] = records
        }
        var identities: [CodexReviewIdentity] = []
        Self.merge(matching.map(\.identity), into: &identities)
        return identities
    }

    private func requireMatchingToken(
        _ token: CodexReviewRestartToken,
        context: Context
    ) throws {
        guard context.token == token else {
            throw CodexAppServerError.reviewRestartUnavailable(token.id)
        }
    }

    private nonisolated static func context(from state: State) -> Context {
        switch state {
        case .preparing(let context, _), .prepared(let context),
             .restarting(let context, _, _), .invalidating(let context, _):
            context
        }
    }

    private nonisolated static func cleanLateSession(
        _ review: CodexReviewSession,
        using cleanup: @Sendable (CodexReviewSession) async throws -> Void
    ) async {
        do {
            try await cleanup(review)
        } catch {
            reviewRestartLogger.error(
                "Failed to interrupt late review session \(review.turnID.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private nonisolated static func merge(
        _ newIdentities: [CodexReviewIdentity],
        into identities: inout [CodexReviewIdentity]
    ) {
        for identity in newIdentities {
            if identities.contains(where: {
                sameReviewLifecycleIdentity($0, identity)
            }) == false {
                identities.append(identity)
            }
        }
    }

    private nonisolated static func failureDisposition(
        error: any Error,
        phase: RestartFailurePhase
    ) -> RestartFailureDisposition {
        if error is CancellationError {
            return .invalidate
        }
        switch phase {
        case .loadingSourceThread:
            return .retryPrepared
        case .loadingRollbackThread:
            if case CodexAppServerError.connectionTerminated = error {
                return .invalidate
            }
            return .retryPrepared
        case .rollingBack, .startingReview:
            guard let error = error as? CodexAppServerError else {
                return .invalidate
            }
            switch error {
            case .request(let failure):
                switch failure.kind {
                case .encode, .transport, .server, .overloadRetryExhausted:
                    return .retryPrepared
                case .write, .invalidResponse, .deadlineExceeded:
                    return .invalidate
                }
            case .connectionTerminated:
                return .invalidate
            case .launch, .turnDeadlineExceeded, .malformedNotification,
                 .reviewRestartUnavailable, .loginAlreadyInProgress,
                 .invalidAPIKey, .authenticationOutcomeUnknown:
                return .invalidate
            }
        }
    }

    private nonisolated static func value(
        from settlement: RestartSettlement,
        tokenID: CodexReviewRestartToken.ID
    ) throws -> CodexReviewSession {
        switch settlement {
        case .succeeded(let review):
            return review
        case .failed(let error):
            throw error
        case .unavailable:
            throw CodexAppServerError.reviewRestartUnavailable(tokenID)
        }
    }
}

private enum PreparationExecutionOutcome: Sendable {
    case succeeded(
        ReviewRestartCoordinator.Preparation,
        retainedIdentities: [CodexReviewIdentity]
    )
    case failed(any Error, retainedIdentities: [CodexReviewIdentity])

    var retainedIdentities: [CodexReviewIdentity] {
        switch self {
        case .succeeded(_, let identities), .failed(_, let identities):
            identities
        }
    }
}

private enum RestartFailurePhase: Sendable {
    case loadingRollbackThread
    case rollingBack
    case loadingSourceThread
    case startingReview
}

private enum RestartFailureDisposition: Equatable, Sendable {
    case retryPrepared
    case invalidate
}

private enum RestartExecutionOutcome: Sendable {
    case succeeded(
        CodexReviewSession,
        context: ReviewRestartCoordinator.Context,
        retainedIdentities: [CodexReviewIdentity]
    )
    case failed(
        any Error,
        phase: RestartFailurePhase,
        context: ReviewRestartCoordinator.Context,
        retainedIdentities: [CodexReviewIdentity]
    )

    var retainedIdentities: [CodexReviewIdentity] {
        switch self {
        case .succeeded(_, _, let identities), .failed(_, _, _, let identities):
            identities
        }
    }

    var context: ReviewRestartCoordinator.Context {
        switch self {
        case .succeeded(_, let context, _), .failed(_, _, let context, _):
            context
        }
    }
}

private enum RestartSettlement: Sendable {
    case succeeded(CodexReviewSession)
    case failed(any Error)
    case unavailable
}

private struct RetainedIdentityRecord: Equatable, Sendable {
    var identity: CodexReviewIdentity
    var ownerToken: CodexReviewRestartToken?
}

package final class PreparationCompletion: Sendable {
    fileprivate let id: UUID
    fileprivate let invalidation: InvalidationSignal
    fileprivate let task: Task<PreparationExecutionOutcome, Never>

    fileprivate init(
        id: UUID,
        invalidation: InvalidationSignal,
        task: Task<PreparationExecutionOutcome, Never>
    ) {
        self.id = id
        self.invalidation = invalidation
        self.task = task
    }
}

package final class RestartCompletion: Sendable {
    fileprivate let id: UUID
    fileprivate let invalidation: InvalidationSignal
    fileprivate let task: Task<RestartExecutionOutcome, Never>
    private let resultCell: SharedResultCell<RestartExecutionOutcome>
    fileprivate let cleanupLateSession: @Sendable (CodexReviewSession) async throws -> Void
    private let storedSettlement = Mutex<RestartSettlement?>(nil)

    fileprivate init(
        id: UUID,
        invalidation: InvalidationSignal,
        task: Task<RestartExecutionOutcome, Never>,
        resultCell: SharedResultCell<RestartExecutionOutcome>,
        cleanupLateSession: @escaping @Sendable (CodexReviewSession) async throws -> Void
    ) {
        self.id = id
        self.invalidation = invalidation
        self.task = task
        self.resultCell = resultCell
        self.cleanupLateSession = cleanupLateSession
    }

    fileprivate func wait() async throws -> RestartExecutionOutcome {
        try await resultCell.wait()
    }

    fileprivate func waitForWaiterCount(atLeast minimumCount: Int) async {
        await resultCell.waitForWaiterCount(atLeast: minimumCount)
    }

    fileprivate var settlement: RestartSettlement? {
        storedSettlement.withLock { $0 }
    }

    fileprivate func setSettlement(_ settlement: RestartSettlement) {
        storedSettlement.withLock { stored in
            precondition(stored == nil, "A shared restart completion must settle exactly once.")
            stored = settlement
        }
    }

    fileprivate func setSettlementIfUnset(_ settlement: RestartSettlement) {
        storedSettlement.withLock { stored in
            if stored == nil {
                stored = settlement
            }
        }
    }
}

package final class InvalidationCompletion: Sendable {
    fileprivate let id: UUID
    fileprivate let task: Task<[CodexReviewIdentity], Never>
    fileprivate let restartCompletion: RestartCompletion?
    private let storedResult = Mutex<[CodexReviewIdentity]?>(nil)

    fileprivate init(
        id: UUID,
        task: Task<[CodexReviewIdentity], Never>,
        restartCompletion: RestartCompletion?
    ) {
        self.id = id
        self.task = task
        self.restartCompletion = restartCompletion
    }

    fileprivate var result: [CodexReviewIdentity]? {
        storedResult.withLock { $0 }
    }

    fileprivate func setResultIfUnset(_ result: [CodexReviewIdentity]) {
        storedResult.withLock { stored in
            if stored == nil {
                stored = result
            }
        }
    }
}

private final class InvalidationSignal: Sendable {
    private struct State: Sendable {
        var isRequested = false
        var observers: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var isRequested: Bool {
        state.withLock { $0.isRequested }
    }

    func request() {
        let observers = state.withLock { state in
            state.isRequested = true
            let observers = state.observers
            state.observers.removeAll(keepingCapacity: false)
            return observers
        }
        for observer in observers {
            observer.resume()
        }
    }

    func waitUntilRequested() async {
        let shouldWait = state.withLock { $0.isRequested == false }
        guard shouldWait else {
            return
        }
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                if state.isRequested {
                    return true
                }
                state.observers.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private final class SharedResultCell<Value: Sendable>: Sendable {
    private struct WaiterCountObserver: Sendable {
        var minimumCount: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var result: Value?
        var waiters: [
            UUID: CheckedContinuation<Result<Value, CancellationError>, Never>
        ] = [:]
        var waiterCountObservers: [WaiterCountObserver] = []
    }

    private let state = Mutex(State())

    func wait() async throws -> Value {
        try Task.checkCancellation()
        let waiterID = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let registration = state.withLock {
                    state -> (
                        Result<Value, CancellationError>?,
                        [CheckedContinuation<Void, Never>]
                    ) in
                    if Task.isCancelled {
                        return (.failure(CancellationError()), [])
                    }
                    if let result = state.result {
                        return (.success(result), [])
                    }
                    state.waiters[waiterID] = continuation
                    let ready = state.waiterCountObservers.filter {
                        state.waiters.count >= $0.minimumCount
                    }.map(\.continuation)
                    state.waiterCountObservers.removeAll {
                        state.waiters.count >= $0.minimumCount
                    }
                    return (nil, ready)
                }
                for observer in registration.1 {
                    observer.resume()
                }
                if let immediate = registration.0 {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiters.removeValue(forKey: waiterID)
            }
            waiter?.resume(returning: .failure(CancellationError()))
        }
        return try result.get()
    }

    func waitForWaiterCount(atLeast minimumCount: Int) async {
        precondition(minimumCount > 0)
        let shouldWait = state.withLock { state in
            state.result == nil && state.waiters.count < minimumCount
        }
        guard shouldWait else {
            return
        }
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                if state.result != nil || state.waiters.count >= minimumCount {
                    return true
                }
                state.waiterCountObservers.append(.init(
                    minimumCount: minimumCount,
                    continuation: continuation
                ))
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resolve(_ result: Value) {
        let waiters = state.withLock { state in
            precondition(state.result == nil, "A shared result must resolve exactly once.")
            state.result = result
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: false)
            let observers = state.waiterCountObservers.map(\.continuation)
            state.waiterCountObservers.removeAll(keepingCapacity: false)
            return (waiters, observers)
        }
        for waiter in waiters.0 {
            waiter.resume(returning: .success(result))
        }
        for observer in waiters.1 {
            observer.resume()
        }
    }
}
