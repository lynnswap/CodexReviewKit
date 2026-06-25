import Foundation
import CodexAppServerKit
import CodexReviewKit
import OSLog

private let appServerBackendLogger = Logger(
    subsystem: "CodexReviewKit",
    category: "app-server-backend"
)

private func makeAppServerReviewAttemptID() -> String {
    UUID().uuidString
}

private struct AppServerReviewCancellation: Equatable, Sendable {
    var threadID: String
    var turnID: String

    init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turnID = turnID
    }

    init(_ cancellation: CodexTurnCancellation) {
        self.init(
            threadID: cancellation.threadID.rawValue,
            turnID: cancellation.turnID?.rawValue ?? ""
        )
    }

    func cleanupIdentity(
        sourceRun run: CodexReviewBackendModel.Review.Run
    ) -> CodexReviewIdentity? {
        let turnID = turnID.nilIfEmpty ?? run.turnID?.nilIfEmpty
        guard let turnID else {
            return nil
        }
        let sourceThreadID = CodexThreadID(rawValue: run.threadID)
        let cancelledThreadID = CodexThreadID(rawValue: threadID)
        return CodexReviewIdentity(
            threadID: sourceThreadID,
            turnID: .init(rawValue: turnID),
            reviewThreadID: cancelledThreadID == sourceThreadID ? nil : cancelledThreadID,
            model: run.model
        )
    }
}

private struct AppServerReviewRestartContext: Sendable {
    var interruptedRun: CodexReviewBackendModel.Review.Run
    var rollbackThreadID: CodexThreadID
    var rollbackModel: String?
}

package actor AppServerCodexReviewBackend: CodexReviewBackend {
    private static let reviewPermissionProfileID = ":danger-full-access"

    private let appServer: CodexAppServer
    private var reviewEventSessionsByAttemptID: [String: AppServerReviewEventSession] = [:]
    private var activeReviewAttemptIDByThreadID: [String: String] = [:]
    private var activeThreadIDsByAttemptID: [String: Set<String>] = [:]
    private var reviewEventSessionCanonicalThreadIDByThreadID: [String: String] = [:]
    private var retainedCleanupIdentitiesBySourceThreadID: [String: [CodexReviewIdentity]] = [:]
    private var restartContextsByTokenID: [String: AppServerReviewRestartContext] = [:]
    private var abandonedReviewAttemptIDs: Set<String> = []
    private var completedReviewEventSessionMetricsByThreadID: [String: ReviewBackendEventSessionMetrics] = [:]

    package init(appServer: CodexAppServer) {
        self.appServer = appServer
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

    package func applySettings(_ change: CodexReviewBackendModel.Settings.Change) async throws -> CodexReviewBackendModel.Settings.Snapshot {
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

    package func startLogin(_ request: CodexReviewBackendModel.Login.Request) async throws -> CodexReviewBackendModel.Login.Challenge {
        let handle = try await appServer.loginChatGPT(
            callbackURLScheme: request.nativeWebAuthenticationCallbackScheme
        )
        return try handle.backendChallenge(
            nativeWebAuthenticationCallbackScheme: request.nativeWebAuthenticationCallbackScheme
        )
    }

    package func cancelLogin(_ challenge: CodexReviewBackendModel.Login.Challenge) async throws {
        try await appServer.cancelLogin(id: .init(rawValue: challenge.id))
    }

    package func completeLogin(_ response: CodexReviewBackendModel.Login.Response) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        if let callbackURL = response.callbackURL {
            guard let url = URL(string: callbackURL) else {
                throw CodexReviewAPI.Error.io("Invalid ChatGPT authentication callback URL.")
            }
            try await appServer.completeLogin(
                id: .init(rawValue: response.challengeID),
                callbackURL: url
            )
        }
        return try await readAuth()
    }

    package func logout(_: CodexReviewBackendModel.Account.ID) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        try await appServer.logout()
        return try await readAuth()
    }

    package func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt {
        let thread = try await startReviewThread(appServer: appServer, request: request)

        let attemptID = makeAppServerReviewAttemptID()
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: thread.id.rawValue,
            reviewThreadID: thread.id.rawValue,
            model: thread.model ?? request.model
        )
        let session = AppServerReviewEventSession(run: provisionalRun)
        registerReviewEventSession(session, for: provisionalRun)

        let review: CodexReviewSession
        do {
            review = try await thread.startReview(target: request.request.target.appServerReviewTarget)
        } catch {
            await cleanupReview(provisionalRun)
            throw error
        }

        let run = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: thread.id.rawValue,
            turnID: review.turnID.rawValue,
            reviewThreadID: review.reviewThreadID.rawValue,
            model: thread.model ?? request.model
        )
        await session.updateRun(run)
        registerReviewEventSession(session, for: run)
        await session.startConsuming(review)

        return await session.attempt()
    }

    private func startReviewThread(
        appServer: CodexAppServer,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> CodexThread {
        let workspace = URL(fileURLWithPath: request.request.cwd, isDirectory: true)
        return try await appServer.startThread(
            in: workspace,
            options: reviewThreadOptions(request)
        )
    }

    private func reviewThreadOptions(
        _ request: CodexReviewBackendModel.Review.Start
    ) -> CodexThread.Options {
        .init(
            model: request.model,
            approvalMode: .denyAll,
            permissions: .profile(id: Self.reviewPermissionProfileID),
            ephemeral: false,
            sessionStartSource: .startup,
            threadSource: .user
        )
    }

    package func interruptReview(_ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason) async throws {
        guard abandonedReviewAttemptIDs.contains(run.attemptID) == false else {
            return
        }
        let session = await reviewEventSession(for: run)
        await session.requestCancellation(message: reason.message)
        do {
            _ = try await cancelReviewTurn(for: run)
            await finishReviewEventStream(
                threadID: run.threadID,
                cancellationMessage: reason.message,
                buffersMissingContinuation: true
            )
        } catch {
            await session.clearCancellationRequest()
            throw error
        }
    }

    package func prepareReviewRestart(
        _ run: CodexReviewBackendModel.Review.Run
    ) async throws -> CodexReviewBackendModel.Review.RestartToken {
        let cancellation = try await cancelReviewTurn(for: run) { retryCancellation in
            await self.rememberCancellationCleanupIdentity(retryCancellation, canonicalThreadID: run.threadID)
        }
        markAttemptAbandoned(run, cancellation: cancellation)
        if let session = unregisterReviewEventSession(for: run) {
            await session.abandon()
            let metrics = await session.metricsSnapshot()
            let cleanupThreadIDs = orderedCleanupThreadIDs(
                sourceThreadID: run.threadID,
                cleanupThreadIDSequences(for: run) + [await session.cleanupThreadIDs()]
            )
            for threadID in cleanupThreadIDs {
                completedReviewEventSessionMetricsByThreadID[threadID] = metrics
            }
        }
        discardRestartContexts(for: run)
        let tokenID = UUID().uuidString
        restartContextsByTokenID[tokenID] = AppServerReviewRestartContext(
            interruptedRun: run,
            rollbackThreadID: .init(rawValue: cancellation.threadID),
            rollbackModel: run.model
        )
        return CodexReviewBackendModel.Review.RestartToken(
            id: tokenID,
            interruptedRun: run
        )
    }

    package func restartPreparedReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        guard let restartContext = restartContextsByTokenID.removeValue(forKey: token.id) else {
            throw CodexReviewAPI.Error.io("Prepared review restart is no longer available.")
        }
        let interruptedRun = restartContext.interruptedRun
        let rollbackThread = try await appServer.resumeThread(
            restartContext.rollbackThreadID,
            options: .init(model: restartContext.rollbackModel)
        )
        try await rollbackThread.rollback(turnCount: 1)

        let thread = try await sourceReviewThread(for: interruptedRun, fallbackModel: request.model)
        let attemptID = makeAppServerReviewAttemptID()
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: interruptedRun.threadID,
            reviewThreadID: interruptedRun.threadID,
            model: thread.model ?? interruptedRun.model ?? request.model
        )
        let session = AppServerReviewEventSession(run: provisionalRun)
        registerReviewEventSession(session, for: provisionalRun)

        let review: CodexReviewSession
        do {
            review = try await thread.startReview(target: request.request.target.appServerReviewTarget)
        } catch {
            _ = unregisterReviewEventSession(for: provisionalRun)
            await session.abandon()
            throw error
        }

        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: interruptedRun.threadID,
            turnID: review.turnID.rawValue,
            reviewThreadID: review.reviewThreadID.rawValue,
            model: thread.model ?? interruptedRun.model ?? request.model
        )
        await session.updateRun(recoveredRun)
        registerReviewEventSession(session, for: recoveredRun)
        await session.startConsuming(review)

        return await session.attempt()
    }

    package func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        discardRestartContexts(for: run)
        var cleanupSequences = cleanupThreadIDSequences(for: run)
        var completedMetrics: ReviewBackendEventSessionMetrics?
        if let session = unregisterReviewEventSession(for: run) {
            await session.finish(cancellationMessage: nil)
            let metrics = await session.metricsSnapshot()
            cleanupSequences.append(await session.cleanupThreadIDs())
            completedMetrics = metrics
        }
        let cleanupThreadIDs = orderedCleanupThreadIDs(
            sourceThreadID: run.threadID,
            cleanupSequences
        )
        if let completedMetrics {
            for threadID in cleanupThreadIDs {
                completedReviewEventSessionMetricsByThreadID[threadID] = completedMetrics
            }
        }
        for threadID in cleanupThreadIDs {
            try? await appServer.deleteThread(.init(rawValue: threadID))
        }
        for threadID in cleanupThreadIDs {
            reviewEventSessionCanonicalThreadIDByThreadID.removeValue(forKey: threadID)
            activeReviewAttemptIDByThreadID.removeValue(forKey: threadID)
        }
        retainedCleanupIdentitiesBySourceThreadID.removeValue(forKey: run.threadID)
    }

    package func cleanupActiveReviewsForShutdown(_ request: CodexReviewRuntimeStopReviewCleanupRequest) async {
        let runs = await activeReviewRunsForShutdown()
        var cleanedAttemptIDs: Set<String> = []
        for run in runs {
            if Task.isCancelled {
                return
            }
            try? await interruptReview(run, reason: request.reason)
            if Task.isCancelled {
                return
            }
            await cleanupReview(run)
            cleanedAttemptIDs.insert(run.attemptID)
        }
        for run in request.recoveryWaitingRuns where cleanedAttemptIDs.insert(run.attemptID).inserted {
            if Task.isCancelled {
                return
            }
            await cleanupReview(run)
        }
    }

    package func reviewEventSessionMetricsForTesting(
        threadID: String
    ) async -> ReviewBackendEventSessionMetrics? {
        if let session = reviewEventSession(forThreadID: threadID) {
            return await session.metricsSnapshot()
        }
        return completedReviewEventSessionMetricsByThreadID[threadID]
    }

    package func activeReviewEventStreamSubscriptionIDForTesting(threadID: String) async -> Int? {
        guard let session = reviewEventSession(forThreadID: threadID) else {
            return nil
        }
        return await session.activeStreamSubscriptionIDForTesting()
    }

    package func detachReviewEventStreamForTesting(threadID: String, subscriptionID: Int) async {
        guard let session = reviewEventSession(forThreadID: threadID) else {
            return
        }
        await session.detach(subscriptionID: subscriptionID)
    }

    package func reviewAttemptForTesting(_ run: CodexReviewBackendModel.Review.Run) async -> BackendReviewAttempt {
        let session = await reviewEventSession(for: run)
        return await session.attempt()
    }

    private func reviewEventSession(for run: CodexReviewBackendModel.Review.Run) async -> AppServerReviewEventSession {
        if let session = reviewEventSessionsByAttemptID[run.attemptID] {
            await session.updateRun(run)
            registerReviewEventSession(session, for: run)
            return session
        }
        let session = AppServerReviewEventSession(run: run)
        registerReviewEventSession(session, for: run)
        return session
    }

    private func sourceReviewThread(
        for run: CodexReviewBackendModel.Review.Run,
        fallbackModel: String?
    ) async throws -> CodexThread {
        try await appServer.resumeThread(
            .init(rawValue: run.threadID),
            options: .init(model: run.model ?? fallbackModel)
        )
    }

    private func registerReviewEventSession(
        _ session: AppServerReviewEventSession,
        for run: CodexReviewBackendModel.Review.Run
    ) {
        reviewEventSessionsByAttemptID[run.attemptID] = session
        let activeThreadIDs = Set(run.appServerAssociatedThreadIDs)
        for threadID in activeThreadIDsByAttemptID[run.attemptID] ?? [] where activeThreadIDs.contains(threadID) == false {
            if activeReviewAttemptIDByThreadID[threadID] == run.attemptID {
                activeReviewAttemptIDByThreadID.removeValue(forKey: threadID)
            }
        }
        activeThreadIDsByAttemptID[run.attemptID] = activeThreadIDs
        for threadID in activeThreadIDs {
            activeReviewAttemptIDByThreadID[threadID] = run.attemptID
        }
        reviewEventSessionCanonicalThreadIDByThreadID[run.threadID] = run.threadID
        if let reviewThreadID = run.reviewThreadID,
           reviewThreadID != run.threadID {
            reviewEventSessionCanonicalThreadIDByThreadID[reviewThreadID] = run.threadID
        }
    }

    private func reviewEventSession(forThreadID threadID: String) -> AppServerReviewEventSession? {
        let canonicalThreadID = reviewEventSessionCanonicalThreadIDByThreadID[threadID] ?? threadID
        let attemptID: String?
        if let directAttemptID = activeReviewAttemptIDByThreadID[threadID] {
            attemptID = directAttemptID
        } else if canonicalThreadID == threadID {
            attemptID = activeReviewAttemptIDByThreadID[canonicalThreadID]
        } else {
            attemptID = nil
        }
        guard let attemptID else { return nil }
        return reviewEventSessionsByAttemptID[attemptID]
    }

    private func unregisterReviewEventSession(for run: CodexReviewBackendModel.Review.Run) -> AppServerReviewEventSession? {
        let threadIDs = activeThreadIDsByAttemptID.removeValue(forKey: run.attemptID)
            ?? Set(run.appServerAssociatedThreadIDs)
        for threadID in threadIDs {
            if activeReviewAttemptIDByThreadID[threadID] == run.attemptID {
                activeReviewAttemptIDByThreadID.removeValue(forKey: threadID)
            }
        }
        return reviewEventSessionsByAttemptID.removeValue(forKey: run.attemptID)
    }

    private func markAttemptAbandoned(
        _ run: CodexReviewBackendModel.Review.Run,
        cancellation: AppServerReviewCancellation
    ) {
        abandonedReviewAttemptIDs.insert(run.attemptID)
        rememberCleanupIdentity(for: run)
        rememberCleanupIdentity(cancellation.cleanupIdentity(sourceRun: run))
    }

    private func rememberCancellationCleanupIdentity(
        _ cancellation: AppServerReviewCancellation,
        canonicalThreadID: String
    ) {
        let sourceRun = CodexReviewBackendModel.Review.Run(
            threadID: canonicalThreadID,
            turnID: cancellation.turnID,
            reviewThreadID: cancellation.threadID
        )
        rememberCleanupIdentity(cancellation.cleanupIdentity(sourceRun: sourceRun))
    }

    private func discardRestartContexts(for run: CodexReviewBackendModel.Review.Run) {
        restartContextsByTokenID = restartContextsByTokenID.filter { _, context in
            context.interruptedRun.attemptID != run.attemptID
        }
    }

    private func activeReviewRunsForShutdown() async -> [CodexReviewBackendModel.Review.Run] {
        let sessions = Array(reviewEventSessionsByAttemptID.values)
        var runsByAttemptID: [String: CodexReviewBackendModel.Review.Run] = [:]
        for session in sessions {
            let run = await session.currentRun()
            runsByAttemptID[run.attemptID] = run
        }
        return Array(runsByAttemptID.values)
    }

    private func finishReviewEventStream(
        threadID: String,
        cancellationMessage: String?,
        buffersMissingContinuation: Bool = false
    ) async {
        guard let session = reviewEventSession(forThreadID: threadID) else {
            return
        }
        await session.finish(
            cancellationMessage: cancellationMessage,
            buffersMissingContinuation: buffersMissingContinuation
        )
    }

    private func cancelReviewTurn(
        for run: CodexReviewBackendModel.Review.Run,
        willCancelActiveTurn: (@Sendable (AppServerReviewCancellation) async -> Void)? = nil
    ) async throws -> AppServerReviewCancellation {
        guard let identity = run.appServerReviewIdentity else {
            throw CodexReviewAPI.Error.io("Review run has no cancellable app-server turn.")
        }
        if let session = reviewEventSessionsByAttemptID[run.attemptID],
           let cancellation = try await session.cancelReview(
                expectedTurnID: identity.turnID.rawValue,
                willCancelActiveTurn: willCancelActiveTurn
           ) {
            return cancellation
        }
        let review = try await appServer.resumeReview(
            identity,
            threadOptions: .init(model: run.model)
        )
        let cancellation: CodexTurnCancellation
        if let willCancelActiveTurn {
            cancellation = try await review.cancel { retryCancellation in
                let reviewCancellation = AppServerReviewCancellation(retryCancellation)
                if reviewCancellation.turnID != identity.turnID.rawValue {
                    await willCancelActiveTurn(reviewCancellation)
                }
            }
        } else {
            cancellation = try await review.cancel()
        }
        return AppServerReviewCancellation(cancellation)
    }

    private func cleanupThreadIDSequences(
        for run: CodexReviewBackendModel.Review.Run
    ) -> [[String]] {
        let retainedSequences = retainedCleanupIdentitiesBySourceThreadID[run.threadID, default: []]
            .map { $0.cleanupThreadIDs.map(\.rawValue) }
        return retainedSequences + [run.appServerCleanupThreadIDs]
    }

    private func orderedCleanupThreadIDs(
        sourceThreadID: String,
        _ sequences: [[String]]
    ) -> [String] {
        var seen: Set<String> = []
        var threadIDs: [String] = []
        for sequence in sequences {
            for threadID in sequence where threadID != sourceThreadID && seen.insert(threadID).inserted {
                threadIDs.append(threadID)
            }
        }
        if seen.insert(sourceThreadID).inserted {
            threadIDs.append(sourceThreadID)
        }
        return threadIDs
    }

    private func rememberCleanupIdentity(
        for run: CodexReviewBackendModel.Review.Run
    ) {
        rememberCleanupIdentity(run.appServerReviewIdentity)
    }

    private func rememberCleanupIdentity(_ identity: CodexReviewIdentity?) {
        guard let identity else {
            return
        }
        let sourceThreadID = identity.sourceThreadID.rawValue
        if retainedCleanupIdentitiesBySourceThreadID[sourceThreadID, default: []].contains(identity) == false {
            retainedCleanupIdentitiesBySourceThreadID[sourceThreadID, default: []].append(identity)
        }
    }

}

private struct AppServerTypedReviewEvent: Sendable {
    var events: [CodexReviewBackendModel.Review.Event]
    var controlThreadID: String?

    init(
        events: [CodexReviewBackendModel.Review.Event],
        controlThreadID: String? = nil
    ) {
        self.events = events
        self.controlThreadID = controlThreadID
    }
}

private enum AppServerTypedItemPhase {
    case started
    case updated
    case completed
}

private enum AppServerTypedReviewEventAdapter {
    static func started(
        review: CodexReviewSession,
        run: CodexReviewBackendModel.Review.Run
    ) -> AppServerTypedReviewEvent {
        .init(
            events: [.started(
                turnID: review.turnID.rawValue,
                reviewThreadID: review.reviewThreadID.rawValue,
                model: run.model
            )],
            controlThreadID: review.reviewThreadID.rawValue
        )
    }

    static func convert(
        _ event: CodexReviewEvent,
        review: CodexReviewSession
    ) -> AppServerTypedReviewEvent {
        let controlThreadID = review.reviewThreadID.rawValue
        return switch event {
        case .turnStarted:
            .init(events: [], controlThreadID: controlThreadID)
        case .turnCompleted(let response):
            .init(events: terminalEvents(for: response), controlThreadID: controlThreadID)
        case .turnFailed(_, let message):
            .init(events: [.failed(message.nilIfEmpty ?? "Failed.")], controlThreadID: controlThreadID)
        case .itemStarted(let item, _):
            .init(events: itemEvents(item, phase: .started), controlThreadID: controlThreadID)
        case .itemUpdated(let item, _):
            .init(events: itemEvents(item, phase: .updated), controlThreadID: controlThreadID)
        case .itemCompleted(let item, _):
            .init(events: itemEvents(item, phase: .completed), controlThreadID: controlThreadID)
        case .message(let message, _):
            .init(events: messageEvents(message), controlThreadID: controlThreadID)
        case .messageDelta(let delta, _):
            .init(events: messageDeltaEvents(delta), controlThreadID: controlThreadID)
        case .reasoningSummaryPartAdded(let part, _):
            .init(events: reasoningPartEvents(part), controlThreadID: controlThreadID)
        case .reasoningDelta(let delta, _):
            .init(events: reasoningDeltaEvents(delta), controlThreadID: controlThreadID)
        case .tokenUsageUpdated, .statusChanged(.running):
            .init(events: [], controlThreadID: controlThreadID)
        case .statusChanged(.closed):
            .init(events: [.failed("Review thread is no longer loaded.")], controlThreadID: controlThreadID)
        case .statusChanged(.unknown(let status)):
            .init(events: [.logEntry(
                kind: .diagnostic,
                text: "Review thread status changed: \(status).",
                groupID: review.turnID.rawValue,
                replacesGroup: false
            )], controlThreadID: controlThreadID)
        case .closed:
            .init(events: [.failed("Review thread closed.")], controlThreadID: controlThreadID)
        case .unknown(let raw):
            .init(events: unknownEvents(raw), controlThreadID: controlThreadID)
        }
    }

    private static func terminalEvents(
        for response: CodexResponse
    ) -> [CodexReviewBackendModel.Review.Event] {
        if let message = response.errorMessage?.nilIfEmpty {
            return terminalFailureEvents(status: response.status, message: message)
        }
        if response.status?.isFailure == true {
            return terminalFailureEvents(
                status: response.status,
                message: response.status?.rawValue ?? "Failed."
            )
        }
        return [.completed(
            summary: "Succeeded.",
            result: response.finalAnswer?.nilIfEmpty
                ?? response.transcript.finalAnswer?.nilIfEmpty
                ?? response.transcript.responseText?.nilIfEmpty
        )]
    }

    private static func terminalFailureEvents(
        status: CodexTurnStatus?,
        message: String
    ) -> [CodexReviewBackendModel.Review.Event] {
        switch status {
        case .interrupted, .cancelled:
            [.cancelled(message)]
        case .failed, .running, .completed, .unknown, nil:
            [.failed(message)]
        }
    }

    private static func itemEvents(
        _ item: CodexThreadItem,
        phase: AppServerTypedItemPhase
    ) -> [CodexReviewBackendModel.Review.Event] {
        guard item.kind.rawValue != "enteredReviewMode" else {
            return []
        }
        if phase == .completed, item.kind.rawValue == "exitedReviewMode" {
            return [.completed(
                summary: "Succeeded.",
                result: item.text?.nilIfEmpty
            )]
        }
        guard item.kind != .userMessage,
              let seed = timelineSeed(for: item, phase: phase)
        else {
            return []
        }
        let domainEvent: ReviewDomainEvent = switch phase {
        case .started:
            .itemStarted(seed)
        case .updated:
            .itemUpdated(seed)
        case .completed:
            .itemCompleted(seed)
        }
        let legacyEvents = legacyLogEvents(for: item, phase: phase)
        return [.domainEvents(
            [domainEvent],
            legacyProjectionSuppressionCount: legacyEvents.legacyTimelineProjectionCount
        )] + legacyEvents.addingTerminalFailureLogProjectionSuppressionIfNeeded
    }

    private static func messageEvents(
        _ message: CodexMessage
    ) -> [CodexReviewBackendModel.Review.Event] {
        guard message.role != .user,
              message.text.isEmpty == false
        else {
            return []
        }
        let item = CodexThreadItem(
            id: message.id,
            kind: .agentMessage,
            content: .message(message)
        )
        return itemEvents(item, phase: .completed)
    }

    private static func messageDeltaEvents(
        _ delta: CodexMessageDelta
    ) -> [CodexReviewBackendModel.Review.Event] {
        guard delta.text.isEmpty == false else {
            return []
        }
        let itemID = delta.itemID?.nilIfEmpty ?? "agent-message-delta"
        let domainEvent = ReviewDomainEvent.textDelta(
            itemID: .init(rawValue: itemID),
            kind: .agentMessage,
            family: .message,
            content: .message(.init(text: "")),
            delta: delta.text
        )
        return [
            .domainEvents([domainEvent], legacyProjectionSuppressionCount: 1),
            .messageDelta(delta.text, itemID: itemID),
        ]
    }

    private static func reasoningPartEvents(
        _ part: CodexReasoningPart
    ) -> [CodexReviewBackendModel.Review.Event] {
        let style: ReviewTimelineItem.Reasoning.Style = switch part.kind {
        case .summary:
            .summary
        case .text:
            .raw
        }
        let seed = ReviewTimelineItemSeed(
            id: .init(rawValue: part.id),
            kind: .reasoning,
            family: .reasoning,
            phase: .running,
            content: .reasoning(.init(text: "", style: style))
        )
        return [.domainEvents([.itemStarted(seed)], legacyProjectionSuppressionCount: 0)]
    }

    private static func reasoningDeltaEvents(
        _ delta: CodexReasoningDelta
    ) -> [CodexReviewBackendModel.Review.Event] {
        guard delta.delta.isEmpty == false else {
            return []
        }
        let style: ReviewTimelineItem.Reasoning.Style
        let kind: ReviewLogEntry.Kind
        switch delta.part.kind {
        case .summary:
            style = .summary
            kind = .reasoningSummary
        case .text:
            style = .raw
            kind = .rawReasoning
        }
        let domainEvent = ReviewDomainEvent.textDelta(
            itemID: .init(rawValue: delta.id),
            kind: .reasoning,
            family: .reasoning,
            content: .reasoning(.init(text: "", style: style)),
            delta: delta.delta
        )
        return [
            .domainEvents([domainEvent], legacyProjectionSuppressionCount: 1),
            .logEntry(kind: kind, text: delta.delta, groupID: delta.id, replacesGroup: false),
        ]
    }

    private static func unknownEvents(
        _ raw: CodexRawNotification
    ) -> [CodexReviewBackendModel.Review.Event] {
        let itemID = raw.turnID?.rawValue
            ?? raw.threadID?.rawValue
            ?? raw.method
        let detail = String(data: raw.params, encoding: .utf8)
        let seed = ReviewTimelineItemSeed(
            id: .init(rawValue: "\(itemID):\(raw.method)"),
            kind: .init(rawValue: raw.method),
            family: .unknown,
            phase: .running,
            content: .unknown(.init(
                title: raw.method,
                detail: detail,
                rawKind: .init(rawValue: raw.method)
            ))
        )
        return [.domainEvents([.itemUpdated(seed)], legacyProjectionSuppressionCount: 0)]
    }

    private static func timelineSeed(
        for item: CodexThreadItem,
        phase: AppServerTypedItemPhase
    ) -> ReviewTimelineItemSeed? {
        ReviewTimelineItemSeed(
            id: .init(rawValue: item.id),
            kind: .init(rawValue: item.kind.rawValue),
            family: item.reviewItemFamily,
            phase: item.reviewItemPhase(defaultingTo: phase),
            content: item.reviewTimelineContent
        )
    }

    private static func legacyLogEvents(
        for item: CodexThreadItem,
        phase: AppServerTypedItemPhase
    ) -> [CodexReviewBackendModel.Review.Event] {
        switch item.content {
        case .message(let message):
            guard message.role != .user,
                  message.text.isEmpty == false
            else {
                return []
            }
            return [item.logEntry(
                kind: .agentMessage,
                text: message.text,
                phase: phase,
                title: nil
            )]
        case .plan(let text):
            return text.nilIfEmpty.map {
                [item.logEntry(kind: .plan, text: $0, phase: phase, title: nil)]
            } ?? []
        case .reasoning(let reasoning):
            let summaryEvents = reasoning.summary.enumerated().compactMap { index, text in
                text.nilIfEmpty.map {
                    CodexReviewBackendModel.Review.Event.logEntry(
                        kind: .reasoningSummary,
                        text: $0,
                        groupID: reasoningSummaryGroupID(itemID: item.id, summaryIndex: index),
                        replacesGroup: phase != .started
                    )
                }
            }
            let rawEvents = reasoning.content.enumerated().compactMap { index, text in
                text.nilIfEmpty.map {
                    CodexReviewBackendModel.Review.Event.logEntry(
                        kind: .rawReasoning,
                        text: $0,
                        groupID: rawReasoningGroupID(itemID: item.id, contentIndex: index),
                        replacesGroup: phase != .started
                    )
                }
            }
            return summaryEvents + rawEvents
        case .command(let command):
            return commandLogEvents(item: item, command: command, phase: phase)
        case .fileChange(let fileChange):
            let text = fileChange.output?.nilIfEmpty
                ?? fileChange.path?.nilIfEmpty
                ?? "File changes \(item.legacyStatus(phase: phase) ?? "updated")."
            let kind: ReviewLogEntry.Kind = fileChange.output?.nilIfEmpty == nil ? .toolCall : .commandOutput
            return [item.logEntry(
                kind: kind,
                text: text,
                phase: phase,
                title: "File changes"
            )]
        case .toolCall(let toolCall):
            let label = item.toolLabel
            let text = toolCall.error?.nilIfEmpty
                ?? toolCall.result?.nilIfEmpty
                ?? "\(label) \(item.legacyStatus(phase: phase) ?? "updated")."
            return [item.logEntry(
                kind: .toolCall,
                text: text,
                phase: phase,
                title: label
            )]
        case .contextCompaction(let text):
            return [item.logEntry(
                kind: .contextCompaction,
                text: text?.nilIfEmpty ?? contextCompactionText(phase: phase, status: item.legacyStatus(phase: phase)),
                phase: phase,
                title: nil
            )]
        case .diagnostic(let text):
            return text.nilIfEmpty.map {
                [item.logEntry(kind: .diagnostic, text: $0, phase: phase, title: nil)]
            } ?? []
        case .log(let text):
            return text.nilIfEmpty.map {
                [item.logEntry(kind: .event, text: $0, phase: phase, title: item.kind.rawValue)]
            } ?? []
        case .unknown(let raw):
            return raw.text?.nilIfEmpty.map {
                [item.logEntry(kind: .event, text: $0, phase: phase, title: raw.rawType)]
            } ?? []
        }
    }

    private static func commandLogEvents(
        item: CodexThreadItem,
        command: CodexCommand,
        phase: AppServerTypedItemPhase
    ) -> [CodexReviewBackendModel.Review.Event] {
        var events: [CodexReviewBackendModel.Review.Event] = []
        if command.command.isEmpty == false {
            events.append(item.logEntry(
                kind: .command,
                text: "$ \(command.command)",
                phase: phase,
                title: nil
            ))
        }
        let output = command.output?.nilIfEmpty
        if let output {
            if command.command.isEmpty {
                events.append(item.commandOutputDeltaLogEntry(text: output))
            } else {
                events.append(item.logEntry(
                    kind: .commandOutput,
                    text: output,
                    phase: phase,
                    title: nil
                ))
            }
        }
        return events
    }

    private static func contextCompactionText(
        phase: AppServerTypedItemPhase,
        status: String?
    ) -> String {
        switch phase {
        case .started, .updated:
            return appServerContextCompactionStartedText
        case .completed:
            let normalized = status?
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            switch normalized {
            case "failed", "failure", "errored", "error":
                return appServerContextCompactionFailedText
            case "cancelled", "canceled":
                return appServerContextCompactionCancelledText
            default:
                return appServerContextCompactionCompletedText
            }
        }
    }
}

private extension CodexThreadItem {
    var reviewItemFamily: ReviewItemFamily {
        switch kind {
        case .agentMessage:
            .message
        case .plan:
            .plan
        case .reasoning:
            .reasoning
        case .commandExecution:
            .command
        case .fileChange:
            .fileChange
        case .mcpToolCall, .dynamicToolCall, .collabAgentToolCall, .imageView, .imageGeneration, .sleep:
            .tool
        case .webSearch:
            .search
        case .contextCompaction:
            .contextCompaction
        case .diagnostic, .error:
            .diagnostic
        case .userMessage, .subAgentActivity, .unknown:
            .unknown
        }
    }

    var reviewTimelineContent: ReviewTimelineItem.Content {
        switch content {
        case .message(let message):
            .message(.init(text: message.text))
        case .plan(let text):
            .plan(.init(markdown: text))
        case .reasoning(let reasoning):
            .reasoning(.init(
                text: reasoning.text,
                style: reasoning.summary.isEmpty ? .raw : .summary
            ))
        case .command(let command):
            .command(.init(
                command: command.command,
                cwd: command.cwd,
                output: command.output ?? "",
                exitCode: command.exitCode,
                status: command.status.map { .init(rawValue: $0.rawValue) }
            ))
        case .fileChange(let fileChange):
            .fileChange(.init(
                title: "File changes",
                output: fileChange.output ?? "",
                paths: fileChange.path.map { [$0] } ?? [],
                status: fileChange.status.map { .init(rawValue: $0.rawValue) }
            ))
        case .toolCall(let toolCall):
            .toolCall(.init(
                namespace: toolCall.namespace,
                server: toolCall.server,
                tool: toolCall.name,
                arguments: toolCall.arguments,
                result: toolCall.result,
                error: toolCall.error,
                status: toolCall.status.map { .init(rawValue: $0.rawValue) }
            ))
        case .contextCompaction(let text):
            .contextCompaction(.init(
                title: text?.nilIfEmpty ?? appServerContextCompactionStartedText,
                status: legacyStatus(phase: .updated).map { .init(rawValue: $0) }
            ))
        case .diagnostic(let text):
            .diagnostic(.init(
                message: text,
                severity: kind == .error ? .error : nil
            ))
        case .log(let text):
            .unknown(.init(title: kind.rawValue, detail: text, rawKind: .init(rawValue: kind.rawValue)))
        case .unknown(let raw):
            .unknown(.init(
                title: raw.rawType,
                detail: raw.text,
                rawKind: .init(rawValue: raw.rawType)
            ))
        }
    }

    func reviewItemPhase(defaultingTo phase: AppServerTypedItemPhase) -> ReviewItemPhase {
        if let status = statusRaw?.nilIfEmpty {
            let normalized = ReviewItemPhase.normalized(status)
            if phase == .completed, normalized == .running {
                return .completed
            }
            return normalized
        }
        return switch phase {
        case .started, .updated:
            .running
        case .completed:
            .completed
        }
    }

    var statusRaw: String? {
        switch content {
        case .command(let command):
            command.status?.rawValue
        case .fileChange(let fileChange):
            fileChange.status?.rawValue
        case .toolCall(let toolCall):
            toolCall.status?.rawValue
        case .contextCompaction, .diagnostic, .log, .message, .plan, .reasoning, .unknown:
            nil
        }
    }

    var toolLabel: String {
        guard case .toolCall(let toolCall) = content else {
            return kind.rawValue
        }
        return [toolCall.namespace, toolCall.server, toolCall.name]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: ".")
            .nilIfEmpty ?? kind.rawValue
    }

    func legacyStatus(phase: AppServerTypedItemPhase) -> String? {
        if let status = statusRaw?.nilIfEmpty {
            return status
        }
        return switch phase {
        case .started:
            "inProgress"
        case .updated:
            nil
        case .completed:
            "completed"
        }
    }

    func logEntry(
        kind logKind: ReviewLogEntry.Kind,
        text: String,
        phase: AppServerTypedItemPhase,
        title: String?
    ) -> CodexReviewBackendModel.Review.Event {
        .logEntry(
            kind: logKind,
            text: text,
            groupID: id,
            replacesGroup: phase != .started,
            metadata: reviewLogMetadata(title: title, phase: phase)
        )
    }

    func commandOutputDeltaLogEntry(text: String) -> CodexReviewBackendModel.Review.Event {
        .logEntry(
            kind: .commandOutput,
            text: text,
            groupID: id,
            replacesGroup: false,
            metadata: reviewLogMetadata(title: "Command output", phase: .updated)
        )
    }

    private func reviewLogMetadata(
        title: String?,
        phase: AppServerTypedItemPhase
    ) -> ReviewLogEntry.Metadata {
        let status = legacyStatus(phase: phase)
        let command: CodexCommand?
        let fileChange: CodexFileChange?
        let toolCall: CodexToolCall?
        switch content {
        case .command(let value):
            command = value
            fileChange = nil
            toolCall = nil
        case .fileChange(let value):
            command = nil
            fileChange = value
            toolCall = nil
        case .toolCall(let value):
            command = nil
            fileChange = nil
            toolCall = value
        case .contextCompaction, .diagnostic, .log, .message, .plan, .reasoning, .unknown:
            command = nil
            fileChange = nil
            toolCall = nil
        }
        return .init(
            sourceType: kind.rawValue,
            title: title?.nilIfEmpty,
            status: status,
            itemID: kind == .commandExecution || kind == .contextCompaction ? id : nil,
            command: command?.command,
            cwd: command?.cwd,
            exitCode: command?.exitCode,
            commandStatus: kind == .commandExecution ? status : nil,
            namespace: toolCall?.namespace,
            server: toolCall?.server,
            tool: toolCall?.name,
            path: fileChange?.path,
            resultText: toolCall?.result?.nilIfEmpty,
            errorText: toolCall?.error?.nilIfEmpty
        )
    }
}

private actor AppServerReviewEventSession {
    private let pipeline: ReviewBackendEventSession
    private var typedReviewStreamTask: Task<Void, Never>?
    private var reviewSession: CodexReviewSession?

    init(
        run: CodexReviewBackendModel.Review.Run,
        mailbox: BackendReviewEventMailbox = .init()
    ) {
        self.pipeline = ReviewBackendEventSession(
            run: run,
            mailbox: mailbox,
            callbacks: .init(
                recordFinished: { run, metrics in
                    appServerBackendLogger.debug(
                        "Review event session finished for \(run.threadID, privacy: .public): emitted=\(metrics.emitted, privacy: .public) buffered=\(metrics.buffered, privacy: .public) ignored=\(metrics.ignored, privacy: .public) timeoutWarnings=\(metrics.commandTimeoutWarnings, privacy: .public)"
                    )
                }
            )
        )
    }

    func updateRun(_ run: CodexReviewBackendModel.Review.Run) async {
        await pipeline.updateRun(run)
    }

    func currentRun() async -> CodexReviewBackendModel.Review.Run {
        await pipeline.currentRun()
    }

    func attempt() async -> BackendReviewAttempt {
        await pipeline.attempt()
    }

    func cleanupThreadIDs() async -> [String] {
        await pipeline.cleanupThreadIDs()
    }

    func requestCancellation(message: String) async {
        await pipeline.requestCancellation(message: message)
    }

    func clearCancellationRequest() async {
        await pipeline.clearCancellationRequest()
    }

    func finish(
        cancellationMessage: String?,
        buffersMissingContinuation: Bool = false
    ) async {
        cancelTypedReviewStream()
        await pipeline.finish(
            cancellationMessage: cancellationMessage,
            buffersMissingContinuation: buffersMissingContinuation
        )
    }

    func finish(throwing error: (any Error)?) async {
        cancelTypedReviewStream()
        await pipeline.finish(throwing: error)
    }

    func abandon() async {
        cancelTypedReviewStream()
        await pipeline.abandon()
    }

    func metricsSnapshot() async -> ReviewBackendEventSessionMetrics {
        await pipeline.metricsSnapshot()
    }

    func activeStreamSubscriptionIDForTesting() -> Int? {
        nil
    }

    func detach(subscriptionID _: Int) {}

    func startConsuming(_ review: CodexReviewSession) {
        guard typedReviewStreamTask == nil else {
            return
        }
        reviewSession = review
        typedReviewStreamTask = Task { [weak self] in
            await self?.consume(review)
        }
    }

    func cancelReview(
        expectedTurnID: String,
        willCancelActiveTurn: (@Sendable (AppServerReviewCancellation) async -> Void)? = nil
    ) async throws -> AppServerReviewCancellation? {
        guard let reviewSession else {
            return nil
        }
        let cancellation: CodexTurnCancellation
        if let willCancelActiveTurn {
            cancellation = try await reviewSession.cancel { retryCancellation in
                let reviewCancellation = AppServerReviewCancellation(retryCancellation)
                if reviewCancellation.turnID != expectedTurnID {
                    await willCancelActiveTurn(reviewCancellation)
                }
            }
        } else {
            cancellation = try await reviewSession.cancel()
        }
        return AppServerReviewCancellation(cancellation)
    }

    private func consume(_ review: CodexReviewSession) async {
        defer {
            typedReviewStreamTask = nil
            if reviewSession?.id == review.id {
                reviewSession = nil
            }
        }
        let run = await pipeline.currentRun()
        await receive(AppServerTypedReviewEventAdapter.started(review: review, run: run))
        do {
            for try await event in review.events {
                if Task.isCancelled {
                    return
                }
                await receive(AppServerTypedReviewEventAdapter.convert(event, review: review))
            }
            await finish(throwing: nil)
        } catch is CancellationError {
            await finish(throwing: CancellationError())
        } catch {
            await finish(throwing: error)
        }
    }

    private func receive(_ converted: AppServerTypedReviewEvent) async {
        await pipeline.receive(converted.events, controlThreadID: converted.controlThreadID)
    }

    private func cancelTypedReviewStream() {
        typedReviewStreamTask?.cancel()
        typedReviewStreamTask = nil
        reviewSession = nil
    }
}

private extension CodexReviewBackendModel.Review.Run {
    var appServerReviewIdentity: CodexReviewIdentity? {
        guard let turnID = turnID?.nilIfEmpty else {
            return nil
        }
        let sourceThreadID = CodexThreadID(rawValue: threadID)
        let reviewThreadID = reviewThreadID?.nilIfEmpty.map(CodexThreadID.init(rawValue:))
        return CodexReviewIdentity(
            threadID: sourceThreadID,
            turnID: .init(rawValue: turnID),
            reviewThreadID: reviewThreadID == sourceThreadID ? nil : reviewThreadID,
            model: model
        )
    }

    var appServerAssociatedThreadIDs: [String] {
        if let identity = appServerReviewIdentity {
            return identity.associatedThreadIDs.map(\.rawValue)
        }
        return fallbackThreadIDs(sourceLast: false)
    }

    var appServerCleanupThreadIDs: [String] {
        if let identity = appServerReviewIdentity {
            return identity.cleanupThreadIDs.map(\.rawValue)
        }
        return fallbackThreadIDs(sourceLast: true)
    }

    private func fallbackThreadIDs(sourceLast: Bool) -> [String] {
        var seen: Set<String> = []
        var threadIDs: [String] = []
        let reviewThreadID = reviewThreadID?.nilIfEmpty
        if sourceLast,
           let reviewThreadID,
           reviewThreadID != threadID,
           seen.insert(reviewThreadID).inserted {
            threadIDs.append(reviewThreadID)
        }
        if seen.insert(threadID).inserted {
            threadIDs.append(threadID)
        }
        if sourceLast == false,
           let reviewThreadID,
           reviewThreadID != threadID,
           seen.insert(reviewThreadID).inserted {
            threadIDs.append(reviewThreadID)
        }
        return threadIDs
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
        let defaultReasoningEffort = defaultReasoningEffort
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

private extension CodexLoginHandle {
    func backendChallenge(
        nativeWebAuthenticationCallbackScheme: String?
    ) throws -> CodexReviewBackendModel.Login.Challenge {
        switch self {
        case .apiKey:
            return .init(id: "api-key")
        case .chatGPT(let loginID, let authenticationURL):
            return .init(
                id: loginID.rawValue,
                verificationURL: authenticationURL,
                nativeWebAuthenticationCallbackScheme: nativeWebAuthenticationCallbackScheme
            )
        case .chatGPTDeviceCode(let loginID, let verificationURL, let userCode):
            return .init(
                id: loginID.rawValue,
                verificationURL: verificationURL,
                userCode: userCode
            )
        }
    }
}

private let appServerContextCompactionStartedText = "Automatically compacting context"
private let appServerContextCompactionCompletedText = "Context automatically compacted"
private let appServerContextCompactionFailedText = "Context compaction failed"
private let appServerContextCompactionCancelledText = "Context compaction cancelled"

private func reasoningSummaryGroupID(itemID: String, summaryIndex: Int) -> String {
    "\(itemID):summary:\(summaryIndex)"
}

private func rawReasoningGroupID(itemID: String, contentIndex: Int) -> String {
    "\(itemID):\(contentIndex)"
}
