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

package actor AppServerCodexReviewBackend: CodexReviewBackend {
    private static let reviewPermissionProfileID = ":danger-full-access"

    private let appServer: CodexAppServer
    private var reviewEventSessionsByAttemptID: [String: AppServerReviewEventSession] = [:]
    private var activeReviewAttemptIDByThreadID: [String: String] = [:]
    private var activeThreadIDsByAttemptID: [String: Set<String>] = [:]
    private var reviewEventSessionCanonicalThreadIDByThreadID: [String: String] = [:]
    private var abandonedReviewAttemptIDs: Set<String> = []
    private var inFlightRestartCountByInterruptedAttemptID: [String: Int] = [:]
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

    package func startLogin(_: CodexReviewBackendModel.Login.Request) async throws
        -> CodexReviewBackendModel.Login.Challenge
    {
        let handle = try await appServer.loginChatGPT()
        return try handle.backendChallenge(
            nativeWebAuthenticationCallbackScheme: nil
        )
    }

    package func cancelLogin(_ challenge: CodexReviewBackendModel.Login.Challenge) async throws {
        try await appServer.cancelLogin(id: .init(rawValue: challenge.id))
    }

    package func logout(_: CodexReviewBackendModel.Account.ID) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        try await appServer.logout()
        return try await readAuth()
    }

    package func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt {
        let workspace = URL(fileURLWithPath: request.request.cwd, isDirectory: true)
        let review = try await appServer.startReview(
            in: workspace,
            target: request.request.target.appServerReviewTarget,
            options: reviewThreadOptions(request)
        )
        let attemptID = makeAppServerReviewAttemptID()
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: review.threadID.rawValue,
            turnID: review.turnID.rawValue,
            reviewThreadID: review.reviewThreadID.rawValue,
            model: review.model ?? request.model
        )
        let session = AppServerReviewEventSession(run: run)
        registerReviewEventSession(session, for: run)
        await session.startConsuming(review)

        return await session.attempt()
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

    package func interruptReview(
        _ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        guard abandonedReviewAttemptIDs.contains(run.attemptID) == false else {
            return
        }
        let session = await reviewEventSession(for: run)
        await session.requestCancellation(message: reason.message)
        do {
            _ = try await cancelReviewTurn(for: run)
            await finishReviewEventStream(
                threadID: run.threadID,
                cancellationMessage: reason.message
            )
        } catch {
            await session.clearCancellationRequest()
            throw error
        }
    }

    package func prepareReviewRestart(
        _ run: CodexReviewBackendModel.Review.Run
    ) async throws -> CodexReviewBackendModel.Review.RestartToken {
        guard let identity = run.appServerReviewIdentity else {
            throw CodexReviewAPI.Error.io("Review run has no restartable app-server turn.")
        }
        let appServerToken = try await appServer.prepareReviewRestart(identity)
        markAttemptAbandoned(run)
        if let session = unregisterReviewEventSession(for: run) {
            await session.abandon()
            let metrics = await session.metricsSnapshot()
            for threadID in localCleanupThreadIDs(for: run, additional: await session.cleanupThreadIDs()) {
                completedReviewEventSessionMetricsByThreadID[threadID] = metrics
            }
        }
        return CodexReviewBackendModel.Review.RestartToken(
            id: appServerToken.id,
            interruptedRun: run
        )
    }

    package func restartPreparedReview(
        _ token: CodexReviewBackendModel.Review.RestartToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        let interruptedRun = token.interruptedRun
        guard let interruptedIdentity = interruptedRun.appServerReviewIdentity else {
            throw CodexReviewAPI.Error.io("Prepared review restart has no app-server identity.")
        }
        let appServerToken = CodexReviewRestartToken(
            id: token.id,
            interruptedIdentity: interruptedIdentity
        )
        markRestartInFlight(forInterrupted: interruptedRun)
        defer {
            clearRestartInFlight(forInterrupted: interruptedRun)
        }
        let review = try await appServer.restartPreparedReview(
            appServerToken,
            target: request.request.target.appServerReviewTarget,
            threadOptions: .init(model: interruptedRun.model ?? request.model)
        )
        let attemptID = makeAppServerReviewAttemptID()
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: interruptedRun.threadID,
            turnID: review.turnID.rawValue,
            reviewThreadID: review.reviewThreadID.rawValue,
            model: review.model ?? interruptedRun.model ?? request.model
        )
        let session = AppServerReviewEventSession(run: recoveredRun)
        registerReviewEventSession(session, for: recoveredRun)
        await session.startConsuming(review)

        return await session.attempt()
    }

    package func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        var completedMetrics: ReviewBackendEventSessionMetrics?
        var additionalCleanupThreadIDs: [String] = []
        if let session = unregisterReviewEventSession(for: run) {
            await session.finish(cancellationMessage: nil)
            let metrics = await session.metricsSnapshot()
            additionalCleanupThreadIDs = await session.cleanupThreadIDs()
            completedMetrics = metrics
        }
        let cleanupThreadIDs = localCleanupThreadIDs(for: run, additional: additionalCleanupThreadIDs)
        if let completedMetrics {
            for threadID in cleanupThreadIDs {
                completedReviewEventSessionMetricsByThreadID[threadID] = completedMetrics
            }
        }
        await cleanupAppServerReview(run, additionalCleanupThreadIDs: additionalCleanupThreadIDs)
        for threadID in cleanupThreadIDs {
            reviewEventSessionCanonicalThreadIDByThreadID.removeValue(forKey: threadID)
            activeReviewAttemptIDByThreadID.removeValue(forKey: threadID)
        }
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
            if isRestartInFlight(forInterrupted: run) {
                continue
            }
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

    private func registerReviewEventSession(
        _ session: AppServerReviewEventSession,
        for run: CodexReviewBackendModel.Review.Run
    ) {
        reviewEventSessionsByAttemptID[run.attemptID] = session
        let activeThreadIDs = Set(run.appServerAssociatedThreadIDs)
        for threadID in activeThreadIDsByAttemptID[run.attemptID] ?? []
        where activeThreadIDs.contains(threadID) == false {
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
            reviewThreadID != run.threadID
        {
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

    private func unregisterReviewEventSession(for run: CodexReviewBackendModel.Review.Run)
        -> AppServerReviewEventSession?
    {
        let threadIDs =
            activeThreadIDsByAttemptID.removeValue(forKey: run.attemptID)
            ?? Set(run.appServerAssociatedThreadIDs)
        for threadID in threadIDs {
            if activeReviewAttemptIDByThreadID[threadID] == run.attemptID {
                activeReviewAttemptIDByThreadID.removeValue(forKey: threadID)
            }
        }
        return reviewEventSessionsByAttemptID.removeValue(forKey: run.attemptID)
    }

    private func markAttemptAbandoned(_ run: CodexReviewBackendModel.Review.Run) {
        abandonedReviewAttemptIDs.insert(run.attemptID)
    }

    private func markRestartInFlight(forInterrupted run: CodexReviewBackendModel.Review.Run) {
        inFlightRestartCountByInterruptedAttemptID[run.attemptID, default: 0] += 1
    }

    private func clearRestartInFlight(forInterrupted run: CodexReviewBackendModel.Review.Run) {
        let count = inFlightRestartCountByInterruptedAttemptID[run.attemptID, default: 0]
        if count <= 1 {
            inFlightRestartCountByInterruptedAttemptID.removeValue(forKey: run.attemptID)
        } else {
            inFlightRestartCountByInterruptedAttemptID[run.attemptID] = count - 1
        }
    }

    private func isRestartInFlight(forInterrupted run: CodexReviewBackendModel.Review.Run) -> Bool {
        inFlightRestartCountByInterruptedAttemptID[run.attemptID] != nil
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
        cancellationMessage: String?
    ) async {
        guard let session = reviewEventSession(forThreadID: threadID) else {
            return
        }
        await session.finish(cancellationMessage: cancellationMessage)
    }

    private func cancelReviewTurn(
        for run: CodexReviewBackendModel.Review.Run
    ) async throws -> CodexTurnCancellation {
        guard let identity = run.appServerReviewIdentity else {
            throw CodexReviewAPI.Error.io("Review run has no cancellable app-server turn.")
        }
        if let session = reviewEventSessionsByAttemptID[run.attemptID],
            let cancellation = try await session.cancelReview(
                expectedTurnID: identity.turnID.rawValue
            )
        {
            return cancellation
        }
        let review = try await appServer.resumeReview(
            identity,
            threadOptions: .init(model: run.model)
        )
        return try await review.cancel()
    }

    private func localCleanupThreadIDs(
        for run: CodexReviewBackendModel.Review.Run,
        additional: [String]
    ) -> [String] {
        let sourceThreadID = run.threadID
        var seen: Set<String> = []
        var threadIDs: [String] = []
        for sequence in [run.appServerCleanupThreadIDs, additional] {
            for threadID in sequence where threadID != sourceThreadID && seen.insert(threadID).inserted {
                threadIDs.append(threadID)
            }
        }
        if seen.insert(sourceThreadID).inserted {
            threadIDs.append(sourceThreadID)
        }
        return threadIDs
    }

    private func cleanupAppServerReview(
        _ run: CodexReviewBackendModel.Review.Run,
        additionalCleanupThreadIDs: [String]
    ) async {
        guard let identity = run.appServerReviewIdentity else {
            for threadID in localCleanupThreadIDs(for: run, additional: additionalCleanupThreadIDs) {
                try? await appServer.deleteThread(.init(rawValue: threadID))
            }
            return
        }
        await appServer.cleanupReview(
            identity,
            additionalCleanupThreadIDs: [additionalCleanupThreadIDs.map(CodexThreadID.init(rawValue:))]
        )
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
            events: [
                .started(
                    turnID: review.turnID.rawValue,
                    reviewThreadID: review.reviewThreadID.rawValue,
                    model: run.model
                )
            ],
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
        case .tokenUsageUpdated:
            .init(events: [], controlThreadID: controlThreadID)
        case .statusChanged(.idle), .statusChanged(.active(activeFlags: _)):
            .init(events: [], controlThreadID: controlThreadID)
        case .statusChanged(.notLoaded):
            .init(events: [.failed("Review thread is no longer loaded.")], controlThreadID: controlThreadID)
        case .statusChanged(.systemError):
            .init(events: [.failed("Review thread has a system error.")], controlThreadID: controlThreadID)
        case .statusChanged(.unknown(let status)):
            .init(
                events: unknownStatusEvents(status, turnID: review.turnID.rawValue),
                controlThreadID: controlThreadID
            )
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
        return [
            .completed(
                summary: "Succeeded.",
                result: response.finalAnswer?.nilIfEmpty
                    ?? response.transcript.finalAnswer?.nilIfEmpty
                    ?? response.transcript.responseText?.nilIfEmpty
            )
        ]
    }

    private static func unknownStatusEvents(
        _ status: String,
        turnID: String
    ) -> [CodexReviewBackendModel.Review.Event] {
        let seed = ReviewTimelineItemSeed(
            id: .init(rawValue: "\(turnID):status"),
            kind: .init(rawValue: "reviewThreadStatus"),
            family: .diagnostic,
            phase: .completed,
            content: .diagnostic(.init(message: "Review thread status changed: \(status)."))
        )
        return [.domainEvents([.itemCompleted(seed)])]
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
            return [
                .completed(
                    summary: "Succeeded.",
                    result: item.text?.nilIfEmpty
                )
            ]
        }
        guard item.kind != .userMessage,
            let seed = timelineSeed(for: item, phase: phase)
        else {
            return []
        }
        let domainEvent: ReviewDomainEvent =
            switch phase {
            case .started:
                .itemStarted(seed)
            case .updated:
                .itemUpdated(seed)
            case .completed:
                .itemCompleted(seed)
            }
        return [
            .domainEvents([domainEvent])
        ]
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
            .domainEvents([domainEvent])
        ]
    }

    private static func reasoningPartEvents(
        _ part: CodexReasoningPart
    ) -> [CodexReviewBackendModel.Review.Event] {
        let style: ReviewTimelineItem.Reasoning.Style =
            switch part.kind {
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
        return [.domainEvents([.itemStarted(seed)])]
    }

    private static func reasoningDeltaEvents(
        _ delta: CodexReasoningDelta
    ) -> [CodexReviewBackendModel.Review.Event] {
        guard delta.delta.isEmpty == false else {
            return []
        }
        let style: ReviewTimelineItem.Reasoning.Style =
            switch delta.part.kind {
            case .summary:
                .summary
            case .text:
                .raw
            }
        let domainEvent = ReviewDomainEvent.textDelta(
            itemID: .init(rawValue: delta.id),
            kind: .reasoning,
            family: .reasoning,
            content: .reasoning(.init(text: "", style: style)),
            delta: delta.delta
        )
        return [.domainEvents([domainEvent])]
    }

    private static func unknownEvents(
        _ raw: CodexRawNotification
    ) -> [CodexReviewBackendModel.Review.Event] {
        let itemID =
            raw.turnID?.rawValue
            ?? raw.threadID?.rawValue
            ?? raw.method
        let detail = String(data: raw.params, encoding: .utf8)
        let seed = ReviewTimelineItemSeed(
            id: .init(rawValue: "\(itemID):\(raw.method)"),
            kind: .init(rawValue: raw.method),
            family: .unknown,
            phase: .running,
            content: .unknown(
                .init(
                    title: raw.method,
                    detail: detail,
                    rawKind: .init(rawValue: raw.method)
                ))
        )
        return [.domainEvents([.itemUpdated(seed)])]
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
            .reasoning(
                .init(
                    text: reasoning.text,
                    style: reasoning.summary.isEmpty ? .raw : .summary
                ))
        case .command(let command):
            .command(
                .init(
                    command: command.command,
                    cwd: command.cwd,
                    output: command.output ?? "",
                    exitCode: command.exitCode,
                    status: command.status.map { .init(rawValue: $0.rawValue) }
                ))
        case .fileChange(let fileChange):
            .fileChange(
                .init(
                    title: "File changes",
                    output: fileChange.output ?? "",
                    paths: fileChange.path.map { [$0] } ?? [],
                    status: fileChange.status.map { .init(rawValue: $0.rawValue) }
                ))
        case .toolCall(let toolCall):
            .toolCall(
                .init(
                    namespace: toolCall.namespace,
                    server: toolCall.server,
                    tool: toolCall.name,
                    arguments: toolCall.arguments,
                    result: toolCall.result,
                    error: toolCall.error,
                    status: toolCall.status.map { .init(rawValue: $0.rawValue) }
                ))
        case .contextCompaction(let text):
            .contextCompaction(
                .init(
                    title: text?.nilIfEmpty ?? appServerContextCompactionStartedText,
                    status: logStatus(phase: .updated).map { .init(rawValue: $0) }
                ))
        case .diagnostic(let text):
            .diagnostic(
                .init(
                    message: text,
                    severity: kind == .error ? .error : nil
                ))
        case .log(let text):
            .unknown(.init(title: kind.rawValue, detail: text, rawKind: .init(rawValue: kind.rawValue)))
        case .unknown(let raw):
            .unknown(
                .init(
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

    func logStatus(phase: AppServerTypedItemPhase) -> String? {
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

    func finish(cancellationMessage: String?) async {
        cancelTypedReviewStream()
        await pipeline.finish(cancellationMessage: cancellationMessage)
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
        expectedTurnID _: String
    ) async throws -> CodexTurnCancellation? {
        guard let reviewSession else {
            return nil
        }
        return try await reviewSession.cancel()
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
        return [threadID]
    }

    var appServerCleanupThreadIDs: [String] {
        if let identity = appServerReviewIdentity {
            return identity.cleanupThreadIDs.map(\.rawValue)
        }
        return [threadID]
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
