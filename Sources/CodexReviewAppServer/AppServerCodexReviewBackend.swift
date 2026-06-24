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
    private var controlsByThreadID: [String: AppServerReviewControl] = [:]
    private var reviewEventSessionsByAttemptID: [String: AppServerReviewEventSession] = [:]
    private var activeReviewAttemptIDByThreadID: [String: String] = [:]
    private var activeThreadIDsByAttemptID: [String: Set<String>] = [:]
    private var reviewEventSessionCanonicalThreadIDByThreadID: [String: String] = [:]
    private var reviewThreadIDsForCleanupByThreadID: [String: Set<String>] = [:]
    private var threadsByThreadID: [String: CodexThread] = [:]
    private var abandonedReviewAttemptIDs: Set<String> = []
    private var abandonedTurnIDs: Set<String> = []
    private var completedReviewEventSessionMetricsByThreadID: [String: AppServerReviewEventSessionMetrics] = [:]

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
        guard change.updatesModel == false,
              change.updatesReasoningEffort == false,
              change.updatesServiceTier == false
        else {
            throw CodexReviewAPI.Error.io(
                "Updating app-server review settings requires a public CodexKit configuration update API."
            )
        }
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

    package func startLogin(_: CodexReviewBackendModel.Login.Request) async throws -> CodexReviewBackendModel.Login.Challenge {
        let handle = try await appServer.loginChatGPT()
        return try handle.backendChallenge(nativeWebAuthenticationCallbackScheme: nil)
    }

    package func cancelLogin(_ challenge: CodexReviewBackendModel.Login.Challenge) async throws {
        try await appServer.cancelLogin(id: .init(rawValue: challenge.id))
    }

    package func completeLogin(_ response: CodexReviewBackendModel.Login.Response) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        if let callbackURL = response.callbackURL {
            guard let url = URL(string: callbackURL) else {
                throw CodexReviewAPI.Error.io("Invalid ChatGPT authentication callback URL.")
            }
            _ = url
            throw CodexReviewAPI.Error.io(
                "Completing native ChatGPT authentication callbacks requires a public CodexKit login completion API."
            )
        }
        return try await readAuth()
    }

    package func logout(_: CodexReviewBackendModel.Account.ID) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        try await appServer.logout()
        return try await readAuth()
    }

    package func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt {
        let control = AppServerReviewControl()
        let thread = try await startReviewThread(appServer: appServer, request: request)
        threadsByThreadID[thread.id.rawValue] = thread
        controlsByThreadID[thread.id.rawValue] = control

        let attemptID = makeAppServerReviewAttemptID()
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: thread.id.rawValue,
            reviewThreadID: thread.id.rawValue,
            model: thread.model ?? request.model
        )
        let session = AppServerReviewEventSession(run: provisionalRun, control: control)
        registerReviewEventSession(session, for: provisionalRun)
        control.recordThreadStarted()

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
        control.recordReviewStarted(review)
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
            _ = try await sendTurnInterrupt(for: run)
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

    package func beginReviewRecovery(
        _ run: CodexReviewBackendModel.Review.Run,
        reason _: CodexReviewBackendModel.CancellationReason
    ) async throws -> CodexReviewBackendModel.Review.RecoveryToken {
        markTurnAbandoned(run.turnID)
        let interruption = try await sendTurnInterrupt(for: run) { retryInterruption in
            await self.markInterruptionTurnAbandoned(retryInterruption, canonicalThreadID: run.threadID)
        }
        markAttemptAbandoned(run, interruption: interruption)
        if let session = unregisterReviewEventSession(for: run) {
            await session.abandon()
            let metrics = await session.metricsSnapshot()
            for threadID in await session.cleanupThreadIDs() {
                completedReviewEventSessionMetricsByThreadID[threadID] = metrics
            }
        }
        return CodexReviewBackendModel.Review.RecoveryToken(
            interruptedRun: run,
            rollbackThreadID: interruption.threadID
        )
    }

    package func resumeReviewRecovery(
        _ token: CodexReviewBackendModel.Review.RecoveryToken,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        let interruptedRun = token.interruptedRun
        let rollbackThread = try await threadHandle(id: token.rollbackThreadID, model: interruptedRun.model)
        try await rollbackThread.rollback(turnCount: 1)

        let control = reviewControl(for: interruptedRun)
        let thread = try await reviewThread(for: interruptedRun)
        let attemptID = makeAppServerReviewAttemptID()
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: interruptedRun.threadID,
            reviewThreadID: interruptedRun.threadID,
            model: thread.model ?? interruptedRun.model ?? request.model
        )
        let session = AppServerReviewEventSession(run: provisionalRun, control: control)
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
        controlsByThreadID[interruptedRun.threadID]?.recordReviewStarted(review)
        await session.startConsuming(review)

        return await session.attempt()
    }

    package func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        controlsByThreadID.removeValue(forKey: run.threadID)
        var cleanupThreadIDs = cleanupThreadIDs(for: run)
        if let session = unregisterReviewEventSession(for: run) {
            await session.finish(cancellationMessage: nil)
            let metrics = await session.metricsSnapshot()
            cleanupThreadIDs = mergedCleanupThreadIDs(cleanupThreadIDs, await session.cleanupThreadIDs())
            for threadID in cleanupThreadIDs {
                completedReviewEventSessionMetricsByThreadID[threadID] = metrics
            }
        }
        for threadID in cleanupThreadIDs {
            guard let thread = try? await threadHandle(id: threadID, model: run.model) else {
                continue
            }
            try? await thread.delete()
        }
        for threadID in cleanupThreadIDs {
            reviewEventSessionCanonicalThreadIDByThreadID.removeValue(forKey: threadID)
            activeReviewAttemptIDByThreadID.removeValue(forKey: threadID)
            threadsByThreadID.removeValue(forKey: threadID)
        }
        reviewThreadIDsForCleanupByThreadID.removeValue(forKey: run.threadID)
    }

    package func cleanupActiveReviewsForShutdown(reason: CodexReviewBackendModel.CancellationReason) async {
        let runs = await activeReviewRunsForShutdown()
        guard runs.isEmpty == false else {
            return
        }
        for run in runs {
            if Task.isCancelled {
                return
            }
            try? await interruptReview(run, reason: reason)
            if Task.isCancelled {
                return
            }
            await cleanupReview(run)
        }
    }

    package func interruptActiveReviewsForShutdown(reason: CodexReviewBackendModel.CancellationReason) async {
        let runs = await activeReviewRunsForShutdown()
        guard runs.isEmpty == false else {
            return
        }
        for run in runs {
            if Task.isCancelled {
                return
            }
            try? await interruptReview(run, reason: reason)
        }
    }

    package func reviewEventSessionMetricsForTesting(
        threadID: String
    ) async -> AppServerReviewEventSessionMetrics? {
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
        let control = reviewControl(for: run)
        let session = AppServerReviewEventSession(run: run, control: control)
        registerReviewEventSession(session, for: run)
        return session
    }

    private func reviewControl(for run: CodexReviewBackendModel.Review.Run) -> AppServerReviewControl {
        if let control = controlsByThreadID[run.threadID] {
            return control
        }
        let control = AppServerReviewControl()
        if let turnID = run.turnID {
            control.recordReviewStarted(turnID: turnID)
        } else {
            control.recordThreadStarted()
        }
        controlsByThreadID[run.threadID] = control
        return control
    }

    private func reviewThread(for run: CodexReviewBackendModel.Review.Run) async throws -> CodexThread {
        try await threadHandle(id: run.threadID, model: run.model)
    }

    private func threadHandle(id threadID: String, model: String?) async throws -> CodexThread {
        if let thread = threadsByThreadID[threadID] {
            return thread
        }
        let thread = try await appServer.resumeThread(
            .init(rawValue: threadID),
            options: .init(model: model)
        )
        threadsByThreadID[threadID] = thread
        return thread
    }

    private func registerReviewEventSession(
        _ session: AppServerReviewEventSession,
        for run: CodexReviewBackendModel.Review.Run
    ) {
        reviewEventSessionsByAttemptID[run.attemptID] = session
        let activeThreadIDs = Set([run.threadID, run.reviewThreadID].compactMap { $0?.nilIfEmpty })
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
        noteReviewThreadIDForCleanup(run.threadID, canonicalThreadID: run.threadID)
        if let reviewThreadID = run.reviewThreadID,
           reviewThreadID != run.threadID {
            reviewEventSessionCanonicalThreadIDByThreadID[reviewThreadID] = run.threadID
            noteReviewThreadIDForCleanup(reviewThreadID, canonicalThreadID: run.threadID)
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
        if activeReviewAttemptIDByThreadID[run.threadID] == run.attemptID {
            activeReviewAttemptIDByThreadID.removeValue(forKey: run.threadID)
        }
        if let reviewThreadID = run.reviewThreadID,
           reviewThreadID != run.threadID {
            if activeReviewAttemptIDByThreadID[reviewThreadID] == run.attemptID {
                activeReviewAttemptIDByThreadID.removeValue(forKey: reviewThreadID)
            }
        }
        activeThreadIDsByAttemptID.removeValue(forKey: run.attemptID)
        return reviewEventSessionsByAttemptID.removeValue(forKey: run.attemptID)
    }

    private func noteReviewThreadIDForCleanup(_ threadID: String, canonicalThreadID: String) {
        reviewThreadIDsForCleanupByThreadID[canonicalThreadID, default: []].insert(threadID)
    }

    private func markAttemptAbandoned(
        _ run: CodexReviewBackendModel.Review.Run,
        interruption: AppServerReviewInterruption
    ) {
        abandonedReviewAttemptIDs.insert(run.attemptID)
        markTurnAbandoned(run.turnID)
        markTurnAbandoned(interruption.turnID)
        noteReviewThreadIDForCleanup(interruption.threadID, canonicalThreadID: run.threadID)
    }

    private func markInterruptionTurnAbandoned(
        _ interruption: AppServerReviewInterruption,
        canonicalThreadID: String
    ) {
        markTurnAbandoned(interruption.turnID)
        noteReviewThreadIDForCleanup(interruption.threadID, canonicalThreadID: canonicalThreadID)
    }

    private func markTurnAbandoned(_ turnID: String?) {
        guard let turnID = turnID?.nilIfEmpty else {
            return
        }
        abandonedTurnIDs.insert(turnID)
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

    private func sendTurnInterrupt(
        for run: CodexReviewBackendModel.Review.Run,
        willInterruptActiveTurn: (@Sendable (AppServerReviewInterruption) async -> Void)? = nil
    ) async throws -> AppServerReviewInterruption {
        if let control = controlsByThreadID[run.threadID],
           let interruption = try await control.interrupt(willInterruptActiveTurn: willInterruptActiveTurn) {
            return interruption
        }
        let control = reviewControl(for: run)
        guard let interruption = try await control.interrupt(willInterruptActiveTurn: willInterruptActiveTurn) else {
            throw CodexReviewAPI.Error.io("Review run has no interruptible app-server session.")
        }
        return interruption
    }

    private func cleanupThreadIDs(for run: CodexReviewBackendModel.Review.Run) -> [String] {
        var seen: Set<String> = []
        var threadIDs: [String] = []
        let registeredReviewThreadIDs = (reviewThreadIDsForCleanupByThreadID[run.threadID] ?? [])
            .filter { $0 != run.threadID }
            .sorted()
        for threadID in registeredReviewThreadIDs where seen.insert(threadID).inserted {
            threadIDs.append(threadID)
        }
        if let reviewThreadID = run.reviewThreadID,
           reviewThreadID != run.threadID,
           seen.insert(reviewThreadID).inserted {
            threadIDs.append(reviewThreadID)
        }
        if seen.insert(run.threadID).inserted {
            threadIDs.append(run.threadID)
        }
        return threadIDs
    }

    private func mergedCleanupThreadIDs(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen: Set<String> = []
        var merged: [String] = []
        for threadID in lhs + rhs where seen.insert(threadID).inserted {
            merged.append(threadID)
        }
        return merged
    }

}

package struct AppServerReviewEventSessionMetrics: Equatable, Sendable {
    package var routed = 0
    package var decoded = 0
    package var emitted = 0
    package var ignored = 0
    package var buffered = 0
    package var commandTimeoutWarnings = 0
    package var firstEventLatencyMs: Int?
    package var terminalLatencyMs: Int?

    package init() {}
}

private struct PendingStreamedLogEntry: Sendable {
    struct Key: Hashable, Sendable {
        var kind: ReviewLogEntry.Kind
        var groupID: String
        var sourceType: String?
        var itemID: String?
    }

    var kind: ReviewLogEntry.Kind
    var text: String
    var groupID: String
    var metadata: ReviewLogEntry.Metadata?
    var suppressesTimelineProjection: Bool

    var key: Key {
        .init(
            kind: kind,
            groupID: groupID,
            sourceType: metadata?.sourceType,
            itemID: metadata?.itemID
        )
    }

    var events: [CodexReviewBackendModel.Review.Event] {
        let logEntry = CodexReviewBackendModel.Review.Event.logEntry(
            kind: kind,
            text: text,
            groupID: groupID,
            replacesGroup: false,
            metadata: metadata
        )
        return suppressesTimelineProjection
            ? [.suppressNextLegacyTimelineProjection, logEntry]
            : [logEntry]
    }

    init?(_ event: CodexReviewBackendModel.Review.Event, suppressesTimelineProjection: Bool = false) {
        guard case .logEntry(let kind, let text, let groupID, let replacesGroup, let metadata) = event,
              text.isEmpty == false,
              replacesGroup == false,
              let groupID
        else {
            return nil
        }
        switch kind {
        case .commandOutput:
            guard metadata?.sourceType == "commandExecution",
                  metadata?.title == "Command output"
            else {
                return nil
            }
        case .reasoningSummary, .rawReasoning:
            break
        case .agentMessage, .command, .plan, .reasoning, .todoList, .toolCall, .diagnostic, .error, .progress, .event, .contextCompaction:
            return nil
        }
        self.kind = kind
        self.text = text
        self.groupID = groupID
        self.metadata = metadata
        self.suppressesTimelineProjection = suppressesTimelineProjection
    }

    mutating func append(_ suffix: String) {
        text += suffix
    }

    mutating func suppressTimelineProjection() {
        suppressesTimelineProjection = true
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
    private static let commandTimeoutExitCode = 124
    private static let longCommandDurationWarningMs = 100_000
    private static let streamedLogFlushIntervalNanoseconds: UInt64 = 20_000_000

    private var run: CodexReviewBackendModel.Review.Run
    private let control: AppServerReviewControl
    private let mailbox: BackendReviewEventMailbox
    private var reviewThreadIDsForCleanup: [String] = []
    private var pendingStreamedLogEntries: [PendingStreamedLogEntry] = []
    private var pendingStreamedLogIndexByKey: [PendingStreamedLogEntry.Key: Int] = [:]
    private var streamedLogFlushTask: Task<Void, Never>?
    private var cancellationRequestedMessage: String?
    private let completionCoordinator = ReviewCompletionCoordinator()
    private let createdAt = Date()
    private var finished = false
    private var metrics = AppServerReviewEventSessionMetrics()
    private var typedReviewStreamTask: Task<Void, Never>?
    private var typedMessageTextByItemID: [String: String] = [:]
    private var typedReviewResultText: String?

    init(
        run: CodexReviewBackendModel.Review.Run,
        control: AppServerReviewControl,
        mailbox: BackendReviewEventMailbox = .init()
    ) {
        self.run = run
        self.control = control
        self.mailbox = mailbox
        if let reviewThreadID = run.reviewThreadID?.nilIfEmpty,
           reviewThreadID != run.threadID {
            self.reviewThreadIDsForCleanup.append(reviewThreadID)
        }
    }

    func updateRun(_ run: CodexReviewBackendModel.Review.Run) {
        self.run = run
        noteReviewThreadIDForCleanup(run.reviewThreadID)
    }

    func currentRun() -> CodexReviewBackendModel.Review.Run {
        run
    }

    func attempt() -> BackendReviewAttempt {
        .init(run: run, events: mailbox)
    }

    func cleanupThreadIDs() -> [String] {
        var threadIDs = reviewThreadIDsForCleanup.filter { $0 != run.threadID }
        threadIDs.append(run.threadID)
        return threadIDs
    }

    func requestCancellation(message: String) {
        cancellationRequestedMessage = message
    }

    func clearCancellationRequest() {
        cancellationRequestedMessage = nil
    }

    func finish(
        cancellationMessage: String?,
        buffersMissingContinuation _: Bool = false
    ) async {
        cancelTypedReviewStream()
        let precedingEvents = drainPendingStreamedLogEvents()
        if cancellationMessage == nil {
            cancelPendingStreamedLogFlush()
        } else {
            cancellationRequestedMessage = cancellationMessage
        }
        await finish(precedingEvents: precedingEvents, cancellationMessage: cancellationMessage)
    }

    func finish(throwing error: (any Error)?) async {
        guard finished == false else {
            return
        }
        cancelTypedReviewStream()
        let precedingEvents = drainPendingStreamedLogEvents()
        cancelPendingStreamedLogFlush()
        await emitPrecedingEvents(precedingEvents)
        if let error {
            finished = true
            completionCoordinator.cancelPendingCompletion()
            await mailbox.fail(error)
        } else {
            if await flushPendingCompletion() {
                finished = true
                return
            }
            finished = true
            await mailbox.finish()
        }
    }

    func abandon() async {
        guard finished == false else {
            return
        }
        cancelTypedReviewStream()
        finished = true
        completionCoordinator.cancelPendingCompletion()
        cancelPendingStreamedLogFlush()
        pendingStreamedLogEntries.removeAll(keepingCapacity: true)
        pendingStreamedLogIndexByKey.removeAll(keepingCapacity: true)
        await mailbox.abandon()
    }

    func metricsSnapshot() -> AppServerReviewEventSessionMetrics {
        metrics
    }

    func activeStreamSubscriptionIDForTesting() -> Int? {
        nil
    }

    func detach(subscriptionID _: Int) {}

    func startConsuming(_ review: CodexReviewSession) {
        guard typedReviewStreamTask == nil else {
            return
        }
        typedReviewStreamTask = Task { [weak self] in
            await self?.consume(review)
        }
    }

    private func consume(_ review: CodexReviewSession) async {
        defer {
            typedReviewStreamTask = nil
        }
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
        metrics.routed += 1
        guard finished == false else {
            metrics.ignored += 1
            return
        }
        var events = converted.events
        guard events.isEmpty == false else {
            metrics.ignored += 1
            return
        }
        metrics.decoded += 1
        events = eventsWithTypedResultFallback(events)
        for event in events {
            if event.shouldDeferCompletion {
                completionCoordinator.deferCompletion(event)
                continue
            }
            if await emit(event, controlThreadID: converted.controlThreadID) {
                return
            }
        }
    }

    private func eventsWithTypedResultFallback(
        _ events: [CodexReviewBackendModel.Review.Event]
    ) -> [CodexReviewBackendModel.Review.Event] {
        events.map { event in
            switch event {
            case .message(let text):
                if let text = text.nilIfEmpty {
                    typedReviewResultText = text
                }
                return event
            case .messageDelta(let delta, let itemID):
                let text = (typedMessageTextByItemID[itemID] ?? "") + delta
                typedMessageTextByItemID[itemID] = text
                if let text = text.nilIfEmpty {
                    typedReviewResultText = text
                }
                return event
            case .logEntry(.agentMessage, let text, _, _, _):
                if let text = text.nilIfEmpty {
                    typedReviewResultText = text
                }
                return event
            case .completed(let summary, nil):
                return .completed(summary: summary, result: typedReviewResultText)
            case .domainEvents,
                 .suppressNextLegacyTimelineProjection,
                 .suppressNextTerminalFailureLogTimelineProjection,
                 .started,
                 .log,
                 .logEntry,
                 .completed,
                 .failed,
                 .cancelled:
                return event
            }
        }
    }

    private func finish(
        precedingEvents: [CodexReviewBackendModel.Review.Event],
        cancellationMessage: String?
    ) async {
        guard finished == false else {
            return
        }
        cancelTypedReviewStream()
        completionCoordinator.cancelPendingCompletion()
        cancelPendingStreamedLogFlush()
        await emitPrecedingEvents(precedingEvents)
        if let cancellationMessage {
            _ = await emit(.cancelled(cancellationMessage))
        } else {
            await mailbox.finish()
        }
        finished = true
    }

    private func noteReviewThreadIDForCleanup(_ reviewThreadID: String?) {
        guard let reviewThreadID = reviewThreadID?.nilIfEmpty,
              reviewThreadID != run.threadID,
              reviewThreadIDsForCleanup.contains(reviewThreadID) == false
        else {
            return
        }
        reviewThreadIDsForCleanup.append(reviewThreadID)
    }

    private func emit(
        _ event: CodexReviewBackendModel.Review.Event,
        controlThreadID: String? = nil
    ) async -> Bool {
        noteEmission(event)
        let didFinish = completionCoordinator.emit(event)
        await mailbox.append(event)
        recordReviewEvent(event, controlThreadID: controlThreadID)
        return didFinish
    }

    private func shouldFlushPendingStreamedLogBeforeDomainEvent(
        followingEvents: ArraySlice<CodexReviewBackendModel.Review.Event>,
        suppressTimelineProjection: Bool
    ) -> Bool {
        guard pendingStreamedLogEntries.isEmpty == false else {
            return false
        }
        return followingEvents.contains {
            canCoalescePendingStreamedLog(
                with: $0,
                suppressTimelineProjection: suppressTimelineProjection
            )
        } == false
    }

    private func canCoalescePendingStreamedLog(
        with event: CodexReviewBackendModel.Review.Event,
        suppressTimelineProjection: Bool
    ) -> Bool {
        guard let entry = PendingStreamedLogEntry(
            event,
            suppressesTimelineProjection: suppressTimelineProjection
        ) else {
            return false
        }
        return pendingStreamedLogIndexByKey[entry.key] != nil
    }

    private func bufferStreamedLog(
        _ event: CodexReviewBackendModel.Review.Event,
        suppressTimelineProjection: Bool = false
    ) -> Bool {
        guard let entry = PendingStreamedLogEntry(
            event,
            suppressesTimelineProjection: suppressTimelineProjection
        ) else {
            return false
        }
        if let index = pendingStreamedLogIndexByKey[entry.key] {
            pendingStreamedLogEntries[index].append(entry.text)
            if suppressTimelineProjection {
                pendingStreamedLogEntries[index].suppressTimelineProjection()
            }
        } else {
            pendingStreamedLogIndexByKey[entry.key] = pendingStreamedLogEntries.count
            pendingStreamedLogEntries.append(entry)
        }
        schedulePendingStreamedLogFlush()
        return true
    }

    private func schedulePendingStreamedLogFlush() {
        guard streamedLogFlushTask == nil else {
            return
        }
        streamedLogFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.streamedLogFlushIntervalNanoseconds)
            } catch {
                return
            }
            await self?.flushPendingStreamedLogFromTimer()
        }
    }

    private func flushPendingStreamedLogFromTimer() async {
        streamedLogFlushTask = nil
        _ = await flushPendingStreamedLog()
    }

    private func flushPendingStreamedLog(
        controlThreadID: String? = nil
    ) async -> Bool {
        let events = drainPendingStreamedLogEvents()
        guard events.isEmpty == false else {
            return false
        }
        cancelPendingStreamedLogFlush()
        for event in events {
            if await emit(event, controlThreadID: controlThreadID) {
                return true
            }
        }
        return false
    }

    private func drainPendingStreamedLogEvents() -> [CodexReviewBackendModel.Review.Event] {
        let events = pendingStreamedLogEntries.flatMap(\.events)
        pendingStreamedLogEntries.removeAll(keepingCapacity: true)
        pendingStreamedLogIndexByKey.removeAll(keepingCapacity: true)
        return events
    }

    private func cancelPendingStreamedLogFlush() {
        streamedLogFlushTask?.cancel()
        streamedLogFlushTask = nil
    }

    private func cancelTypedReviewStream() {
        typedReviewStreamTask?.cancel()
        typedReviewStreamTask = nil
    }

    private func flushPendingCompletion(
        controlThreadID: String? = nil
    ) async -> Bool {
        guard let event = completionCoordinator.flushPendingCompletion() else {
            return false
        }
        let events = eventsWithTypedResultFallback([event])
        guard let event = events.first else {
            return false
        }
        noteEmission(event)
        await mailbox.append(event)
        recordReviewEvent(event, controlThreadID: controlThreadID)
        return true
    }

    private func recordReviewEvent(_ event: CodexReviewBackendModel.Review.Event, controlThreadID: String? = nil) {
        switch event {
        case .started(let turnID, _, _):
            control.recordTurnStarted(turnID: turnID)
        case .completed, .failed, .cancelled:
            control.finish()
            appServerBackendLogger.debug(
                "Review event session finished for \(self.run.threadID, privacy: .public): emitted=\(self.metrics.emitted, privacy: .public) buffered=\(self.metrics.buffered, privacy: .public) ignored=\(self.metrics.ignored, privacy: .public) timeoutWarnings=\(self.metrics.commandTimeoutWarnings, privacy: .public)"
            )
        case .domainEvents,
             .suppressNextLegacyTimelineProjection,
             .suppressNextTerminalFailureLogTimelineProjection,
             .message,
             .messageDelta,
             .log,
             .logEntry:
            break
        }
    }

    private func noteEmissions(_ events: [CodexReviewBackendModel.Review.Event]) {
        for event in events {
            noteEmission(event)
        }
    }

    private func emitPrecedingEvents(_ events: [CodexReviewBackendModel.Review.Event]) async {
        noteEmissions(events)
        for event in events {
            await mailbox.append(event)
            recordReviewEvent(event)
        }
    }

    private func noteEmission(_ event: CodexReviewBackendModel.Review.Event) {
        metrics.emitted += 1
        if metrics.firstEventLatencyMs == nil {
            metrics.firstEventLatencyMs = Self.durationMs(from: createdAt, to: Date())
        }
        if event.isTerminal {
            metrics.terminalLatencyMs = Self.durationMs(from: createdAt, to: Date())
        }
        if Self.isCommandTimeoutWarning(event) {
            metrics.commandTimeoutWarnings += 1
        }
    }

    private static func isCommandTimeoutWarning(_ event: CodexReviewBackendModel.Review.Event) -> Bool {
        guard case .logEntry(_, _, _, _, let metadata) = event,
              metadata?.sourceType == "commandExecution"
        else {
            return false
        }
        if metadata?.exitCode == commandTimeoutExitCode {
            return true
        }
        return (metadata?.durationMs ?? 0) >= longCommandDurationWarningMs
    }

    private static func durationMs(from start: Date, to end: Date) -> Int {
        let milliseconds = end.timeIntervalSince(start) * 1000
        guard milliseconds.isFinite else {
            return 0
        }
        return max(0, Int(milliseconds.rounded()))
    }
}

private extension CodexReviewBackendModel.Review.Event {
    var isTerminal: Bool {
        return switch self {
        case .completed, .failed, .cancelled:
            true
        case .domainEvents,
             .suppressNextLegacyTimelineProjection,
             .suppressNextTerminalFailureLogTimelineProjection,
             .started,
             .message,
             .messageDelta,
             .log,
             .logEntry:
            false
        }
    }

    var shouldDeferCompletion: Bool {
        guard case .completed(_, let result) = self else {
            return false
        }
        return result?.nilIfEmpty == nil
    }
}

private extension Array where Element == CodexReviewBackendModel.Review.Event {
    var legacyTimelineProjectionCount: Int {
        reduce(0) { count, event in
            count + (event.createsImmediateLegacyTimelineProjection ? 1 : 0)
        }
    }

    var addingTerminalFailureLogProjectionSuppressionIfNeeded: [Element] {
        flatMap { event -> [Element] in
            if case .failed = event {
                return [.suppressNextTerminalFailureLogTimelineProjection, event]
            }
            return [event]
        }
    }
}

private extension CodexReviewBackendModel.Review.Event {
    var createsImmediateLegacyTimelineProjection: Bool {
        guard PendingStreamedLogEntry(self) == nil else {
            return false
        }
        return switch self {
        case .message, .messageDelta, .log, .logEntry:
            true
        case .domainEvents,
             .suppressNextLegacyTimelineProjection,
             .suppressNextTerminalFailureLogTimelineProjection,
             .started,
             .completed,
             .failed,
             .cancelled:
            false
        }
    }
}

private final class ReviewCompletionCoordinator {
    private var pendingCompletion: CodexReviewBackendModel.Review.Event?
    private var finished = false

    func emit(_ event: CodexReviewBackendModel.Review.Event) -> Bool {
        guard finished == false else {
            return true
        }
        guard event.isTerminal else {
            return false
        }
        finished = true
        pendingCompletion = nil
        return true
    }

    func deferCompletion(_ event: CodexReviewBackendModel.Review.Event) {
        guard finished == false else {
            return
        }
        pendingCompletion = event
    }

    func flushPendingCompletion() -> CodexReviewBackendModel.Review.Event? {
        guard finished == false,
              let event = pendingCompletion
        else {
            return nil
        }
        pendingCompletion = nil
        finished = true
        return event
    }

    func cancelPendingCompletion() {
        pendingCompletion = nil
    }

    func finishIfNeeded() {
        guard finished == false else {
            return
        }
        finished = true
        pendingCompletion = nil
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
