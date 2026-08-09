import Foundation
import CodexAppServerKit
import CodexDataKit
import CodexReviewKit
import OSLog

private let appServerBackendLogger = Logger(
    subsystem: "CodexReviewKit",
    category: "app-server-backend"
)

private func makeAppServerReviewAttemptID() -> String {
    UUID().uuidString
}

package actor AppServerCodexReviewBackend: CodexReviewBackend, CodexModelActor {
    private static let reviewPermissionProfileID = ":danger-full-access"

    private let appServer: CodexAppServer
    nonisolated package let modelContainer: CodexModelContainer
    nonisolated package let modelExecutor: CodexDefaultSerialModelExecutor
    private struct ActiveReviewSession {
        let attempt: ReviewAttempt
        let session: CodexReviewSession
        let chat: CodexChat
    }

    private var activeReviewSessionsByAttemptID: [ReviewAttemptID: ActiveReviewSession] = [:]
    private var abandonedReviewAttemptIDs: Set<ReviewAttemptID> = []
    private var inFlightRestartCountByInterruptedAttemptID: [ReviewAttemptID: Int] = [:]

    package init(modelContainer: CodexModelContainer) {
        self.appServer = modelContainer.appServer
        self.modelContainer = modelContainer
        self.modelExecutor = CodexDefaultSerialModelExecutor(modelContainer: modelContainer)
    }

    package func readSettings() async throws -> CodexReviewBackendModel.Settings.Snapshot {
        let configuration = try await appServer.configuration()
        let models = try await appServer.models(includeHidden: true)
            .map(\.reviewModelCatalogItem)
        return .init(
            model: configuration.reviewModel?.nilIfEmpty,
            fallbackModel: configuration.model?.nilIfEmpty ?? models.first(where: \.isDefault)?.model,
            reasoningEffort: configuration.reasoningEffort?.rawValue,
            serviceTier: configuration.serviceTier,
            models: models
        )
    }

    package func applySettings(_ change: CodexReviewBackendModel.Settings.Change) async throws
        -> CodexReviewBackendModel.Settings.Snapshot
    {
        var patch = CodexConfigurationPatch()
        if change.updatesModel {
            patch.setReviewModel(change.model?.nilIfEmpty)
        }
        if change.updatesReasoningEffort {
            patch.setReasoningEffort(change.reasoningEffort?.nilIfEmpty.map(CodexReasoningEffort.init(rawValue:)))
        }
        if change.updatesServiceTier {
            patch.setServiceTier(change.serviceTier?.nilIfEmpty)
        }
        try await appServer.updateConfiguration(patch)
        return try await readSettings()
    }

    package func readAuth() async throws -> CodexReviewBackendModel.Auth.Snapshot {
        guard let account = try await appServer.account() else {
            return .init()
        }
        let backendAccount = account.backendAccount
        return .init(accounts: [backendAccount], activeAccountID: backendAccount.id)
    }

    package func readRateLimits() async throws -> CodexRateLimits {
        try await appServer.rateLimits()
    }

    package func logout(_: CodexReviewBackendModel.Account.ID) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        try await appServer.logout()
        return try await readAuth()
    }

    package func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt {
        let startedReview = try await performReviewOperation(.startReview) {
            try await startReviewSession(for: request)
        }
        let attempt: ReviewAttempt
        do {
            attempt = try Self.reviewAttempt(
                for: startedReview.session,
                attemptID: makeAppServerReviewAttemptID(),
                fallbackModel: request.model
            )
        } catch {
            await discardInvalidlyIdentifiedReview(startedReview.session)
            throw ReviewBackendFailure.protocolViolation(
                message: "Review start returned invalid identity: \(error.localizedDescription)"
            )
        }
        let activeReview = ActiveReviewSession(
            attempt: attempt,
            session: startedReview.session,
            chat: startedReview.chat
        )
        activeReviewSessionsByAttemptID[attempt.attemptID] = activeReview
        return backendAttempt(for: activeReview)
    }

    private func startReviewSession(for request: CodexReviewBackendModel.Review.Start) async throws
        -> CodexStartedReview
    {
        let workspace = URL(fileURLWithPath: request.request.cwd, isDirectory: true)
        return try await startDataKitBackedReviewSession(request, in: workspace)
    }

    private func startDataKitBackedReviewSession(
        _ request: CodexReviewBackendModel.Review.Start,
        in workspace: URL
    ) async throws -> CodexStartedReview {
        try await modelContext.startReview(
            in: workspace,
            input: CodexReviewInput(
                target: request.request.target.appServerReviewTarget,
                options: reviewThreadOptions(request),
                delivery: .inline
            )
        )
    }

    private func reviewThreadOptions(
        _ request: CodexReviewBackendModel.Review.Start
    ) -> CodexThread.Options {
        reviewThreadOptions(model: request.model)
    }

    // Every thread handle a review runs on uses the same review profile;
    // restart/resume paths must not fall back to default Codex settings.
    private func reviewThreadOptions(model: String?) -> CodexThread.Options {
        .init(
            model: model,
            approvalMode: .denyAll,
            permissions: .profile(id: Self.reviewPermissionProfileID),
            ephemeral: false,
            sessionStartSource: .startup,
            threadSource: .user
        )
    }

    package func interruptReview(
        _ attempt: ReviewAttempt, reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        guard abandonedReviewAttemptIDs.contains(attempt.attemptID) == false else {
            return
        }
        _ = try await performReviewOperation(.interruptReview) {
            try await cancelReviewTurn(for: attempt)
        }
    }

    package func prepareReviewRestart(
        _ attempt: ReviewAttempt
    ) async throws -> CodexReviewBackendModel.Review.RestartToken {
        let identity = attempt.appServerReviewIdentity
        let appServerToken = try await performReviewOperation(.prepareRestart) {
            try await appServer.prepareReviewRestart(identity)
        }
        markAttemptAbandoned(attempt)
        activeReviewSessionsByAttemptID.removeValue(forKey: attempt.attemptID)
        return CodexReviewBackendModel.Review.RestartToken(
            id: appServerToken.id,
            interruptedAttempt: attempt
        )
    }

    package func restartPreparedReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        let interruptedAttempt = token.interruptedAttempt
        let interruptedIdentity = interruptedAttempt.appServerReviewIdentity
        let appServerToken = CodexReviewRestartToken(
            id: token.id,
            interruptedIdentity: interruptedIdentity
        )
        markRestartInFlight(forInterrupted: interruptedAttempt)
        defer {
            clearRestartInFlight(forInterrupted: interruptedAttempt)
        }
        let review = try await performReviewOperation(.restartReview) {
            try await appServer.restartPreparedReview(
                appServerToken,
                target: request.request.target.appServerReviewTarget,
                delivery: .inline,
                threadOptions: reviewThreadOptions(model: interruptedAttempt.model ?? request.model)
            )
        }
        let recoveredAttempt: ReviewAttempt
        do {
            recoveredAttempt = try Self.reviewAttempt(
                for: review,
                attemptID: makeAppServerReviewAttemptID(),
                sourceThreadID: interruptedAttempt.threadIdentity.sourceThreadID.rawValue,
                fallbackModel: interruptedAttempt.model ?? request.model
            )
        } catch {
            await discardInvalidlyIdentifiedReview(review)
            throw ReviewBackendFailure.protocolViolation(
                message: "Review restart returned invalid identity: \(error.localizedDescription)"
            )
        }
        let activeReview = ActiveReviewSession(
            attempt: recoveredAttempt,
            session: review,
            chat: modelContext.model(for: review.activeTurnThreadID)
        )
        activeReviewSessionsByAttemptID[recoveredAttempt.attemptID] = activeReview
        return backendAttempt(for: activeReview)
    }

    package func discardPreparedReviewRestart(
        _ token: CodexReviewBackendModel.Review.RestartToken
    ) async -> [ReviewAttempt] {
        let interruptedAttempt = token.interruptedAttempt
        let interruptedIdentity = interruptedAttempt.appServerReviewIdentity
        let retainedIdentities = await appServer.discardPreparedReviewRestart(
            CodexReviewRestartToken(
                id: token.id,
                interruptedIdentity: interruptedIdentity
            )
        )

        return retainedIdentities.map { identity in
            // Do not turn this into a recoverable cross-source cleanup path. CodexKit
            // keys token-owned retention by the token's source thread and constructs
            // restarted identities from that same source handle. If this invariant is
            // broken, assigning the identity to this run would transfer deletion
            // authority across review lifecycles with no valid quarantine owner.
            precondition(
                identity.sourceThreadID.rawValue
                    == interruptedAttempt.threadIdentity.sourceThreadID.rawValue,
                "A prepared review restart cannot transfer cleanup authority across source threads."
            )
            if identity == interruptedIdentity {
                return interruptedAttempt
            }
            do {
                return try Self.reviewAttempt(
                    for: identity,
                    attemptID: makeAppServerReviewAttemptID(),
                    fallbackModel: interruptedAttempt.model
                )
            } catch {
                preconditionFailure(
                    "CodexKit returned an invalid retained review identity: \(error.localizedDescription)"
                )
            }
        }
    }

    package func discardAllPreparedReviewRestarts(
        ownedAttemptsByRunID: [ReviewRunID: ReviewAttempt]
    ) async -> [ReviewRunID: [ReviewAttempt]] {
        let retainedIdentitiesBySource = await appServer.discardAllPreparedReviewRestarts()
        var retainedAttemptsByRunID: [ReviewRunID: [ReviewAttempt]] = [:]

        for retainedIdentities in retainedIdentitiesBySource.values {
            let owners = ownedAttemptsByRunID.filter { _, attempt in
                retainedIdentities.contains(attempt.appServerReviewIdentity)
            }
            precondition(
                owners.count == 1,
                "A prepared-restart identity group must match exactly one retained review run."
            )
            guard let (runID, owner) = owners.first else {
                preconditionFailure(
                    "A prepared-restart identity group requires a retained review run."
                )
            }
            retainedAttemptsByRunID[runID] = retainedIdentities.map { identity in
                if identity == owner.appServerReviewIdentity {
                    return owner
                }
                do {
                    return try Self.reviewAttempt(
                        for: identity,
                        attemptID: makeAppServerReviewAttemptID(),
                        fallbackModel: owner.model
                    )
                } catch {
                    preconditionFailure(
                        "CodexKit returned an invalid retained review identity: \(error.localizedDescription)"
                    )
                }
            }
        }
        return retainedAttemptsByRunID
    }

    package func cleanupReview(_ attempt: ReviewAttempt) async {
        finishReviewLocally(attempt)
    }

    private func finishReviewLocally(
        _ attempt: ReviewAttempt
    ) {
        activeReviewSessionsByAttemptID.removeValue(forKey: attempt.attemptID)
        abandonedReviewAttemptIDs.remove(attempt.attemptID)
    }

    package func cleanupRetainedReviews(
        _ attempts: [ReviewAttempt],
        additionalThreadIDs: [ReviewThreadID]
    ) async -> ReviewRetainedThreadCleanupResult {
        guard let firstAttempt = attempts.first else {
            return .init()
        }
        let sourceThreadID = firstAttempt.threadIdentity.sourceThreadID
        precondition(
            attempts.allSatisfy { $0.threadIdentity.sourceThreadID == sourceThreadID },
            "One retained review cleanup must contain a single source thread lifecycle."
        )
        let result = await appServer.cleanupReview(
            firstAttempt.appServerReviewIdentity,
            additionalCleanupThreadIDs: attempts.dropFirst().map { attempt in
                attempt.appServerReviewIdentity.cleanupThreadIDs
            } + [additionalThreadIDs.map { CodexThreadID(rawValue: $0.rawValue) }]
        )
        return .init(failures: result.failures.map { failure in
            guard let threadID = try? ReviewThreadID(validating: failure.threadID.rawValue) else {
                preconditionFailure("CodexKit returned an empty cleanup thread identity.")
            }
            return .init(
                threadID: threadID,
                message: failure.message
            )
        })
    }

    package func cleanupActiveReviewsForShutdown(_ request: CodexReviewRuntimeStopReviewCleanupRequest) async {
        let attempts = await activeReviewAttemptsForShutdown()
        var cleanedAttemptIDs: Set<ReviewAttemptID> = []
        for attempt in attempts {
            if Task.isCancelled {
                return
            }
            try? await interruptReview(attempt, reason: request.reason)
            if Task.isCancelled {
                return
            }
            await cleanupReview(attempt)
            cleanedAttemptIDs.insert(attempt.attemptID)
        }
        for attempt in request.recoveryWaitingAttempts
        where cleanedAttemptIDs.insert(attempt.attemptID).inserted {
            if isRestartInFlight(forInterrupted: attempt) {
                continue
            }
            if Task.isCancelled {
                return
            }
            await cleanupReview(attempt)
        }
    }

    package func cleanupActiveReviewsAfterConnectionTermination(
        _ request: CodexReviewRuntimeStopReviewCleanupRequest
    ) async {
        let activeAttempts = await activeReviewAttemptsForShutdown()
        var attemptsByID = Dictionary(uniqueKeysWithValues: activeAttempts.map { ($0.attemptID, $0) })
        for attempt in request.recoveryWaitingAttempts {
            attemptsByID[attempt.attemptID] = attempt
        }

        for attempt in attemptsByID.values {
            finishReviewLocally(attempt)
        }
    }

    private func backendAttempt(for activeReview: ActiveReviewSession) -> BackendReviewAttempt {
        let attempt = activeReview.attempt
        return BackendReviewAttempt(
            attempt: activeReview.attempt,
            observeTerminal: { [self] in
                try await observeTerminal(for: attempt)
            },
            observedTerminalIfKnown: { [self] in
                await observedTerminalIfKnown(for: attempt)
            },
            finalizeTerminal: { [self] observed in
                await finalizeTerminal(observed, attempt: attempt)
            }
        )
    }

    private func observeTerminal(
        for attempt: ReviewAttempt
    ) async throws -> ReviewBackendObservedTerminal {
        guard let activeReview = activeReviewSessionsByAttemptID[attempt.attemptID],
              activeReview.attempt == attempt else {
            return .failed(.protocolViolation(
                message: "Terminal observation requires the active SDK review session."
            ))
        }
        do {
            return AppServerReviewTerminalMapper.observed(
                try await activeReview.session.collect(),
                expectedAttempt: attempt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(AppServerReviewTerminalMapper.failure(error))
        }
    }

    private func observedTerminalIfKnown(
        for attempt: ReviewAttempt
    ) async -> ReviewBackendObservedTerminal? {
        guard let activeReview = activeReviewSessionsByAttemptID[attempt.attemptID],
              activeReview.attempt == attempt else {
            return .failed(.protocolViolation(
                message: "Terminal probing requires the active SDK review session."
            ))
        }
        do {
            guard let outcome = try await activeReview.session.terminalOutcomeIfKnown() else {
                return nil
            }
            return AppServerReviewTerminalMapper.observed(
                outcome,
                expectedAttempt: attempt
            )
        } catch is CancellationError {
            return nil
        } catch {
            return .failed(AppServerReviewTerminalMapper.failure(error))
        }
    }

    private func finalizeTerminal(
        _ observed: ReviewBackendObservedTerminal,
        attempt: ReviewAttempt
    ) async -> ReviewBackendTerminal {
        switch observed {
        case .completed(let candidate):
            // Do not directly await the refresh in the caller's task. Product
            // cancellation removes its waiter, but an accepted completion must
            // finish the authoritative DataKit publication barrier.
            return await Task { [self] in
                await publishCompletedReview(candidate, attempt: attempt)
            }.value
        case .interrupted(let message):
            return .interrupted(message: message)
        case .failed(let failure):
            return .failed(failure)
        }
    }

    private func publishCompletedReview(
        _ candidate: ReviewCompletionCandidate,
        attempt: ReviewAttempt
    ) async -> ReviewBackendTerminal {
        guard candidate.turnID == attempt.turnID else {
            return .failed(.protocolViolation(
                message: "Review completion candidate does not match its attempt turn."
            ))
        }
        guard let activeReview = activeReviewSessionsByAttemptID[attempt.attemptID],
              activeReview.attempt == attempt else {
            return .failed(.protocolViolation(
                message: "Output publication requires the active SDK review session."
            ))
        }
        let chat = activeReview.chat
        do {
            try await modelContext.refresh(chat, includeTurns: true)
        } catch {
            return .failed(.outputPublication(.refreshFailed(
                turnID: candidate.turnID,
                message: error.localizedDescription
            )))
        }

        let turnID = CodexTurnID(rawValue: candidate.turnID.rawValue)
        guard chat.turn(id: turnID) != nil else {
            return .failed(.outputPublication(.unavailable(turnID: candidate.turnID)))
        }
        guard let rawOutput = chat.transcript(in: turnID).reviewOutputText else {
            return .failed(.outputPublication(.empty(turnID: candidate.turnID)))
        }
        guard let projectedOutput = try? NonEmptyReviewOutput(validating: rawOutput) else {
            return .failed(.outputPublication(.empty(turnID: candidate.turnID)))
        }
        guard projectedOutput == candidate.expectedOutput else {
            return .failed(.outputPublication(.mismatched(turnID: candidate.turnID)))
        }
        return .completed(.init(finalReview: projectedOutput))
    }

    private func discardInvalidlyIdentifiedReview(
        _ session: CodexReviewSession
    ) async {
        await Task { [appServer] in
            do {
                _ = try await Self.interruptAndAwaitTerminal(session)
            } catch {
                appServerBackendLogger.error(
                    "Failed to cancel a review with invalid identity before cleanup: \(error.localizedDescription, privacy: .public)"
                )
            }
            await appServer.cleanupReview(session.identity)
        }.value
    }

    private func performReviewOperation<T>(
        _ operation: ReviewBackendOperationFailure.Operation,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ReviewBackendFailure {
            throw failure
        } catch let error as CodexAppServerError {
            throw AppServerReviewOperationFailureMapper.failure(error, operation: operation)
        } catch {
            appServerBackendLogger.error(
                "Unexpected review operation failure type \(String(reflecting: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw ReviewBackendFailure.protocolViolation(
                message: "Unexpected review operation failure: \(error.localizedDescription)"
            )
        }
    }

    private nonisolated static func reviewAttempt(
        for session: CodexReviewSession,
        attemptID: String,
        sourceThreadID: String? = nil,
        fallbackModel: String?
    ) throws -> ReviewAttempt {
        try ReviewAttempt(
            validatingAttemptID: attemptID,
            sourceThreadID: sourceThreadID ?? session.sourceThreadID.rawValue,
            activeTurnThreadID: session.activeTurnThreadID.rawValue,
            turnID: session.turnID.rawValue,
            model: session.model ?? fallbackModel
        )
    }

    private nonisolated static func reviewAttempt(
        for identity: CodexReviewIdentity,
        attemptID: String,
        fallbackModel: String?
    ) throws -> ReviewAttempt {
        try ReviewAttempt(
            validatingAttemptID: attemptID,
            sourceThreadID: identity.sourceThreadID.rawValue,
            activeTurnThreadID: identity.activeTurnThreadID.rawValue,
            turnID: identity.turnID.rawValue,
            model: identity.model ?? fallbackModel
        )
    }

    private func markAttemptAbandoned(_ attempt: ReviewAttempt) {
        abandonedReviewAttemptIDs.insert(attempt.attemptID)
    }

    private func markRestartInFlight(forInterrupted attempt: ReviewAttempt) {
        inFlightRestartCountByInterruptedAttemptID[attempt.attemptID, default: 0] += 1
    }

    private func clearRestartInFlight(forInterrupted attempt: ReviewAttempt) {
        let count = inFlightRestartCountByInterruptedAttemptID[attempt.attemptID, default: 0]
        if count <= 1 {
            inFlightRestartCountByInterruptedAttemptID.removeValue(forKey: attempt.attemptID)
        } else {
            inFlightRestartCountByInterruptedAttemptID[attempt.attemptID] = count - 1
        }
    }

    private func isRestartInFlight(forInterrupted attempt: ReviewAttempt) -> Bool {
        inFlightRestartCountByInterruptedAttemptID[attempt.attemptID] != nil
    }

    private func activeReviewAttemptsForShutdown() async -> [ReviewAttempt] {
        activeReviewSessionsByAttemptID.values.map(\.attempt)
    }

    private func cancelReviewTurn(
        for attempt: ReviewAttempt
    ) async throws -> CodexTurnCancellation {
        guard let activeReview = activeReviewSessionsByAttemptID[attempt.attemptID],
              activeReview.attempt == attempt else {
            throw ReviewBackendFailure.protocolViolation(
                message: "Interrupt requires the active SDK review session for its attempt."
            )
        }
        return try await Self.interruptAndAwaitTerminal(activeReview.session)
    }

    private nonisolated static func interruptAndAwaitTerminal(
        _ session: CodexReviewSession
    ) async throws -> CodexTurnCancellation {
        try await interruptAndAwaitTerminal(
            interrupt: { try await session.cancel() },
            awaitTerminal: { _ = try await session.collect() },
            terminalMayStillArriveAfterInterruptFailure: { error in
                Self.terminalMayStillArrive(afterInterruptFailure: error)
            }
        )
    }

    nonisolated static func interruptAndAwaitTerminal<Cancellation: Sendable>(
        interrupt: @escaping @Sendable () async throws -> Cancellation,
        awaitTerminal: @escaping @Sendable () async throws -> Void,
        terminalMayStillArriveAfterInterruptFailure:
            @escaping @Sendable (any Error) -> Bool
    ) async throws -> Cancellation {
        // Cleanup callers may themselves be cancelled while tearing down a run.
        // Keep terminal ownership only when a live connection can still deliver
        // the accepted interrupt's terminal after its acknowledgement failed.
        let interruption = Task {
            let cancellation: Cancellation
            do {
                cancellation = try await interrupt()
            } catch {
                let interruptError = error
                if terminalMayStillArriveAfterInterruptFailure(interruptError) {
                    try await awaitTerminal()
                }
                throw interruptError
            }
            try await awaitTerminal()
            return cancellation
        }
        return try await interruption.value
    }

    private nonisolated static func terminalMayStillArrive(
        afterInterruptFailure error: any Error
    ) -> Bool {
        guard case .request(let failure) = error as? CodexAppServerError else {
            return false
        }
        return terminalMayStillArrive(afterInterruptRequestFailure: failure.kind)
    }

    nonisolated static func terminalMayStillArrive(
        afterInterruptRequestFailure failure: CodexRequestFailure.Kind
    ) -> Bool {
        switch failure {
        case .invalidResponse:
            return true
        case .encode, .server, .overloadRetryExhausted:
            return false
        case .write, .transport, .deadlineExceeded:
            // CodexKit terminates the connection before surfacing a post-write
            // failure in these paths; their pre-write forms were never accepted.
            return false
        }
    }

    private func cleanupAppServerReview(
        _ attempt: ReviewAttempt
    ) async {
        await appServer.cleanupReview(attempt.appServerReviewIdentity)
    }

}

enum AppServerReviewTerminalMapper {
    static func observed(
        _ outcome: CodexTurnOutcome,
        expectedAttempt: ReviewAttempt
    ) -> ReviewBackendObservedTerminal {
        guard let turnID = try? ReviewTurnID(validating: outcome.response.turnID.rawValue) else {
            return .failed(.protocolViolation(message: "Review terminal has an empty turn ID."))
        }
        guard turnID == expectedAttempt.turnID else {
            return .failed(.protocolViolation(
                message: "Review terminal turn does not match its attempt."
            ))
        }
        switch outcome {
        case .completed(let response):
            guard let rawOutput = response.transcript.reviewOutputText,
                  let output = try? NonEmptyReviewOutput(validating: rawOutput) else {
                return .failed(.missingReviewOutput(turnID: turnID))
            }
            return .completed(.init(turnID: turnID, expectedOutput: output))
        case .interrupted:
            return .interrupted(message: nil)
        case .failed(let failedTurn):
            return .failed(.turnFailed(turnFailure(failedTurn.error)))
        case .invalidTerminalStatus(let rawStatus, let error, _):
            return .failed(
                .invalidTerminalStatus(
                    rawStatus: rawStatus,
                    turnID: turnID,
                    turnFailure: error.map(turnFailure)
                )
            )
        }
    }

    static func failure(_ error: any Error) -> ReviewBackendFailure {
        if let failure = error as? ReviewBackendFailure {
            return failure
        }
        guard let appServerError = error as? CodexAppServerError else {
            appServerBackendLogger.error(
                "Unexpected review terminal failure type \(String(reflecting: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .protocolViolation(
                message: "Unexpected review terminal failure: \(error.localizedDescription)"
            )
        }
        switch appServerError {
        case .connectionTerminated(let termination):
            return .connectionTerminated(AppServerReviewOperationFailureMapper.connectionTermination(termination))
        case .malformedNotification(let malformed):
            return .protocolViolation(message: malformed.localizedDescription)
        case .turnDeadlineExceeded(let turnID, let duration):
            return .protocolViolation(
                message: "Unexpected terminal collection deadline for turn \(turnID.rawValue): \(duration)"
            )
        case .launch, .request, .reviewRestartUnavailable, .loginAlreadyInProgress,
             .invalidAPIKey, .authenticationOutcomeUnknown:
            return .protocolViolation(
                message: "Unexpected terminal collection failure: \(appServerError.localizedDescription)"
            )
        }
    }

    static func turnFailure(_ error: CodexTurnError) -> ReviewTurnFailure {
        .init(
            message: error.message,
            code: error.info.map(turnFailureCode),
            additionalDetails: error.additionalDetails
        )
    }

    private static func turnFailureCode(_ info: CodexErrorInfo) -> ReviewTurnFailure.Code {
        switch info {
        case .contextWindowExceeded:
            .contextWindowExceeded
        case .sessionBudgetExceeded:
            .sessionBudgetExceeded
        case .usageLimitExceeded:
            .usageLimitExceeded
        case .serverOverloaded:
            .serverOverloaded
        case .cyberPolicy:
            .cyberPolicy
        case .httpConnectionFailed(let status):
            .httpConnectionFailed(status: status)
        case .responseStreamConnectionFailed(let status):
            .responseStreamConnectionFailed(status: status)
        case .internalServerError:
            .internalServerError
        case .unauthorized:
            .unauthorized
        case .badRequest:
            .badRequest
        case .threadRollbackFailed:
            .threadRollbackFailed
        case .sandboxError:
            .sandboxError
        case .responseStreamDisconnected(let status):
            .responseStreamDisconnected(status: status)
        case .responseTooManyFailedAttempts(let status):
            .responseTooManyFailedAttempts(status: status)
        case .activeTurnNotSteerable(let kind):
            .activeTurnNotSteerable(kind: kind)
        case .other:
            .other
        case .unknown(let rawValue):
            .unknown(rawValue: rawValue)
        }
    }
}

private enum AppServerReviewOperationFailureMapper {
    static func failure(
        _ error: CodexAppServerError,
        operation: ReviewBackendOperationFailure.Operation
    ) -> ReviewBackendFailure {
        let reason: ReviewBackendOperationFailure.Reason
        switch error {
        case .launch(let failure):
            reason = .launch(launchKind(failure))
        case .request(let failure):
            reason = .request(
                requestID: failure.requestID,
                method: failure.method,
                kind: requestKind(failure.kind)
            )
        case .connectionTerminated(let termination):
            reason = .connectionTerminated(connectionTermination(termination))
        case .turnDeadlineExceeded(let turnID, let duration):
            guard let reviewTurnID = try? ReviewTurnID(validating: turnID.rawValue) else {
                return .protocolViolation(message: "Review operation deadline has an empty turn ID.")
            }
            reason = .turnDeadlineExceeded(turnID: reviewTurnID, duration: duration)
        case .malformedNotification(let malformed):
            reason = .malformedNotification(method: malformed.method)
        case .reviewRestartUnavailable:
            reason = .reviewRestartUnavailable
        case .loginAlreadyInProgress, .invalidAPIKey, .authenticationOutcomeUnknown:
            return .protocolViolation(
                message: "A review operation unexpectedly reported an authentication failure."
            )
        }
        return .operation(.init(
            operation: operation,
            reason: reason,
            message: error.localizedDescription
        ))
    }

    static func connectionTermination(
        _ termination: CodexConnectionTermination
    ) -> ReviewBackendConnectionTermination {
        switch termination {
        case .closedByCaller:
            .closed
        case .transportFailure(let failure):
            .transport(message: failure.localizedDescription)
        case .processExited(let status):
            .processExited(status: status)
        }
    }

    private static func launchKind(
        _ failure: CodexLaunchFailure
    ) -> ReviewBackendOperationFailure.LaunchKind {
        switch failure {
        case .executableNotFound:
            .executableNotFound
        case .scaffold:
            .scaffold
        case .spawn:
            .spawn
        }
    }

    private static func requestKind(
        _ kind: CodexRequestFailure.Kind
    ) -> ReviewBackendOperationFailure.RequestKind {
        switch kind {
        case .encode:
            .encode
        case .write:
            .write
        case .transport:
            .transport
        case .server(let error):
            .server(
                code: error.code,
                turnFailure: error.turnError.map(AppServerReviewTerminalMapper.turnFailure)
            )
        case .invalidResponse(let expectedType, _, _):
            .invalidResponse(expectedType: expectedType)
        case .deadlineExceeded:
            .deadlineExceeded
        case .overloadRetryExhausted(let last, let attempts):
            .overloadRetryExhausted(
                lastCode: last.code,
                lastTurnFailure: last.turnError.map(AppServerReviewTerminalMapper.turnFailure),
                attempts: attempts
            )
        }
    }
}

private extension ReviewAttempt {
    var appServerReviewIdentity: CodexReviewIdentity {
        let sourceThreadID = CodexThreadID(rawValue: threadIdentity.sourceThreadID.rawValue)
        let activeTurnThreadID = CodexThreadID(rawValue: threadIdentity.activeTurnThreadID.rawValue)
        return CodexReviewIdentity(
            threadID: sourceThreadID,
            turnID: .init(rawValue: turnID.rawValue),
            reviewThreadID: activeTurnThreadID == sourceThreadID ? nil : activeTurnThreadID,
            model: model
        )
    }

}

private extension CodexAppServerKit.CodexAccount {
    var backendAccount: CodexReviewBackendModel.Account.Snapshot {
        let backendKind: CodexReviewBackendModel.Account.Kind =
            CodexReviewBackendModel.Account.Kind(rawValue: kind.rawValue) ?? .chatGPT
        return .init(
            id: CodexReviewBackendModel.Account.ID(id),
            kind: backendKind,
            label: label,
            isActive: true,
            planType: planType,
            capabilities: backendKind.capabilities
        )
    }
}

private extension CodexModel {
    var reviewModelCatalogItem: CodexReviewSettings.ModelCatalogItem {
        let reasoningOptions = supportedReasoningEfforts.compactMap { option in
            CodexReviewSettings.ReasoningEffort(rawValue: option.reasoningEffort.rawValue).map {
                CodexReviewSettings.ReasoningOption(reasoningEffort: $0, description: option.description)
            }
        }
        let defaultReasoningEffort =
            defaultReasoningEffort
            .flatMap { CodexReviewSettings.ReasoningEffort(rawValue: $0.rawValue) }
            ?? reasoningOptions.first?.reasoningEffort
            ?? .medium
        let serviceTiers = supportedServiceTiers.compactMap(CodexReviewSettings.ServiceTier.init(rawValue:))
        return .init(
            id: id,
            model: model,
            displayName: displayName,
            hidden: hidden,
            supportedReasoningEfforts: reasoningOptions,
            defaultReasoningEffort: defaultReasoningEffort,
            supportedServiceTiers: serviceTiers,
            isDefault: isDefault
        )
    }
}
