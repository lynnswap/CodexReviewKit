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
    nonisolated package let modelExecutor: any CodexModelExecutor
    private var reviewEventSessionsByAttemptID: [String: AppServerReviewEventSession] = [:]
    private var activeReviewAttemptIDByThreadID: [String: String] = [:]
    private var activeThreadIDsByAttemptID: [String: Set<String>] = [:]
    private var reviewEventSessionCanonicalThreadIDByThreadID: [String: String] = [:]
    private var abandonedReviewAttemptIDs: Set<String> = []
    private var inFlightRestartCountByInterruptedAttemptID: [String: Int] = [:]
    private var completedReviewEventSessionMetricsByThreadID: [String: ReviewBackendEventSessionMetrics] = [:]

    private struct DeferredReviewThreadCleanup {
        var run: CodexReviewBackendModel.Review.Run
        var additionalCleanupThreadIDs: [String]
    }

    // Terminal reviews keep their chats readable (sidebar, MCP log reads)
    // until runtime teardown: cleanupReview defers the destructive thread
    // deletion here and cleanupActiveReviewsForShutdown flushes it.
    private var deferredThreadCleanupsByAttemptID: [String: DeferredReviewThreadCleanup] = [:]
    private var completedThreadCleanupAttemptIDs: Set<String> = []

    package init(appServer: CodexAppServer, modelContainer: CodexModelContainer? = nil) {
        let modelContainer = modelContainer ?? CodexModelContainer(appServer: appServer)
        self.appServer = appServer
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

    package func startLogin(_ request: CodexReviewBackendModel.Login.Request) async throws
        -> CodexReviewBackendModel.Login.Challenge
    {
        if let callbackScheme = request.nativeWebAuthenticationCallbackScheme {
            let login = try await appServer.loginChatGPT(
                nativeWebAuthentication: .init(callbackURLScheme: callbackScheme)
            )
            return login.backendChallenge()
        }
        let handle = try await appServer.loginChatGPT()
        return try handle.backendChallenge(
            nativeWebAuthenticationCallbackScheme: nil
        )
    }

    package func completeLogin(
        _ challenge: CodexReviewBackendModel.Login.Challenge,
        callbackURL: URL
    ) async throws {
        try await appServer.completeLogin(
            id: .init(rawValue: challenge.id),
            callbackURL: callbackURL
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
        let review = try await startReviewSession(for: request)
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

    private func startReviewSession(for request: CodexReviewBackendModel.Review.Start) async throws
        -> CodexReviewSession
    {
        let workspace = URL(fileURLWithPath: request.request.cwd, isDirectory: true)
        return try await startDataKitBackedReviewSession(request, in: workspace)
    }

    private func startDataKitBackedReviewSession(
        _ request: CodexReviewBackendModel.Review.Start,
        in workspace: URL
    ) async throws -> CodexReviewSession {
        try await modelContext.startReview(
            in: workspace,
            input: CodexReviewInput(
                target: request.request.target.appServerReviewTarget,
                options: reviewThreadOptions(request),
                delivery: .inline
            )
        )
        .session
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
        _ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason
    ) async throws {
        guard abandonedReviewAttemptIDs.contains(run.attemptID) == false else {
            return
        }
        _ = try await cancelReviewTurn(for: run)
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
            delivery: .inline,
            threadOptions: reviewThreadOptions(model: interruptedRun.model ?? request.model)
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
            await session.finish()
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
        if completedThreadCleanupAttemptIDs.contains(run.attemptID) == false {
            deferredThreadCleanupsByAttemptID[run.attemptID] = .init(
                run: run,
                additionalCleanupThreadIDs: additionalCleanupThreadIDs
            )
        }
        for threadID in cleanupThreadIDs {
            reviewEventSessionCanonicalThreadIDByThreadID.removeValue(forKey: threadID)
            activeReviewAttemptIDByThreadID.removeValue(forKey: threadID)
        }
    }

    private func flushDeferredThreadCleanups() async {
        let deferredCleanups = deferredThreadCleanupsByAttemptID.values
        deferredThreadCleanupsByAttemptID = [:]
        completedThreadCleanupAttemptIDs.formUnion(
            deferredCleanups.map { $0.run.attemptID }
        )
        for cleanup in deferredCleanups {
            await cleanupAppServerReview(
                cleanup.run,
                additionalCleanupThreadIDs: cleanup.additionalCleanupThreadIDs
            )
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
        await flushDeferredThreadCleanups()
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
            threadOptions: reviewThreadOptions(model: run.model)
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

private enum AppServerTypedReviewEventAdapter {
    static func started(
        review: CodexReviewSession,
        run: CodexReviewBackendModel.Review.Run
    ) -> CodexReviewBackendModel.Review.Event {
        .started(
            turnID: review.turnID.rawValue,
            reviewThreadID: review.reviewThreadID.rawValue,
            model: run.model
        )
    }

    static func convert(
        _ outcome: CodexTurnOutcome
    ) -> CodexReviewBackendModel.Review.Event {
        switch outcome {
        case .completed(let response):
            guard let finalReview = response.transcript.reviewOutputText?.nilIfEmpty else {
                return .failed(.missingReviewOutput(turnID: response.turnID.rawValue))
            }
            return .completed(finalReview: finalReview)
        case .interrupted:
            return .interrupted(message: nil)
        case .failed(let failedTurn):
            return .failed(.turnFailed(map(failedTurn.error)))
        case .invalidTerminalStatus(let rawStatus, let error, let response):
            return .failed(
                .invalidTerminalStatus(
                    rawStatus: rawStatus,
                    turnID: response.turnID.rawValue,
                    turnFailure: error.map(map)
                )
            )
        }
    }

    private static func map(_ error: CodexTurnError) -> ReviewTurnFailure {
        .init(
            message: error.message,
            code: error.info.map(map),
            additionalDetails: error.additionalDetails
        )
    }

    private static func map(_ info: CodexErrorInfo) -> ReviewTurnFailure.Code {
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

private actor AppServerReviewEventSession {
    private let pipeline: ReviewBackendEventSession
    private var terminalCollectionTask: Task<Void, Never>?
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

    func finish() async {
        cancelTerminalCollection()
        await pipeline.finish(throwing: nil)
    }

    func finish(throwing error: (any Error)?) async {
        cancelTerminalCollection()
        await pipeline.finish(throwing: error)
    }

    func abandon() async {
        cancelTerminalCollection()
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
        guard terminalCollectionTask == nil else {
            return
        }
        reviewSession = review
        terminalCollectionTask = Task { [weak self] in
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
            terminalCollectionTask = nil
            if reviewSession?.id == review.id {
                reviewSession = nil
            }
        }
        let run = await pipeline.currentRun()
        await receive(
            AppServerTypedReviewEventAdapter.started(review: review, run: run),
            controlThreadID: review.reviewThreadID.rawValue
        )
        do {
            let outcome = try await review.collect()
            await receive(
                AppServerTypedReviewEventAdapter.convert(outcome),
                controlThreadID: review.reviewThreadID.rawValue
            )
        } catch is CancellationError {
            await finish(throwing: CancellationError())
        } catch {
            await finish(throwing: error)
        }
    }

    private func receive(
        _ event: CodexReviewBackendModel.Review.Event,
        controlThreadID: String
    ) async {
        await pipeline.receive([event], controlThreadID: controlThreadID)
    }

    private func cancelTerminalCollection() {
        terminalCollectionTask?.cancel()
        terminalCollectionTask = nil
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

private extension CodexChatGPTLogin {
    func backendChallenge() -> CodexReviewBackendModel.Login.Challenge {
        .init(
            id: id.rawValue,
            verificationURL: authenticationURL,
            nativeWebAuthenticationCallbackScheme: nativeWebAuthentication?.callbackURLScheme
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
