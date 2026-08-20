import Foundation
import CodexReview
import OSLog

private let appServerBackendLogger = Logger(
    subsystem: "CodexReviewKit",
    category: "app-server-backend"
)

private func appServerTurnThreadID(for run: CodexReviewBackendModel.Review.Run) -> String {
    run.reviewThreadID?.nilIfEmpty ?? run.threadID
}

private func makeAppServerReviewAttemptID() -> String {
    UUID().uuidString
}

package actor AppServerCodexReviewBackend: CodexReviewBackend {
    private static let reviewPermissionProfileID = ":danger-full-access"

    private let client: AppServerClient
    private let threadStartPermissionStrategy: AppServerAPI.Thread.Start.PermissionStrategy
    private var controlsByThreadID: [String: AppServerReviewControl] = [:]
    private var reviewEventSessionsByAttemptID: [String: AppServerReviewEventSession] = [:]
    private var activeReviewAttemptIDsByThreadID: [String: Set<String>] = [:]
    private var activeThreadIDsByAttemptID: [String: Set<String>] = [:]
    private var reviewEventSessionCanonicalThreadIDByThreadID: [String: String] = [:]
    private var reviewThreadIDsForCleanupByThreadID: [String: Set<String>] = [:]
    private var abandonedReviewAttemptIDs: Set<String> = []
    private var abandonedTurnIDs: Set<String> = []
    private var unmatchedReviewNotificationsByThreadID: [String: [AppServerRoutedReviewNotification]] = [:]
    private var completedReviewEventSessionMetricsByThreadID: [String: AppServerReviewEventSessionMetrics] = [:]
    private var notificationRouterTask: Task<Void, Never>?
    private var isNotificationRouterStarting = false
    private var reviewNotificationSequence = 0
    private var notificationRouterMetrics = AppServerNotificationRouterMetrics()
    private var reviewStartRequestsInFlight = 0
    private var diagnosedUnknownNotificationMethods: Set<String> = []
    private var connectionStreamFailure: ReviewAttemptStreamFailure?

    package init(
        client: AppServerClient,
        threadStartPermissionStrategy: AppServerAPI.Thread.Start.PermissionStrategy = .modernPermissions
    ) {
        self.client = client
        self.threadStartPermissionStrategy = threadStartPermissionStrategy
    }

    package func readSettings() async throws -> CodexReviewBackendModel.Settings.Snapshot {
        _ = try await client.initialize()
        let response = try await client.send(AppServerAPI.Config.Read.Request())
        let models = try await readModelCatalog()
        return .init(
            model: response.config.reviewModel?.nilIfEmpty,
            fallbackModel: response.config.model?.nilIfEmpty ?? models.first(where: \.isDefault)?.model,
            reasoningEffort: response.config.modelReasoningEffort,
            serviceTier: response.config.serviceTier,
            models: models
        )
    }

    package func applySettings(_ change: CodexReviewBackendModel.Settings.Change) async throws -> CodexReviewBackendModel.Settings.Snapshot {
        _ = try await client.initialize()
        let edits = Self.configEdits(from: change)
        if edits.isEmpty == false {
            let _: AppServerAPI.Config.BatchWrite.Response = try await client.send(AppServerAPI.Config.BatchWrite.Request(
                params: .init(edits: edits)
            ))
        }
        return try await readSettings()
    }

    package func readAuth() async throws -> CodexReviewBackendModel.Auth.Snapshot {
        _ = try await client.initialize()
        let response = try await client.send(AppServerAPI.Auth.Read.Request())
        guard let account = response.account?.backendAccount else {
            return .init()
        }
        return .init(accounts: [account], activeAccountID: account.id)
    }

    package func readRateLimits() async throws -> AppServerAPI.Account.RateLimits.Response {
        _ = try await client.initialize()
        return try await client.send(AppServerAPI.Account.RateLimits.Read.Request())
    }

    package func startLogin(_ request: CodexReviewBackendModel.Login.Request) async throws -> CodexReviewBackendModel.Login.Challenge {
        _ = try await client.initialize()
        let nativeWebAuthentication = request.nativeWebAuthenticationCallbackScheme
            .map(AppServerAPI.Account.Login.NativeWebAuthentication.init(callbackURLScheme:))
        let response: AppServerAPI.Account.Login.Response = try await client.send(
            method: "account/login/start",
            params: AppServerAPI.Account.Login.Params(nativeWebAuthentication: nativeWebAuthentication),
            responseType: AppServerAPI.Account.Login.Response.self
        )
        return try response.backendChallenge
    }

    package func cancelLogin(_ challenge: CodexReviewBackendModel.Login.Challenge) async throws {
        _ = try await client.initialize()
        let _: AppServerAPI.Account.Login.Cancel.Response = try await client.send(
            method: "account/login/cancel",
            params: AppServerAPI.Account.Login.Cancel.Params(loginID: challenge.id),
            responseType: AppServerAPI.Account.Login.Cancel.Response.self
        )
    }

    package func completeLogin(_ response: CodexReviewBackendModel.Login.Response) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        if let callbackURL = response.callbackURL {
            _ = try await client.initialize()
            let _: AppServerAPI.Account.Login.Complete.Response = try await client.send(
                method: "account/login/complete",
                params: AppServerAPI.Account.Login.Complete.Params(loginID: response.challengeID, callbackURL: callbackURL),
                responseType: AppServerAPI.Account.Login.Complete.Response.self
            )
        }
        return try await readAuth()
    }

    package func logout(_: CodexReviewBackendModel.Account.ID) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        _ = try await client.initialize()
        let _: EmptyResponse = try await client.send(
            method: "account/logout",
            params: EmptyResponse(),
            responseType: EmptyResponse.self
        )
        return try await readAuth()
    }

    package func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        _ = try await client.initialize()
        await ensureNotificationRouterStarted()
        let control = AppServerReviewControl(client: client)

        let thread = try await startReviewThread(request, admission: admission)
        controlsByThreadID[thread.threadID] = control
        let attemptID = makeAppServerReviewAttemptID()
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: thread.threadID,
            reviewThreadID: thread.threadID,
            model: thread.model ?? request.model
        )
        let session = AppServerReviewEventSession(
            run: provisionalRun,
            control: control,
            isRunFinalized: false
        )
        registerReviewEventSession(session, for: provisionalRun)
        control.recordThreadStarted(threadID: thread.threadID)
        await admission.recordPreparedThread(provisionalRun)

        guard await admission.admitReviewStartDispatch(for: provisionalRun) else {
            try await cleanupReview(provisionalRun)
            throw ReviewStartCancelledBeforeDispatch(
                cancellation: await admission.cancellationRequest() ?? .system()
            )
        }

        let review: AppServerAPI.Review.Start.Response
        reviewStartRequestsInFlight += 1
        do {
            review = try await client.send(AppServerAPI.Review.Start.Request(
                params: .init(threadID: thread.threadID, target: request.request.target)
            ))
        } catch {
            reviewStartRequestsInFlight -= 1
            discardUnmatchedReviewNotificationsIfIdle()
            if let terminal = streamTerminal(for: error) {
                try await admission.recordStreamTerminal(terminal)
            }
            try await cleanupReview(provisionalRun)
            throw error
        }
        let reviewThreadID = review.reviewThreadID ?? thread.threadID
        let run = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: thread.threadID,
            turnID: review.turnID,
            reviewThreadID: reviewThreadID,
            model: thread.model ?? request.model
        )
        await session.updateRun(run)
        registerReviewEventSession(session, for: run)
        control.recordReviewStarted(turnThreadID: appServerTurnThreadID(for: run), turnID: review.turnID)
        await session.bufferStartupNotifications(takeUnmatchedReviewNotifications(for: run))
        await session.finalizeRun()
        await admission.recordActiveRun(run)
        reviewStartRequestsInFlight -= 1
        discardUnmatchedReviewNotificationsIfIdle()

        return await session.attempt()
    }

    private func startReviewThread(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> AppServerAPI.Thread.Start.Response {
        if threadStartPermissionStrategy == .legacySandbox {
            // Deprecated compatibility: installed Codex builds without the app-server v2
            // session-source flag can ignore permissions without failing the request.
            return try await sendThreadStart(AppServerAPI.Thread.Start.Request(
                params: threadStartParamsWithLegacySandbox(request)
            ), admission: admission)
        }
        do {
            return try await startReviewThreadWithProfileIDPermissions(request, admission: admission)
        } catch let error as JSONRPC.Error where Self.shouldRetryThreadStartWithLegacySandbox(error) {
            // Deprecated compatibility: some builds accept the permissions field shape
            // without registering the danger-full-access built-in profile.
            try await admission.recordThreadStartRejectedForRetry()
            return try await sendThreadStart(AppServerAPI.Thread.Start.Request(
                params: threadStartParamsWithLegacySandbox(request)
            ), admission: admission)
        } catch let error as JSONRPC.Error where Self.shouldRetryThreadStartWithObjectPermissions(error) {
            // Deprecated compatibility: installed Codex builds can require object-shaped
            // permissions while the latest local app-server source accepts a profile ID string.
            try await admission.recordThreadStartRejectedForRetry()
            return try await startReviewThreadWithProfileSelectionPermissions(request, admission: admission)
        }
    }

    private func startReviewThreadWithProfileIDPermissions(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> AppServerAPI.Thread.Start.Response {
        try await sendThreadStart(AppServerAPI.Thread.Start.Request(
            params: threadStartParams(
                request,
                permissions: .profileID(Self.reviewPermissionProfileID)
            )
        ), admission: admission)
    }

    private func startReviewThreadWithProfileSelectionPermissions(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> AppServerAPI.Thread.Start.Response {
        do {
            return try await sendThreadStart(AppServerAPI.Thread.Start.Request(
                params: threadStartParams(
                    request,
                    permissions: .profileSelection(.init(id: Self.reviewPermissionProfileID))
                )
            ), admission: admission)
        } catch let error as JSONRPC.Error
            where Self.shouldRetryThreadStartWithLegacySandbox(error)
        {
            // Deprecated compatibility: installed Codex builds can know the permissions
            // object shape without registering the danger-full-access built-in profile.
            try await admission.recordThreadStartRejectedForRetry()
            return try await sendThreadStart(AppServerAPI.Thread.Start.Request(
                params: threadStartParamsWithLegacySandbox(request)
            ), admission: admission)
        }
    }

    private func sendThreadStart(
        _ request: AppServerAPI.Thread.Start.Request,
        admission: ReviewStartAdmission
    ) async throws -> AppServerAPI.Thread.Start.Response {
        guard await admission.admitThreadStartDispatch() else {
            throw ReviewStartCancelledBeforeDispatch(
                cancellation: await admission.cancellationRequest() ?? .system()
            )
        }
        do {
            return try await client.send(request)
        } catch {
            if let terminal = streamTerminal(for: error) {
                try await admission.recordStreamTerminal(terminal)
            }
            throw error
        }
    }

    private func threadStartParams(
        _ request: CodexReviewBackendModel.Review.Start,
        permissions: AppServerAPI.Thread.Start.Permissions
    ) -> AppServerAPI.Thread.Start.Params {
        .init(
            cwd: request.request.cwd,
            model: request.model,
            ephemeral: false,
            approvalPolicy: "never",
            permissions: permissions,
            sessionStartSource: .startup,
            threadSource: .user
        )
    }

    private func threadStartParamsWithLegacySandbox(_ request: CodexReviewBackendModel.Review.Start) -> AppServerAPI.Thread.Start.Params {
        .init(
            cwd: request.request.cwd,
            model: request.model,
            ephemeral: false,
            approvalPolicy: "never",
            sandbox: "danger-full-access",
            sessionStartSource: .startup,
            threadSource: .user
        )
    }

    private nonisolated static func shouldRetryThreadStartWithObjectPermissions(_ error: JSONRPC.Error) -> Bool {
        guard case .responseError(_, let message) = error else {
            return false
        }
        return message.contains("PermissionProfileSelectionParams")
            || message.contains("invalid type: string")
    }

    private nonisolated static func shouldRetryThreadStartWithLegacySandbox(_ error: JSONRPC.Error) -> Bool {
        guard case .responseError(_, let message) = error else {
            return false
        }
        return message.contains("unknown built-in profile")
            || message.contains("default_permissions refers to unknown")
    }

    private nonisolated static func interruptRequestFailure(
        for error: any Error
    ) -> ReviewInterruptRequestFailure {
        if case JSONRPC.Error.responseError(let code, let message) = error {
            return .init(outcome: .rejected(code: code, message: message))
        }
        return .init(outcome: .outcomeUnknown(message: error.localizedDescription))
    }

    private func streamTerminal(
        for error: any Error
    ) -> ReviewAttemptStreamFailure? {
        guard let jsonRPCError = error as? JSONRPC.Error else {
            return nil
        }
        switch jsonRPCError {
        case .closed:
            return connectionStreamFailure
                ?? .unexpectedConnection(.connection(jsonRPCError.localizedDescription))
        case .invalidMessage:
            return .protocolViolation(.init(message: jsonRPCError.localizedDescription))
        case .responseError:
            return nil
        case .transportTerminated(let termination):
            switch termination {
            case .ownerClose:
                return connectionStreamFailure
                    ?? .unexpectedConnection(.connection(jsonRPCError.localizedDescription))
            case .processExit, .processFailure:
                return .process(.process(jsonRPCError.localizedDescription))
            }
        }
    }

    package func interruptReview(_ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason) async throws {
        _ = try await client.initialize()
        guard abandonedReviewAttemptIDs.contains(run.attemptID) == false else {
            return
        }
        let session = await reviewEventSession(for: run)
        await session.requestCancellation(message: reason.message)
        do {
            _ = try await sendTurnInterrupt(for: run)
        } catch {
            let failure = Self.interruptRequestFailure(for: error)
            if case .rejected = failure.outcome {
                await session.clearCancellationRequest()
            }
            throw failure
        }
    }

    package func forceCloseReviewConnection() async throws {
        connectionStreamFailure = .ownerForcedConnectionClose(
            .connection("Review connection was force-closed by its attempt owner.")
        )
        do {
            try await client.close()
        } catch let failure as ReviewRuntimeCloseFailure {
            throw failure
        } catch {
            throw ReviewRuntimeCloseFailure.connection(error.localizedDescription)
        }
    }

    package func prepareReviewRecovery(
        _ candidate: ReviewRecoveryCandidate
    ) async throws -> ReviewRecoveryHandoff {
        let run = candidate.resolved.run
        let interruption = AppServerReviewInterruption(
            threadID: appServerTurnThreadID(for: run),
            turnID: run.turnID ?? ""
        )
        markTurnAbandoned(run.turnID)
        markAttemptAbandoned(run, interruption: interruption)
        if let session = unregisterReviewEventSession(for: run) {
            await session.abandon()
            let metrics = await session.metricsSnapshot()
            for threadID in await session.cleanupThreadIDs() {
                completedReviewEventSessionMetricsByThreadID[threadID] = metrics
            }
        }
        return ReviewRecoveryHandoff(
            candidate: candidate,
            token: .init(
                interruptedRun: run,
                rollbackThreadID: interruption.threadID
            )
        )
    }

    package func resumeReviewRecovery(
        _ handoff: ReviewRecoveryHandoff,
        request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt {
        _ = try await client.initialize()
        await ensureNotificationRouterStarted()
        let token = handoff.token
        let interruptedRun = token.interruptedRun
        let _: EmptyResponse = try await client.send(AppServerAPI.Thread.Rollback.Request(
            params: .init(threadID: token.rollbackThreadID, numTurns: 1)
        ))

        let control = controlsByThreadID[interruptedRun.threadID] ?? AppServerReviewControl(client: client)
        controlsByThreadID[interruptedRun.threadID] = control
        let attemptID = makeAppServerReviewAttemptID()
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: interruptedRun.threadID,
            reviewThreadID: interruptedRun.threadID,
            model: interruptedRun.model ?? request.model
        )
        let session = AppServerReviewEventSession(
            run: provisionalRun,
            control: control,
            isRunFinalized: false
        )
        registerReviewEventSession(session, for: provisionalRun)
        await admission.recordPreparedThread(provisionalRun)
        guard await admission.admitReviewStartDispatch(for: provisionalRun) else {
            _ = unregisterReviewEventSession(for: provisionalRun)
            await session.abandon()
            throw ReviewStartCancelledBeforeDispatch(
                cancellation: await admission.cancellationRequest() ?? .system()
            )
        }

        let review: AppServerAPI.Review.Start.Response
        reviewStartRequestsInFlight += 1
        do {
            review = try await client.send(AppServerAPI.Review.Start.Request(
                params: .init(threadID: interruptedRun.threadID, target: request.request.target)
            ))
        } catch {
            reviewStartRequestsInFlight -= 1
            _ = unregisterReviewEventSession(for: provisionalRun)
            if let terminal = streamTerminal(for: error) {
                try await admission.recordStreamTerminal(terminal)
            }
            await session.abandon()
            discardUnmatchedReviewNotificationsIfIdle()
            throw error
        }

        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: interruptedRun.threadID,
            turnID: review.turnID,
            reviewThreadID: review.reviewThreadID ?? interruptedRun.threadID,
            model: interruptedRun.model ?? request.model
        )
        await session.updateRun(recoveredRun)
        registerReviewEventSession(session, for: recoveredRun)
        controlsByThreadID[interruptedRun.threadID]?.recordReviewStarted(
            turnThreadID: appServerTurnThreadID(for: recoveredRun),
            turnID: review.turnID
        )
        await session.bufferStartupNotifications(takeUnmatchedReviewNotifications(for: recoveredRun))
        await session.finalizeRun()
        await admission.recordActiveRun(recoveredRun)
        reviewStartRequestsInFlight -= 1
        discardUnmatchedReviewNotificationsIfIdle()

        return await session.attempt()
    }

    package func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async throws {
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
        var failureMessages: [String] = []
        do {
            let _: EmptyResponse = try await client.send(AppServerAPI.Thread.BackgroundTerminals.Clean.Request(
                params: .init(threadID: run.threadID)
            ))
        } catch {
            failureMessages.append(
                "thread/backgroundTerminals/clean for \(run.threadID): \(error.localizedDescription)"
            )
        }
        do {
            let _: AppServerAPI.Thread.Unsubscribe.Response = try await client.send(AppServerAPI.Thread.Unsubscribe.Request(
                params: .init(threadID: run.threadID)
            ))
        } catch {
            failureMessages.append(
                "thread/unsubscribe for \(run.threadID): \(error.localizedDescription)"
            )
        }
        for threadID in cleanupThreadIDs {
            do {
                let _: EmptyResponse = try await client.send(AppServerAPI.Thread.Delete.Request(
                    params: .init(threadID: threadID)
                ))
            } catch {
                failureMessages.append(
                    "thread/delete for \(threadID): \(error.localizedDescription)"
                )
            }
        }
        for threadID in cleanupThreadIDs {
            reviewEventSessionCanonicalThreadIDByThreadID.removeValue(forKey: threadID)
        }
        reviewThreadIDsForCleanupByThreadID.removeValue(forKey: run.threadID)
        if failureMessages.isEmpty == false {
            throw ReviewRuntimeCloseFailure.cleanup(failureMessages.joined(separator: "; "))
        }
    }

    package func notificationRouterMetricsForTesting() -> AppServerNotificationRouterMetrics {
        notificationRouterMetrics
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

    package func notificationRouterIsRunningForTesting() -> Bool {
        notificationRouterTask != nil
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
        await ensureNotificationRouterStarted()
        if let session = reviewEventSessionsByAttemptID[run.attemptID] {
            await session.updateRun(run)
            registerReviewEventSession(session, for: run)
            return session
        }
        let control = controlsByThreadID[run.threadID] ?? AppServerReviewControl(client: client)
        controlsByThreadID[run.threadID] = control
        if let turnID = run.turnID {
            control.recordReviewStarted(turnThreadID: appServerTurnThreadID(for: run), turnID: turnID)
        } else {
            control.recordThreadStarted(threadID: run.threadID)
        }
        let session = AppServerReviewEventSession(run: run, control: control)
        registerReviewEventSession(session, for: run)
        return session
    }

    private func registerReviewEventSession(
        _ session: AppServerReviewEventSession,
        for run: CodexReviewBackendModel.Review.Run
    ) {
        reviewEventSessionsByAttemptID[run.attemptID] = session
        let activeThreadIDs = Set([run.threadID, run.reviewThreadID].compactMap { $0?.nilIfEmpty })
        for threadID in activeThreadIDsByAttemptID[run.attemptID] ?? [] where activeThreadIDs.contains(threadID) == false {
            activeReviewAttemptIDsByThreadID[threadID]?.remove(run.attemptID)
            if activeReviewAttemptIDsByThreadID[threadID]?.isEmpty == true {
                activeReviewAttemptIDsByThreadID.removeValue(forKey: threadID)
            }
        }
        activeThreadIDsByAttemptID[run.attemptID] = activeThreadIDs
        for threadID in activeThreadIDs {
            activeReviewAttemptIDsByThreadID[threadID, default: []].insert(run.attemptID)
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
        let attemptIDs = activeReviewAttemptIDsByThreadID[threadID]
            ?? activeReviewAttemptIDsByThreadID[canonicalThreadID]
            ?? []
        guard attemptIDs.count == 1,
              let attemptID = attemptIDs.first
        else { return nil }
        return reviewEventSessionsByAttemptID[attemptID]
    }

    private func unregisterReviewEventSession(for run: CodexReviewBackendModel.Review.Run) -> AppServerReviewEventSession? {
        for threadID in activeThreadIDsByAttemptID[run.attemptID] ?? [] {
            activeReviewAttemptIDsByThreadID[threadID]?.remove(run.attemptID)
            if activeReviewAttemptIDsByThreadID[threadID]?.isEmpty == true {
                activeReviewAttemptIDsByThreadID.removeValue(forKey: threadID)
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

    private func markTurnAbandoned(_ turnID: String?) {
        guard let turnID = turnID?.nilIfEmpty else {
            return
        }
        abandonedTurnIDs.insert(turnID)
    }

    private func bufferUnmatchedReviewNotification(_ notification: AppServerRoutedReviewNotification) -> Bool {
        guard reviewStartRequestsInFlight > 0,
              let threadID = notification.payload.threadID
        else {
            return false
        }
        notificationRouterMetrics.buffered += 1
        unmatchedReviewNotificationsByThreadID[threadID, default: []].append(notification)
        return true
    }

    private func takeUnmatchedReviewNotifications(for run: CodexReviewBackendModel.Review.Run) -> [AppServerRoutedReviewNotification] {
        guard let reviewThreadID = run.reviewThreadID else {
            return []
        }
        let notifications = unmatchedReviewNotificationsByThreadID.removeValue(forKey: reviewThreadID) ?? []
        notificationRouterMetrics.routed += notifications.count
        return notifications
    }

    private func discardUnmatchedReviewNotificationsIfIdle() {
        guard reviewStartRequestsInFlight == 0 else {
            return
        }
        unmatchedReviewNotificationsByThreadID.removeAll(keepingCapacity: true)
    }

    private func sendTurnInterrupt(
        for run: CodexReviewBackendModel.Review.Run
    ) async throws -> AppServerReviewInterruption {
        if let control = controlsByThreadID[run.threadID],
           let interruption = try await control.interrupt() {
            return interruption
        }
        let threadID = appServerTurnThreadID(for: run)
        let _: EmptyResponse = try await client.send(AppServerAPI.Turn.Interrupt.Request(
            params: .init(threadID: threadID, turnID: run.turnID ?? "")
        ))
        return .init(threadID: threadID, turnID: run.turnID ?? "")
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

    private func ensureNotificationRouterStarted() async {
        if notificationRouterTask != nil {
            return
        }
        while isNotificationRouterStarting {
            await Task.yield()
            if notificationRouterTask != nil {
                return
            }
        }
        isNotificationRouterStarting = true
        let notifications = await client.notificationStream()
        notificationRouterTask = Task { [notifications] in
            await self.consumeReviewNotifications(notifications)
        }
        isNotificationRouterStarting = false
    }

    private func consumeReviewNotifications(
        _ notifications: AsyncThrowingStream<JSONRPC.Notification, Error>
    ) async {
        do {
            for try await notification in notifications {
                await routeReviewNotification(notification)
            }
            await finishAllReviewEventSessions(throwing: .workerContract(.init(
                message: "App-server notification stream ended without a transport terminal."
            )))
        } catch {
            await finishAllReviewEventSessions(throwing: streamFailure(for: error))
        }
        notificationRouterTask = nil
    }

    private func routeReviewNotification(_ notification: JSONRPC.Notification) async {
        notificationRouterMetrics.received += 1
        switch CurrentV2ReviewNotificationDecoder.decode(notification) {
        case .standaloneTraffic:
            notificationRouterMetrics.standaloneIgnored += 1
            notificationRouterMetrics.ignored += 1
            return
        case .unrelated:
            diagnoseUnknownNotificationMethod(notification.method)
            notificationRouterMetrics.ignored += 1
            return
        case .failure(let failure):
            if failure.isGlobalDiagnostic {
                diagnoseMalformedGlobalNotification(
                    failure.method,
                    error: failure.error
                )
                notificationRouterMetrics.ignored += 1
                return
            }
            await containNotificationDecodeFailure(failure)
            return
        case .globalDiagnostic(let envelope):
            do {
                let payload = try JSONDecoder().decode(
                    TurnNotificationPayload.self,
                    from: envelope.params
                )
                notificationRouterMetrics.decoded += 1
                reviewNotificationSequence += 1
                let routed = AppServerRoutedReviewNotification(
                    sequence: reviewNotificationSequence,
                    envelope: envelope,
                    payload: payload
                )
                let sessions = Array(reviewEventSessionsByAttemptID.values)
                guard sessions.isEmpty == false else {
                    notificationRouterMetrics.ignored += 1
                    return
                }
                notificationRouterMetrics.routed += sessions.count
                for session in sessions {
                    await session.receiveGlobalDiagnostic(routed)
                }
            } catch {
                diagnoseMalformedGlobalNotification(notification.method, error: error)
                notificationRouterMetrics.ignored += 1
            }
            return
        case .review(let envelope):
            await routeDecodedReviewNotification(envelope)
        }
    }

    private func routeDecodedReviewNotification(
        _ envelope: CurrentV2ReviewNotificationEnvelope
    ) async {
        guard let threadID = envelope.threadID else {
            await failConnection(
                .missingRoutingIdentity(method: envelope.method)
            )
            return
        }
        let attemptIDs = activeReviewAttemptIDsByThreadID[threadID] ?? []
        if attemptIDs.count > 1 {
            await failConnection(.conflictingActiveRouting(threadID: threadID))
            return
        }
        let payload: TurnNotificationPayload
        do {
            payload = try JSONDecoder().decode(TurnNotificationPayload.self, from: envelope.params)
        } catch {
            let ingestionError = ReviewIngestionError.malformedKnownEvent(
                method: envelope.method,
                message: error.localizedDescription
            )
            if let attemptID = attemptIDs.first,
               let session = reviewEventSessionsByAttemptID[attemptID] {
                notificationRouterMetrics.attemptFailures += 1
                await session.failAttempt(ingestionError)
            } else {
                await failConnection(ingestionError)
            }
            return
        }
        notificationRouterMetrics.decoded += 1
        if let turnID = envelope.turnID,
           abandonedTurnIDs.contains(turnID) {
            notificationRouterMetrics.ignored += 1
            return
        }

        reviewNotificationSequence += 1
        let routed = AppServerRoutedReviewNotification(
            sequence: reviewNotificationSequence,
            envelope: envelope,
            payload: payload
        )
        if let attemptID = attemptIDs.first,
           let session = reviewEventSessionsByAttemptID[attemptID] {
            notificationRouterMetrics.routed += 1
            await session.receive(routed)
            return
        }
        if bufferUnmatchedReviewNotification(routed) {
            return
        }
        notificationRouterMetrics.ignored += 1
    }

    private func containNotificationDecodeFailure(
        _ failure: CurrentV2ReviewNotificationDecodeFailure
    ) async {
        if failure.requiresConnectionContainment {
            await failConnection(failure.error)
            return
        }
        if let threadID = failure.routedThreadID {
            let attemptIDs = activeReviewAttemptIDsByThreadID[threadID] ?? []
            if attemptIDs.count == 1,
               let attemptID = attemptIDs.first,
               let session = reviewEventSessionsByAttemptID[attemptID] {
                notificationRouterMetrics.attemptFailures += 1
                await session.failAttempt(failure.error)
                return
            }
            if attemptIDs.count > 1 {
                await failConnection(.conflictingActiveRouting(threadID: threadID))
                return
            }
        }
        await failConnection(failure.error)
    }

    private func failConnection(_ error: ReviewIngestionError) async {
        notificationRouterMetrics.connectionFailures += 1
        connectionStreamFailure = .protocolViolation(.init(
            message: error.localizedDescription
        ))
        appServerBackendLogger.error(
            "Closing app-server connection after review routing failure: \(error.localizedDescription, privacy: .public)"
        )
        do {
            try await client.close()
        } catch {
            appServerBackendLogger.error(
                "App-server connection close failed during routing containment: \(error.localizedDescription, privacy: .public)"
            )
        }
        await finishAllReviewEventSessions(throwing: .protocolViolation(.init(
            message: error.localizedDescription
        )))
    }

    private func diagnoseUnknownNotificationMethod(_ method: String) {
        guard diagnosedUnknownNotificationMethods.count < 32,
              diagnosedUnknownNotificationMethods.insert(method).inserted
        else {
            return
        }
        notificationRouterMetrics.diagnostics += 1
        appServerBackendLogger.warning(
            "Ignoring unrelated app-server notification method \(method, privacy: .public)."
        )
    }

    private func diagnoseMalformedGlobalNotification(_ method: String, error: any Error) {
        notificationRouterMetrics.diagnostics += 1
        appServerBackendLogger.warning(
            "Ignoring malformed global app-server diagnostic \(method, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }

    private func finishAllReviewEventSessions(
        throwing failure: ReviewAttemptStreamFailure?
    ) async {
        let sessions = Array(reviewEventSessionsByAttemptID.values)
        for session in sessions {
            await session.finish(throwing: failure)
        }
    }

    private func streamFailure(
        for error: any Error
    ) -> ReviewAttemptStreamFailure {
        if let failure = error as? ReviewAttemptStreamFailure {
            return failure
        }
        if let failure = error as? ReviewRuntimeCloseFailure {
            switch failure {
            case .process:
                return .process(failure)
            case .connection:
                return .unexpectedConnection(failure)
            case .worker, .cleanup, .mcpHandlerDrain:
                return .workerContract(.init(message: failure.localizedDescription))
            }
        }
        if let jsonRPCError = error as? JSONRPC.Error {
            switch jsonRPCError {
            case .invalidMessage:
                return .protocolViolation(.init(message: jsonRPCError.localizedDescription))
            case .closed:
                return connectionStreamFailure
                    ?? .unexpectedConnection(.connection(jsonRPCError.localizedDescription))
            case .responseError:
                return .workerContract(.init(message: jsonRPCError.localizedDescription))
            case .transportTerminated(let termination):
                switch termination {
                case .ownerClose:
                    return connectionStreamFailure
                        ?? .unexpectedConnection(.connection(jsonRPCError.localizedDescription))
                case .processExit, .processFailure:
                    return .process(.process(jsonRPCError.localizedDescription))
                }
            }
        }
        if error is CancellationError {
            return .ownerCancellation
        }
        return .workerContract(.init(message: error.localizedDescription))
    }

    private func readModelCatalog() async throws -> [CodexReviewSettings.ModelCatalogItem] {
        var cursor: String?
        var models: [CodexReviewSettings.ModelCatalogItem] = []
        repeat {
            let response = try await client.send(AppServerAPI.Model.List.Request(
                params: .init(cursor: cursor, includeHidden: true)
            ))
            models.append(contentsOf: response.data)
            cursor = response.nextCursor?.nilIfEmpty
        } while cursor != nil
        return models
    }
}

package struct AppServerNotificationRouterMetrics: Equatable, Sendable {
    package var received = 0
    package var decoded = 0
    package var routed = 0
    package var ignored = 0
    package var buffered = 0
    package var standaloneIgnored = 0
    package var diagnostics = 0
    package var attemptFailures = 0
    package var connectionFailures = 0

    package init() {}
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

private struct AppServerRoutedReviewNotification: Sendable {
    var sequence: Int
    var envelope: CurrentV2ReviewNotificationEnvelope
    var payload: TurnNotificationPayload

    var method: String { envelope.method }
}

private struct DecodedReviewNotification {
    var events: [CodexReviewBackendModel.Review.Event]
    var finishesReviewMode: Bool
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

    var key: Key {
        .init(
            kind: kind,
            groupID: groupID,
            sourceType: metadata?.sourceType,
            itemID: metadata?.itemID
        )
    }

    var event: CodexReviewBackendModel.Review.Event {
        .logEntry(
            kind: kind,
            text: text,
            groupID: groupID,
            replacesGroup: false,
            metadata: metadata
        )
    }

    init?(_ event: CodexReviewBackendModel.Review.Event) {
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
    }

    mutating func append(_ suffix: String) {
        text += suffix
    }
}

private actor AppServerReviewEventSession {
    private static let commandTimeoutExitCode = 124
    private static let longCommandDurationWarningMs = 100_000
    private static let streamedLogFlushIntervalNanoseconds: UInt64 = 20_000_000

    private var run: CodexReviewBackendModel.Review.Run
    private let control: AppServerReviewControl
    private let mailbox: BackendReviewEventMailbox
    private var terminalReducer: CurrentV2ReviewTerminalReducer?
    private var emittedCanonicalStart = false
    private var reviewThreadIDsForCleanup: [String] = []
    private var commandLifecycleByItemID: [String: AppServerCommandLifecycle] = [:]
    private var pendingStreamedLogEntries: [PendingStreamedLogEntry] = []
    private var pendingStreamedLogIndexByKey: [PendingStreamedLogEntry.Key: Int] = [:]
    private var streamedLogFlushTask: Task<Void, Never>?
    private var cancellationRequestedMessage: String?
    private let createdAt = Date()
    private var finished = false
    private var isRunFinalized: Bool
    private var isDrainingStartupNotifications = false
    private var pendingStartupNotifications: [AppServerRoutedReviewNotification] = []
    private var metrics = AppServerReviewEventSessionMetrics()

    init(
        run: CodexReviewBackendModel.Review.Run,
        control: AppServerReviewControl,
        mailbox: BackendReviewEventMailbox = .init(),
        isRunFinalized: Bool = true
    ) {
        self.run = run
        self.control = control
        self.mailbox = mailbox
        self.isRunFinalized = isRunFinalized
        self.terminalReducer = Self.makeTerminalReducer(for: run)
        if let reviewThreadID = run.reviewThreadID?.nilIfEmpty,
           reviewThreadID != run.threadID {
            self.reviewThreadIDsForCleanup.append(reviewThreadID)
        }
    }

    func updateRun(_ run: CodexReviewBackendModel.Review.Run) {
        self.run = run
        if terminalReducer == nil {
            terminalReducer = Self.makeTerminalReducer(for: run)
        }
        noteReviewThreadIDForCleanup(run.reviewThreadID)
    }

    func bufferStartupNotifications(_ notifications: [AppServerRoutedReviewNotification]) {
        guard notifications.isEmpty == false else {
            return
        }
        metrics.routed += notifications.count
        metrics.buffered += notifications.count
        pendingStartupNotifications.append(contentsOf: notifications)
    }

    func finalizeRun() async {
        guard isRunFinalized == false else {
            return
        }
        isRunFinalized = true
        pendingStartupNotifications.sort { $0.sequence < $1.sequence }
        await drainStartupNotifications()
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

    func receive(_ notification: AppServerRoutedReviewNotification) async {
        metrics.routed += 1
        guard finished == false else {
            metrics.ignored += 1
            return
        }
        guard isRunFinalized, isDrainingStartupNotifications == false else {
            metrics.buffered += 1
            pendingStartupNotifications.append(notification)
            return
        }
        await process(notification)
    }

    func finish(
        cancellationMessage: String?,
        buffersMissingContinuation _: Bool = false
    ) async {
        var precedingEvents = drainPendingStreamedLogEvents()
        if cancellationMessage == nil {
            cancelPendingStreamedLogFlush()
        } else {
            cancellationRequestedMessage = cancellationMessage
            precedingEvents.append(contentsOf: commandLifecycleByItemID.closeActiveCommands(status: "canceled"))
            commandLifecycleByItemID.removeAll(keepingCapacity: true)
        }
        await finish(precedingEvents: precedingEvents, cancellationMessage: cancellationMessage)
    }

    func finish(throwing failure: ReviewAttemptStreamFailure?) async {
        guard finished == false else {
            return
        }
        let precedingEvents = drainPendingStreamedLogEvents()
        finished = true
        cancelPendingStreamedLogFlush()
        commandLifecycleByItemID.removeAll(keepingCapacity: true)
        pendingStartupNotifications.removeAll(keepingCapacity: true)
        await emitPrecedingEvents(precedingEvents)
        if let failure {
            await mailbox.fail(failure)
        } else {
            await mailbox.finish()
        }
    }

    func abandon() async {
        guard finished == false else {
            return
        }
        finished = true
        cancelPendingStreamedLogFlush()
        commandLifecycleByItemID.removeAll(keepingCapacity: true)
        pendingStreamedLogEntries.removeAll(keepingCapacity: true)
        pendingStreamedLogIndexByKey.removeAll(keepingCapacity: true)
        pendingStartupNotifications.removeAll(keepingCapacity: true)
        await mailbox.abandon()
    }

    func metricsSnapshot() -> AppServerReviewEventSessionMetrics {
        metrics
    }

    func activeStreamSubscriptionIDForTesting() -> Int? {
        nil
    }

    func detach(subscriptionID _: Int) {}

    private func finish(
        precedingEvents: [CodexReviewBackendModel.Review.Event],
        cancellationMessage: String?
    ) async {
        guard finished == false else {
            return
        }
        cancelPendingStreamedLogFlush()
        pendingStartupNotifications.removeAll(keepingCapacity: true)
        await emitPrecedingEvents(precedingEvents)
        if let cancellationMessage {
            await emitTerminal(.interrupted(message: cancellationMessage))
        } else {
            await mailbox.finish()
        }
        finished = true
    }

    private func drainStartupNotifications() async {
        guard isDrainingStartupNotifications == false else {
            return
        }
        isDrainingStartupNotifications = true
        defer {
            isDrainingStartupNotifications = false
        }
        while finished == false, pendingStartupNotifications.isEmpty == false {
            let notification = pendingStartupNotifications.removeFirst()
            await process(notification)
        }
    }

    private func process(_ notification: AppServerRoutedReviewNotification) async {
        guard var terminalReducer else {
            await failAttempt(.missingRoutingIdentity(method: notification.method))
            return
        }
        let ingestion: CurrentV2ReviewAttemptIngestion
        do {
            ingestion = try terminalReducer.ingest(notification.envelope)
            self.terminalReducer = terminalReducer
        } catch let error as ReviewIngestionError {
            await failAttempt(error)
            return
        } catch {
            await failAttempt(.malformedKnownEvent(
                method: notification.method,
                message: error.localizedDescription
            ))
            return
        }
        switch ingestion {
        case .duplicate, .foreignIdentity:
            metrics.ignored += 1
            return
        case .accepted:
            break
        }

        var decodedCommandLifecycleByItemID = commandLifecycleByItemID
        let decoded: DecodedReviewNotification
        do {
            decoded = try normalizeReviewNotification(
                notification,
                commandLifecycleByItemID: &decodedCommandLifecycleByItemID
            )
        } catch let error as ReviewIngestionError {
            await failAttempt(error)
            return
        } catch {
            await failAttempt(.malformedKnownEvent(
                method: notification.method,
                message: error.localizedDescription
            ))
            return
        }
        metrics.decoded += 1
        let controlThreadID = notification.payload.threadID
        let terminal: ReviewAttemptTerminal?
        if case .accepted(let acceptedTerminal) = ingestion {
            terminal = acceptedTerminal
        } else {
            terminal = nil
        }
        if emittedCanonicalStart == false,
           notification.envelope.turnID != nil,
           (notification.method == "turn/started"
            || decoded.events.contains(where: { $0.isTerminal == false })) {
            emittedCanonicalStart = true
            if await emit(
                .started(
                    turnID: run.turnID ?? "",
                    reviewThreadID: run.reviewThreadID ?? run.threadID,
                    model: nil
                ),
                controlThreadID: controlThreadID
            ) {
                return
            }
        }
        if shouldCloseActiveCommandsBeforeEvents(
            notification: notification,
            decoded: decoded
        ) {
            if await flushPendingStreamedLog(controlThreadID: controlThreadID) {
                return
            }
            let closedItemIDs = Set(commandLifecycleByItemID.keys)
            if await closeActiveCommandsForProgressBoundary(
                controlThreadID: controlThreadID
            ) {
                return
            }
            for itemID in closedItemIDs {
                decodedCommandLifecycleByItemID.removeValue(forKey: itemID)
            }
        }
        commandLifecycleByItemID = decodedCommandLifecycleByItemID

        if decoded.finishesReviewMode {
            if await flushPendingStreamedLog(controlThreadID: controlThreadID) {
                return
            }
            if await closeActiveCommandsForReviewExit(
                controlThreadID: controlThreadID
            ) {
                return
            }
        }

        for event in decoded.events {
            if bufferStreamedLog(event) {
                continue
            }
            if await flushPendingStreamedLog(controlThreadID: controlThreadID) {
                return
            }
            for commandEvent in commandLifecycleByItemID.closeActiveCommands(for: event) {
                if await emit(commandEvent, controlThreadID: controlThreadID) {
                    return
                }
            }
            if event.activeCommandTerminalStatus != nil {
                commandLifecycleByItemID.removeAll(keepingCapacity: true)
            }
            if await emit(event, controlThreadID: controlThreadID) {
                return
            }
        }

        if let terminal {
            if await flushPendingStreamedLog(controlThreadID: controlThreadID) {
                return
            }
            for commandEvent in commandLifecycleByItemID.closeActiveCommands(
                status: terminal.commandStatus
            ) {
                _ = await emit(commandEvent, controlThreadID: controlThreadID)
            }
            commandLifecycleByItemID.removeAll(keepingCapacity: true)
            await emitTerminal(terminal, controlThreadID: controlThreadID)
        } else if decoded.events.isEmpty,
                  notification.method != "turn/started" {
            metrics.ignored += 1
        }
    }

    func receiveGlobalDiagnostic(_ notification: AppServerRoutedReviewNotification) async {
        metrics.routed += 1
        guard finished == false else {
            metrics.ignored += 1
            return
        }
        var lifecycle = commandLifecycleByItemID
        do {
            let decoded = try normalizeReviewNotification(
                notification,
                commandLifecycleByItemID: &lifecycle
            )
            metrics.decoded += 1
            for event in decoded.events {
                _ = await emit(event)
            }
        } catch {
            metrics.ignored += 1
        }
    }

    func failAttempt(_ error: ReviewIngestionError) async {
        guard finished == false else {
            return
        }
        let precedingEvents = drainPendingStreamedLogEvents()
        cancelPendingStreamedLogFlush()
        pendingStartupNotifications.removeAll(keepingCapacity: true)
        await emitPrecedingEvents(precedingEvents)
        await mailbox.fail(.protocolViolation(.init(message: error.localizedDescription)))
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
        await mailbox.append(event)
        recordReviewEvent(event, controlThreadID: controlThreadID)
        return event.isTerminal
    }

    private func emitTerminal(
        _ terminal: ReviewAttemptTerminal,
        controlThreadID: String? = nil
    ) async {
        let event: CodexReviewBackendModel.Review.Event
        switch terminal {
        case .completed(let result):
            for itemID in result.suppressedAgentMessageItemIDs.sorted() {
                _ = await emit(
                    .logEntry(
                        kind: .agentMessage,
                        text: "",
                        groupID: itemID,
                        replacesGroup: true,
                        metadata: .init(sourceType: "suppressedFinalReviewCompanion")
                    ),
                    controlThreadID: controlThreadID
                )
            }
            if case .turnSummary(let itemID) = result.source {
                _ = await emit(
                    .logEntry(
                        kind: .agentMessage,
                        text: result.text,
                        groupID: itemID,
                        replacesGroup: true,
                        metadata: .init(sourceType: "canonicalReviewResult")
                    ),
                    controlThreadID: controlThreadID
                )
            }
            event = .completed(summary: "Succeeded.", result: result.text)
        case .interrupted(let message):
            event = .cancelled(message)
        case .failed(let message):
            event = .failed(message)
        }
        noteEmission(event)
        await mailbox.append(event)
        recordReviewEvent(event, controlThreadID: controlThreadID)
        await mailbox.finish()
    }

    private func shouldCloseActiveCommandsBeforeEvents(
        notification: AppServerRoutedReviewNotification,
        decoded: DecodedReviewNotification
    ) -> Bool {
        guard commandLifecycleByItemID.isEmpty == false else {
            return false
        }
        let startsNewCommand = notification.method == "item/started"
            && notification.payload.item?.type == "commandExecution"
        let reachesModelProgress = decoded.events.contains(where: Self.isCommandProgressBoundary(_:))
        guard startsNewCommand || reachesModelProgress else {
            return false
        }

        switch notification.method {
        case "item/commandExecution/outputDelta",
            "item/commandExecution/terminalInteraction":
            return false
        case "item/completed" where notification.payload.item?.type == "commandExecution":
            return false
        case "turn/completed", "thread/closed":
            return false
        default:
            return true
        }
    }

    private static func isCommandProgressBoundary(_ event: CodexReviewBackendModel.Review.Event) -> Bool {
        switch event {
        case .started, .message, .messageDelta, .log:
            return true
        case .logEntry(let kind, _, _, _, _):
            return kind != .command && kind != .commandOutput
        case .completed, .failed, .cancelled:
            return false
        }
    }

    private func closeActiveCommandsForProgressBoundary(
        controlThreadID: String? = nil
    ) async -> Bool {
        guard commandLifecycleByItemID.isEmpty == false else {
            return false
        }
        let status = cancellationRequestedMessage == nil ? "completed" : "canceled"
        for commandEvent in commandLifecycleByItemID.closeActiveCommands(status: status) {
            if await emit(commandEvent, controlThreadID: controlThreadID) {
                return true
            }
        }
        commandLifecycleByItemID.removeAll(keepingCapacity: true)
        return false
    }

    private func closeActiveCommandsForReviewExit(
        controlThreadID: String? = nil
    ) async -> Bool {
        guard commandLifecycleByItemID.isEmpty == false else {
            return false
        }
        let status = cancellationRequestedMessage == nil ? "completed" : "canceled"
        appServerBackendLogger.info(
            "Review mode exited with \(self.commandLifecycleByItemID.count, privacy: .public) active command execution(s); closing as \(status, privacy: .public)."
        )
        for commandEvent in commandLifecycleByItemID.closeActiveCommands(status: status) {
            if await emit(commandEvent, controlThreadID: controlThreadID) {
                return true
            }
        }
        commandLifecycleByItemID.removeAll(keepingCapacity: true)
        return false
    }

    private func bufferStreamedLog(_ event: CodexReviewBackendModel.Review.Event) -> Bool {
        guard let entry = PendingStreamedLogEntry(event) else {
            return false
        }
        if let index = pendingStreamedLogIndexByKey[entry.key] {
            pendingStreamedLogEntries[index].append(entry.text)
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
        let events = pendingStreamedLogEntries.map(\.event)
        pendingStreamedLogEntries.removeAll(keepingCapacity: true)
        pendingStreamedLogIndexByKey.removeAll(keepingCapacity: true)
        return events
    }

    private func cancelPendingStreamedLogFlush() {
        streamedLogFlushTask?.cancel()
        streamedLogFlushTask = nil
    }

    private func recordReviewEvent(_ event: CodexReviewBackendModel.Review.Event, controlThreadID: String? = nil) {
        switch event {
        case .started(let turnID, _, _):
            control.recordTurnStarted(turnThreadID: controlThreadID ?? appServerTurnThreadID(for: run), turnID: turnID)
        case .completed, .failed, .cancelled:
            control.finish()
            appServerBackendLogger.debug(
                "Review event session finished for \(self.run.threadID, privacy: .public): emitted=\(self.metrics.emitted, privacy: .public) buffered=\(self.metrics.buffered, privacy: .public) ignored=\(self.metrics.ignored, privacy: .public) timeoutWarnings=\(self.metrics.commandTimeoutWarnings, privacy: .public)"
            )
        case .message, .messageDelta, .log, .logEntry:
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

    private static func makeTerminalReducer(
        for run: CodexReviewBackendModel.Review.Run
    ) -> CurrentV2ReviewTerminalReducer? {
        guard let turnID = run.turnID?.nilIfEmpty,
              let threadID = run.reviewThreadID?.nilIfEmpty ?? run.threadID.nilIfEmpty
        else {
            return nil
        }
        return CurrentV2ReviewTerminalReducer(identity: .init(
            threadID: threadID,
            turnID: turnID
        ))
    }
}

private extension CodexReviewBackendModel.Review.Event {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .started, .message, .messageDelta, .log, .logEntry:
            false
        }
    }

    var activeCommandTerminalStatus: String? {
        switch self {
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .cancelled:
            return "canceled"
        case .started, .message, .messageDelta, .log, .logEntry:
            return nil
        }
    }
}

private extension ReviewAttemptTerminal {
    var commandStatus: String {
        switch self {
        case .completed:
            "completed"
        case .interrupted:
            "canceled"
        case .failed:
            "failed"
        }
    }
}

private extension AppServerCodexReviewBackend {
    static func configEdits(from change: CodexReviewBackendModel.Settings.Change) -> [AppServerAPI.Config.Edit] {
        var edits: [AppServerAPI.Config.Edit] = []
        if change.updatesModel {
            edits.append(.init(
                keyPath: "review_model",
                value: change.model.map(AppServerAPI.Config.Value.string) ?? .null
            ))
        }
        if change.updatesReasoningEffort {
            edits.append(.init(
                keyPath: "model_reasoning_effort",
                value: change.reasoningEffort.map(AppServerAPI.Config.Value.string) ?? .null
            ))
        }
        if change.updatesServiceTier {
            edits.append(.init(
                keyPath: "service_tier",
                value: change.serviceTier.map(AppServerAPI.Config.Value.string) ?? .null
            ))
        }
        return edits
    }
}

private extension AppServerAPI.Account.Snapshot {
    var backendAccount: CodexReviewBackendModel.Account.Snapshot {
        .init(
            id: id,
            kind: kind,
            label: label,
            isActive: true,
            planType: planType,
            capabilities: capabilities
        )
    }
}

private extension AppServerAPI.Account.Login.Response {
    var backendChallenge: CodexReviewBackendModel.Login.Challenge {
        get throws {
            switch self {
            case .apiKey:
                return .init(id: "api-key")
            case .chatgpt(let loginID, let authURL, let nativeWebAuthentication):
                return .init(
                    id: loginID,
                    verificationURL: try Self.webAuthenticationURL(authURL, field: "authUrl"),
                    nativeWebAuthenticationCallbackScheme: nativeWebAuthentication?.callbackURLScheme
                )
            case .chatgptDeviceCode(let loginID, let verificationURL, let userCode):
                return .init(
                    id: loginID,
                    verificationURL: try Self.webAuthenticationURL(verificationURL, field: "verificationUrl"),
                    userCode: userCode
                )
            case .chatgptAuthTokens:
                return .init(id: "chatgpt-auth-tokens")
            }
        }
    }

    static func webAuthenticationURL(_ string: String, field: String) throws -> URL {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              let url = components.url
        else {
            throw CodexReviewAPI.Error.io("Invalid ChatGPT authentication URL in \(field).")
        }
        return url
    }
}

private struct TurnNotificationPayload: Decodable, Sendable {
    var threadID: String?
    var turn: AppServerNotificationTurn?
    var turnID: String?
    var itemID: String?
    var reviewID: String?
    var item: AppServerThreadItem?
    var startedAtMs: Int64?
    var completedAtMs: Int64?
    var reviewThreadID: String?
    var model: String?
    var fromModel: String?
    var toModel: String?
    var reason: String?
    var message: String?
    var stdin: String?
    var summary: String?
    var details: String?
    var delta: String?
    var diff: String?
    var error: AppServerAPI.Turn.Error?
    var willRetry: Bool?
    var status: AppServerThreadStatus?
    var summaryIndex: Int?
    var contentIndex: Int?
    var plan: [AppServerTurnPlanStep]
    var verifications: [String]

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
        case turnID = "turnId"
        case itemID = "itemId"
        case reviewID = "reviewId"
        case item
        case startedAtMs
        case completedAtMs
        case reviewThreadID = "reviewThreadId"
        case model
        case fromModel
        case toModel
        case reason
        case message
        case stdin
        case summary
        case details
        case delta
        case diff
        case error
        case willRetry
        case status
        case summaryIndex
        case contentIndex
        case plan
        case verifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.threadID = try container.decodeStringIfPresent(forKey: .threadID)
        self.turn = try container.decodeIfPresent(AppServerNotificationTurn.self, forKey: .turn)
        self.turnID = try container.decodeStringIfPresent(forKey: .turnID)
        self.itemID = try container.decodeStringIfPresent(forKey: .itemID)
        self.reviewID = try container.decodeStringIfPresent(forKey: .reviewID)
        self.item = try container.decodeIfPresent(AppServerThreadItem.self, forKey: .item)
        self.startedAtMs = try container.decodeIfPresent(Int64.self, forKey: .startedAtMs)
        self.completedAtMs = try container.decodeIfPresent(Int64.self, forKey: .completedAtMs)
        self.reviewThreadID = try container.decodeStringIfPresent(forKey: .reviewThreadID)
        self.model = try container.decodeStringIfPresent(forKey: .model)
        self.fromModel = try container.decodeStringIfPresent(forKey: .fromModel)
        self.toModel = try container.decodeStringIfPresent(forKey: .toModel)
        self.reason = try container.decodeStringIfPresent(forKey: .reason)
        self.message = try container.decodeStringIfPresent(forKey: .message)
        self.stdin = try container.decodeStringIfPresent(forKey: .stdin)
        self.summary = try container.decodeStringIfPresent(forKey: .summary)
        self.details = try container.decodeStringIfPresent(forKey: .details)
        self.delta = try container.decodeStringIfPresent(forKey: .delta)
        self.diff = try container.decodeStringIfPresent(forKey: .diff)
        self.error = try container.decodeIfPresent(AppServerAPI.Turn.Error.self, forKey: .error)
        self.willRetry = try container.decodeIfPresent(Bool.self, forKey: .willRetry)
        self.status = try container.decodeIfPresent(AppServerThreadStatus.self, forKey: .status)
        self.summaryIndex = try container.decodeIfPresent(Int.self, forKey: .summaryIndex)
        self.contentIndex = try container.decodeIfPresent(Int.self, forKey: .contentIndex)
        self.plan = try container.decodeIfPresent([AppServerTurnPlanStep].self, forKey: .plan) ?? []
        self.verifications = try container.decodeIfPresent([String].self, forKey: .verifications) ?? []
    }

    var resolvedTurnID: String? {
        turn?.id ?? turnID
    }

    var startedAt: Date? {
        startedAtMs.map(Self.date(millisecondsSince1970:))
    }

    var completedAt: Date? {
        completedAtMs.map(Self.date(millisecondsSince1970:))
    }

    private static func date(millisecondsSince1970 milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

private struct AppServerNotificationTurn: Decodable, Sendable {
    var id: String
    var status: String?
    var error: AppServerNotificationTurnError?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.status = try container.decodeStringIfPresent(forKey: .status)
        self.error = try container.decodeIfPresent(AppServerNotificationTurnError.self, forKey: .error)
    }
}

private struct AppServerNotificationTurnError: Decodable, Sendable {
    var message: String?

    enum CodingKeys: String, CodingKey {
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.message = try container.decodeStringIfPresent(forKey: .message)
    }
}

private struct AppServerThreadStatus: Decodable, Sendable {
    var type: String
}

private let appServerContextCompactionStartedText = "Automatically compacting context"
private let appServerContextCompactionCompletedText = "Context automatically compacted"
private let appServerContextCompactionFailedText = "Context compaction failed"
private let appServerContextCompactionCancelledText = "Context compaction cancelled"

private func normalizeReviewNotification(
    _ notification: AppServerRoutedReviewNotification,
    commandLifecycleByItemID: inout [String: AppServerCommandLifecycle]
) throws -> DecodedReviewNotification {
    let payload = notification.payload
    let events: [CodexReviewBackendModel.Review.Event]
    switch notification.method {
    case "turn/started":
        events = []
    case "item/started":
        guard let item = payload.item else {
            throw ReviewIngestionError.malformedKnownEvent(
                method: notification.method,
                message: "item is required"
            )
        }
        if item.type == "commandExecution" {
            let lifecycle = AppServerCommandLifecycle(
                item: item,
                startedAt: payload.startedAt,
                completedAt: nil
            )
            commandLifecycleByItemID[item.id] = lifecycle
            events = try item.startedEvents(startedAt: payload.startedAt, lifecycle: lifecycle)
        } else {
            events = try item.startedEvents(startedAt: payload.startedAt, lifecycle: nil)
        }
    case "item/completed":
        guard let item = payload.item else {
            throw ReviewIngestionError.malformedKnownEvent(
                method: notification.method,
                message: "item is required"
            )
        }
        if item.type == "commandExecution" {
            let previous = commandLifecycleByItemID[item.id]
            let lifecycle = AppServerCommandLifecycle(
                item: item,
                startedAt: previous?.startedAt,
                completedAt: payload.completedAt,
                fallback: previous
            )
            events = try item.completedEvents(completedAt: payload.completedAt, lifecycle: lifecycle)
            commandLifecycleByItemID.removeValue(forKey: item.id)
        } else {
            events = try item.completedEvents(completedAt: payload.completedAt, lifecycle: nil)
        }
    case "item/agentMessage/delta":
        guard let delta = payload.delta,
              delta.isEmpty == false
        else {
            events = []
            break
        }
        guard let itemID = payload.itemID else {
            throw ReviewIngestionError.missingRoutingIdentity(method: notification.method)
        }
        events = [.messageDelta(delta, itemID: itemID)]
    case "item/plan/delta":
        events = payload.deltaLog(kind: .plan).map { [$0] } ?? []
    case "item/reasoning/summaryTextDelta":
        events = payload.deltaLog(
            kind: .reasoningSummary,
            groupID: payload.reasoningSummaryGroupKey
        ).map { [$0] } ?? []
    case "item/reasoning/summaryPartAdded":
        events = []
    case "item/reasoning/textDelta":
        events = payload.deltaLog(
            kind: .rawReasoning,
            groupID: payload.rawReasoningGroupKey
        ).map { [$0] } ?? []
    case "item/commandExecution/outputDelta":
        if let itemID = payload.itemID,
           let output = payload.delta,
           output.isEmpty == false {
            commandLifecycleByItemID[itemID]?.appendOutput(output)
        }
        events = payload.deltaLog(
            kind: .commandOutput,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: payload.itemID)
        ).map { [$0] } ?? []
    case "item/fileChange/outputDelta":
        events = payload.deltaLog(
            kind: .commandOutput,
            metadata: .init(sourceType: "fileChange", title: "File change output")
        ).map { [$0] } ?? []
    case "item/mcpToolCall/progress":
        events = payload.messageLog(
            kind: .toolCall,
            metadata: .init(sourceType: "mcpToolCall", title: "Tool progress")
        ).map { [$0] } ?? []
    case "item/fileChange/patchUpdated":
        events = payload.itemID.map {
            [.logEntry(
                kind: .toolCall,
                text: "File changes updated.",
                groupID: $0,
                replacesGroup: false,
                metadata: .init(sourceType: "fileChange", title: "File changes", status: "updated")
            )]
        } ?? []
    case "item/commandExecution/terminalInteraction":
        events = payload.stdin?.nilIfEmpty.flatMap { stdin in
            payload.itemID.map {
                .logEntry(
                    kind: .commandOutput,
                    text: stdin,
                    groupID: $0,
                    replacesGroup: false,
                    metadata: .init(sourceType: "commandExecution", title: "Terminal input")
                )
            }
        }.map { [$0] } ?? []
    case "item/autoApprovalReview/started":
        guard let reviewID = payload.reviewID else {
            throw ReviewIngestionError.malformedKnownEvent(
                method: notification.method,
                message: "reviewId is required"
            )
        }
        events = [.logEntry(
            kind: .diagnostic,
            text: "Approval review started.",
            groupID: reviewID,
            replacesGroup: false
        )]
    case "item/autoApprovalReview/completed":
        guard let reviewID = payload.reviewID else {
            throw ReviewIngestionError.malformedKnownEvent(
                method: notification.method,
                message: "reviewId is required"
            )
        }
        events = [.logEntry(
            kind: .diagnostic,
            text: "Approval review completed.",
            groupID: reviewID,
            replacesGroup: false
        )]
    case "turn/diff/updated":
        guard let diff = payload.diff else {
            throw ReviewIngestionError.malformedKnownEvent(
                method: notification.method,
                message: "diff is required"
            )
        }
        events = [.logEntry(kind: .event, text: diff, groupID: payload.turnID, replacesGroup: true)]
    case "turn/plan/updated":
        events = [.logEntry(
            kind: .todoList,
            text: payload.renderedPlan,
            groupID: payload.turnID,
            replacesGroup: true
        )]
    case "turn/completed":
        events = []
    case "error":
        let message = payload.error?.message ?? payload.message ?? "Failed."
        let kind: ReviewLogEntry.Kind = payload.willRetry == true ? .progress : .error
        events = [.logEntry(
            kind: kind,
            text: message,
            groupID: payload.turnID,
            replacesGroup: false
        )]
    case "thread/closed":
        events = [.logEntry(
            kind: .diagnostic,
            text: "Review thread closed.",
            groupID: payload.threadID,
            replacesGroup: false
        )]
    case "thread/status/changed":
        switch payload.status?.type {
        case "notLoaded":
            events = [.logEntry(
                kind: .diagnostic,
                text: "Review thread is no longer loaded.",
                groupID: payload.threadID,
                replacesGroup: false
            )]
        case "systemError":
            events = [.logEntry(
                kind: .diagnostic,
                text: "Review thread entered a system error state.",
                groupID: payload.threadID,
                replacesGroup: false
            )]
        default:
            events = []
        }
    case "model/rerouted":
        events = [.logEntry(kind: .event, text: payload.modelReroutedText, groupID: payload.turnID, replacesGroup: false)]
    case "model/verification":
        events = [.logEntry(kind: .diagnostic, text: payload.modelVerificationText, groupID: payload.turnID, replacesGroup: false)]
    case "thread/compacted":
        events = [.logEntry(
            kind: .contextCompaction,
            text: appServerContextCompactionCompletedText,
            groupID: payload.turnID.map { "contextCompaction:\($0)" },
            replacesGroup: true,
            metadata: .init(
                sourceType: "contextCompaction",
                status: "completed"
            )
        )]
    case "warning", "guardianWarning", "deprecationNotice", "configWarning":
        guard let message = payload.diagnosticText?.nilIfEmpty else {
            events = []
            break
        }
        events = [.logEntry(kind: .diagnostic, text: message, groupID: payload.turnID, replacesGroup: false)]
    default:
        events = []
    }
    return .init(
        events: events,
        finishesReviewMode: notification.method == "item/completed" && payload.item?.type == "exitedReviewMode"
    )
}

private func reasoningSummaryGroupID(itemID: String, summaryIndex: Int) -> String {
    "\(itemID):summary:\(summaryIndex)"
}

private func rawReasoningGroupID(itemID: String, contentIndex: Int) -> String {
    "\(itemID):\(contentIndex)"
}

private extension TurnNotificationPayload {
    func deltaLog(
        kind: ReviewLogEntry.Kind,
        groupID explicitGroupID: String? = nil,
        metadata: ReviewLogEntry.Metadata? = nil
    ) -> CodexReviewBackendModel.Review.Event? {
        guard let delta,
              delta.isEmpty == false
        else {
            return nil
        }
        return .logEntry(
            kind: kind,
            text: delta,
            groupID: explicitGroupID ?? itemID,
            replacesGroup: false,
            metadata: metadata
        )
    }

    func messageLog(
        kind: ReviewLogEntry.Kind,
        metadata: ReviewLogEntry.Metadata? = nil
    ) -> CodexReviewBackendModel.Review.Event? {
        guard let message,
              message.isEmpty == false
        else {
            return nil
        }
        return .logEntry(
            kind: kind,
            text: message,
            groupID: itemID,
            replacesGroup: false,
            metadata: metadata
        )
    }

    var reasoningSummaryGroupKey: String? {
        guard let itemID,
              let summaryIndex
        else {
            return nil
        }
        return reasoningSummaryGroupID(
            itemID: itemID,
            summaryIndex: summaryIndex
        )
    }

    var rawReasoningGroupKey: String? {
        guard let itemID,
              let contentIndex
        else {
            return nil
        }
        return rawReasoningGroupID(
            itemID: itemID,
            contentIndex: contentIndex
        )
    }

    var renderedPlan: String {
        let steps = plan.map { step in
            "[\(step.status)] \(step.step)"
        }
        return steps.joined(separator: "\n")
    }

    var diagnosticText: String? {
        if let message = message?.nilIfEmpty {
            return message
        }
        if let summary = summary?.nilIfEmpty,
           let details = details?.nilIfEmpty
        {
            return "\(summary)\n\(details)"
        }
        return summary?.nilIfEmpty ?? details?.nilIfEmpty
    }

    var modelReroutedText: String {
        let route = [fromModel, toModel].compactMap { $0?.nilIfEmpty }.joined(separator: " -> ")
        let suffix = reason?.nilIfEmpty.map { " (\($0))" } ?? ""
        return route.isEmpty ? "Model rerouted\(suffix)." : "Model rerouted: \(route)\(suffix)."
    }

    var modelVerificationText: String {
        guard verifications.isEmpty == false else {
            return "Model verification required."
        }
        return "Model verification required: \(verifications.joined(separator: ", "))."
    }
}

private struct AppServerCommandAction: Decodable, Sendable {
    var type: String
    var command: String?
    var name: String?
    var path: String?
    var query: String?

    enum CodingKeys: String, CodingKey {
        case type
        case command
        case name
        case path
        case query
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.command = try container.decodeStringIfPresent(forKey: .command)
        self.name = try container.decodeStringIfPresent(forKey: .name)
        self.path = try container.decodeStringIfPresent(forKey: .path)
        self.query = try container.decodeStringIfPresent(forKey: .query)
    }

    var metadataAction: ReviewLogEntry.Metadata.CommandAction {
        .init(
            kind: metadataKind,
            command: command,
            name: name,
            path: path,
            query: query
        )
    }

    private var metadataKind: ReviewLogEntry.Metadata.CommandAction.Kind {
        switch type {
        case "read":
            .read
        case "listFiles":
            .listFiles
        case "search":
            .search
        default:
            .unknown
        }
    }
}

private struct AppServerCommandLifecycle: Sendable {
    var itemID: String
    var command: String?
    var cwd: String?
    var startedAt: Date?
    var completedAt: Date?
    var durationMs: Int?
    var commandActions: [ReviewLogEntry.Metadata.CommandAction]?
    var commandStatus: String?
    private var streamedOutput = ""

    var streamedOutputIfAvailable: String? {
        streamedOutput.isEmpty ? nil : streamedOutput
    }

    init(
        item: AppServerThreadItem,
        startedAt: Date?,
        completedAt: Date?,
        fallback: AppServerCommandLifecycle? = nil
    ) {
        self.itemID = item.id
        self.command = item.command?.nilIfEmpty ?? fallback?.command
        self.cwd = item.cwd?.nilIfEmpty ?? fallback?.cwd
        self.startedAt = startedAt ?? fallback?.startedAt
        self.completedAt = completedAt ?? fallback?.completedAt
        self.durationMs = item.durationMs ?? fallback?.durationMs
        let actions = item.metadataCommandActions
        self.commandActions = actions?.isEmpty == false ? actions : fallback?.commandActions
        self.commandStatus = item.status?.nilIfEmpty ?? fallback?.commandStatus
        self.streamedOutput = fallback?.streamedOutput ?? ""
    }

    mutating func appendOutput(_ output: String) {
        streamedOutput += output
    }

    func closingEvents(status: String, completedAt: Date) -> [CodexReviewBackendModel.Review.Event] {
        guard let command = command?.nilIfEmpty else {
            return []
        }
        var events: [CodexReviewBackendModel.Review.Event] = []
        let metadata = ReviewLogEntry.Metadata(
            sourceType: "commandExecution",
            status: status,
            itemID: itemID,
            command: command,
            cwd: cwd,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: Self.durationMs(startedAt: startedAt, completedAt: completedAt),
            commandActions: commandActions,
            commandStatus: status
        )
        events.append(.logEntry(
            kind: .command,
            text: "$ \(command)",
            groupID: itemID,
            replacesGroup: true,
            metadata: metadata
        ))
        if streamedOutput.isEmpty == false {
            events.append(.logEntry(
                kind: .commandOutput,
                text: streamedOutput,
                groupID: itemID,
                replacesGroup: true,
                metadata: metadata
            ))
        }
        return events
    }

    private static func durationMs(startedAt: Date?, completedAt: Date) -> Int? {
        guard let startedAt else {
            return nil
        }
        let milliseconds = completedAt.timeIntervalSince(startedAt) * 1000
        guard milliseconds.isFinite else {
            return nil
        }
        return max(0, Int(milliseconds.rounded()))
    }
}

private extension Dictionary where Key == String, Value == AppServerCommandLifecycle {
    func closeActiveCommands(for terminalEvent: CodexReviewBackendModel.Review.Event) -> [CodexReviewBackendModel.Review.Event] {
        guard let status = terminalEvent.activeCommandTerminalStatus else {
            return []
        }
        return closeActiveCommands(status: status)
    }

    func closeActiveCommands(status: String, completedAt: Date = Date()) -> [CodexReviewBackendModel.Review.Event] {
        values
            .sorted {
                switch ($0.startedAt, $1.startedAt) {
                case let (lhs?, rhs?) where lhs != rhs:
                    return lhs < rhs
                default:
                    return $0.itemID < $1.itemID
                }
            }
            .flatMap { $0.closingEvents(status: status, completedAt: completedAt) }
    }
}

private struct AppServerThreadItem: Decodable, Sendable {
    var type: String
    var id: String
    var text: String?
    var command: String?
    var cwd: String?
    var processID: String?
    var source: String?
    var aggregatedOutput: String?
    var exitCode: Int?
    var durationMs: Int?
    var commandActions: [AppServerCommandAction]
    var status: String?
    var server: String?
    var tool: String?
    var namespace: String?
    var query: String?
    var path: String?
    var review: String?
    var summary: [String]?
    var content: [String]?
    var result: AppServerNotificationValue?
    var error: AppServerNotificationValue?
    var success: Bool?
    var prompt: String?
    var activityKind: String?
    var agentThreadID: String?
    var agentPath: String?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case text
        case command
        case cwd
        case processID = "processId"
        case source
        case aggregatedOutput
        case exitCode
        case durationMs
        case commandActions
        case status
        case server
        case tool
        case namespace
        case query
        case path
        case review
        case summary
        case content
        case result
        case error
        case success
        case prompt
        case activityKind = "kind"
        case agentThreadID = "agentThreadId"
        case agentPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.id = try container.decode(String.self, forKey: .id)
        self.text = try container.decodeStringIfPresent(forKey: .text)
        self.command = try container.decodeStringIfPresent(forKey: .command)
        self.cwd = try container.decodeStringIfPresent(forKey: .cwd)
        self.processID = try container.decodeStringIfPresent(forKey: .processID)
        self.source = try container.decodeStringIfPresent(forKey: .source)
        self.aggregatedOutput = try container.decodeStringIfPresent(forKey: .aggregatedOutput)
        self.exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        self.durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        self.commandActions = try container.decodeIfPresent([AppServerCommandAction].self, forKey: .commandActions) ?? []
        self.status = try container.decodeStringIfPresent(forKey: .status)
        self.server = try container.decodeStringIfPresent(forKey: .server)
        self.tool = try container.decodeStringIfPresent(forKey: .tool)
        self.namespace = try container.decodeStringIfPresent(forKey: .namespace)
        self.query = try container.decodeStringIfPresent(forKey: .query)
        self.path = try container.decodeStringIfPresent(forKey: .path)
        self.review = try container.decodeStringIfPresent(forKey: .review)
        if self.type == "reasoning" {
            self.summary = try container.decode([String].self, forKey: .summary)
            self.content = try container.decode([String].self, forKey: .content)
        } else {
            self.summary = nil
            self.content = nil
        }
        self.result = try container.decodeIfPresent(AppServerNotificationValue.self, forKey: .result)
        self.error = try container.decodeIfPresent(AppServerNotificationValue.self, forKey: .error)
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success)
        self.prompt = try container.decodeStringIfPresent(forKey: .prompt)
        self.activityKind = try container.decodeStringIfPresent(forKey: .activityKind)
        self.agentThreadID = try container.decodeStringIfPresent(forKey: .agentThreadID)
        self.agentPath = try container.decodeStringIfPresent(forKey: .agentPath)
    }

    func startedEvents(
        startedAt: Date?,
        lifecycle: AppServerCommandLifecycle?
    ) throws -> [CodexReviewBackendModel.Review.Event] {
        switch type {
        case "userMessage":
            return []
        case "enteredReviewMode":
            return review.map { [.logEntry(kind: .progress, text: "Reviewing \($0)", groupID: id, replacesGroup: true)] } ?? []
        case "commandExecution":
            return (command?.nilIfEmpty ?? lifecycle?.command).map {
                [logEntry(
                    kind: .command,
                    text: "$ \($0)",
                    replacesGroup: true,
                    title: nil,
                    status: "inProgress",
                    startedAt: startedAt,
                    completedAt: nil,
                    lifecycle: lifecycle
                )]
            } ?? []
        case "mcpToolCall":
            return [logEntry(kind: .toolCall, text: "MCP \(toolLabel) started.", replacesGroup: true, title: toolLabel, status: "started")]
        case "dynamicToolCall":
            return [logEntry(kind: .toolCall, text: "Dynamic tool \(toolLabel) started.", replacesGroup: true, title: toolLabel, status: "started")]
        case "collabAgentToolCall":
            return [logEntry(kind: .toolCall, text: "Collab tool \(toolLabel) started.", replacesGroup: true, title: toolLabel, status: "started")]
        case "subAgentActivity":
            return [try subAgentActivityEvent(method: "item/started")]
        case "webSearch":
            return [logEntry(kind: .toolCall, text: "Web search: \(query ?? "started")", replacesGroup: true, title: "Web search", status: "started")]
        case "imageView":
            return [logEntry(kind: .toolCall, text: "View image: \(path ?? "image")", replacesGroup: true, title: "Image view", status: "started")]
        case "sleep":
            return [try sleepEvent(method: "item/started", status: "inProgress")]
        case "imageGeneration":
            return [logEntry(kind: .toolCall, text: "Image generation started.", replacesGroup: true, title: "Image generation", status: "started")]
        case "fileChange":
            return [logEntry(kind: .toolCall, text: "Applying file changes.", replacesGroup: true, title: "File changes", status: "started")]
        case "plan":
            return text.map { [.logEntry(kind: .plan, text: $0, groupID: id, replacesGroup: true)] } ?? []
        case "reasoning":
            return reasoningCompletionEvents(replacesGroup: true)
        case "contextCompaction":
            return [logEntry(
                kind: .contextCompaction,
                text: appServerContextCompactionStartedText,
                replacesGroup: true,
                title: nil,
                status: "inProgress",
                startedAt: startedAt
            )]
        case "hookPrompt":
            return [logEntry(kind: .event, text: "Hook prompt started.", replacesGroup: true, title: "Hook prompt", status: "started", detail: prompt)]
        case "agentMessage":
            return text?.nilIfEmpty.map {
                [.logEntry(kind: .agentMessage, text: $0, groupID: id, replacesGroup: true)]
            } ?? []
        default:
            throw ReviewIngestionError.unsupportedItemType(
                method: "item/started",
                type: type
            )
        }
    }

    func completedEvents(
        completedAt: Date?,
        lifecycle: AppServerCommandLifecycle?
    ) throws -> [CodexReviewBackendModel.Review.Event] {
        switch type {
        case "userMessage":
            return []
        case "agentMessage":
            return text.map {
                [.logEntry(kind: .agentMessage, text: $0, groupID: id, replacesGroup: true)]
            } ?? []
        case "exitedReviewMode":
            return review.map {
                [.logEntry(
                    kind: .agentMessage,
                    text: $0,
                    groupID: id,
                    replacesGroup: true,
                    metadata: .init(sourceType: "exitedReviewMode")
                )]
            } ?? []
        case "commandExecution":
            if let output = aggregatedOutput?.nilIfEmpty ?? lifecycle?.streamedOutputIfAvailable {
                var events: [CodexReviewBackendModel.Review.Event] = []
                if let command = command?.nilIfEmpty ?? lifecycle?.command {
                    events.append(logEntry(
                        kind: .command,
                        text: "$ \(command)",
                        replacesGroup: true,
                        title: nil,
                        status: completedStatus,
                        startedAt: lifecycle?.startedAt,
                        completedAt: completedAt,
                        lifecycle: lifecycle
                    ))
                }
                events.append(logEntry(
                    kind: .commandOutput,
                    text: output,
                    replacesGroup: true,
                    title: nil,
                    status: completedStatus,
                    startedAt: lifecycle?.startedAt,
                    completedAt: completedAt,
                    lifecycle: lifecycle
                ))
                return events
            }
            if let command = command?.nilIfEmpty ?? lifecycle?.command {
                return [logEntry(
                    kind: .command,
                    text: "$ \(command)",
                    replacesGroup: true,
                    title: nil,
                    status: completedStatus,
                    startedAt: lifecycle?.startedAt,
                    completedAt: completedAt,
                    lifecycle: lifecycle
                )]
            }
            return []
        case "plan":
            return text.map { [.logEntry(kind: .plan, text: $0, groupID: id, replacesGroup: true)] } ?? []
        case "reasoning":
            return reasoningCompletionEvents(replacesGroup: true)
        case "mcpToolCall":
            return [logEntry(kind: .toolCall, text: "\(toolLabel) \(status ?? "completed").\(resultSuffix)", replacesGroup: true, title: toolLabel, status: completedStatus)]
        case "dynamicToolCall":
            return [logEntry(kind: .toolCall, text: "Dynamic tool \(toolLabel) \(status ?? "completed").\(resultSuffix)", replacesGroup: true, title: toolLabel, status: completedStatus)]
        case "collabAgentToolCall":
            return [logEntry(kind: .toolCall, text: "Collab tool \(toolLabel) \(status ?? "completed").\(promptSuffix)", replacesGroup: true, title: toolLabel, status: completedStatus, detail: prompt)]
        case "subAgentActivity":
            return [try subAgentActivityEvent(method: "item/completed")]
        case "webSearch":
            return [logEntry(kind: .toolCall, text: "Web search completed: \(query ?? "search").", replacesGroup: true, title: "Web search", status: completedStatus)]
        case "imageView":
            return [logEntry(kind: .toolCall, text: "Image viewed: \(path ?? "image").", replacesGroup: true, title: "Image view", status: completedStatus)]
        case "sleep":
            return [try sleepEvent(method: "item/completed", status: "completed")]
        case "imageGeneration":
            return [logEntry(kind: .toolCall, text: "Image generation \(status ?? "completed").\(resultSuffix)", replacesGroup: true, title: "Image generation", status: completedStatus)]
        case "fileChange":
            return [logEntry(kind: .toolCall, text: "File changes \(status ?? "completed").", replacesGroup: true, title: "File changes", status: completedStatus)]
        case "contextCompaction":
            let resolvedStatus = completedStatus
            return [logEntry(
                kind: .contextCompaction,
                text: Self.contextCompactionCompletionText(for: resolvedStatus),
                replacesGroup: true,
                title: nil,
                status: resolvedStatus,
                completedAt: completedAt
            )]
        case "hookPrompt":
            return [logEntry(kind: .event, text: "Hook prompt completed.", replacesGroup: true, title: "Hook prompt", status: completedStatus, detail: prompt)]
        case "enteredReviewMode":
            return []
        default:
            throw ReviewIngestionError.unsupportedItemType(
                method: "item/completed",
                type: type
            )
        }
    }

    private func logEntry(
        kind: ReviewLogEntry.Kind,
        text: String,
        replacesGroup: Bool,
        title: String?,
        status explicitStatus: String? = nil,
        detail: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        lifecycle: AppServerCommandLifecycle? = nil
    ) -> CodexReviewBackendModel.Review.Event {
        .logEntry(
            kind: kind,
            text: text,
            groupID: id,
            replacesGroup: replacesGroup,
            metadata: metadata(
                title: title,
                status: explicitStatus,
                detail: detail,
                startedAt: startedAt,
                completedAt: completedAt,
                lifecycle: lifecycle
            )
        )
    }

    private func subAgentActivityEvent(
        method: String
    ) throws -> CodexReviewBackendModel.Review.Event {
        guard let activityKind,
              let agentThreadID,
              let agentPath
        else {
            throw ReviewIngestionError.malformedKnownEvent(
                method: method,
                message: "subAgentActivity requires kind, agentThreadId, and agentPath"
            )
        }
        return .logEntry(
            kind: .event,
            text: "Subagent \(agentPath): \(activityKind).",
            groupID: id,
            replacesGroup: true,
            metadata: .init(
                sourceType: "subAgentActivity",
                status: activityKind,
                detail: agentThreadID
            )
        )
    }

    private func sleepEvent(
        method: String,
        status: String
    ) throws -> CodexReviewBackendModel.Review.Event {
        guard let durationMs else {
            throw ReviewIngestionError.malformedKnownEvent(
                method: method,
                message: "sleep requires durationMs"
            )
        }
        return .logEntry(
            kind: .event,
            text: status == "completed"
                ? "Slept for \(durationMs) ms."
                : "Sleeping for \(durationMs) ms.",
            groupID: id,
            replacesGroup: true,
            metadata: .init(
                sourceType: "sleep",
                status: status,
                durationMs: durationMs
            )
        )
    }

    private func metadata(
        title: String?,
        status explicitStatus: String?,
        detail: String?,
        startedAt explicitStartedAt: Date? = nil,
        completedAt explicitCompletedAt: Date? = nil,
        lifecycle: AppServerCommandLifecycle? = nil
    ) -> ReviewLogEntry.Metadata {
        let resolvedStartedAt = explicitStartedAt ?? lifecycle?.startedAt
        let resolvedCompletedAt = explicitCompletedAt ?? lifecycle?.completedAt
        let computedDurationMs = Self.durationMs(
            startedAt: resolvedStartedAt,
            completedAt: resolvedCompletedAt
        )
        let resolvedDurationMs = Self.resolvedDurationMs(
            reported: durationMs ?? lifecycle?.durationMs,
            computed: computedDurationMs
        )
        let actions = metadataCommandActions
        let resolvedCommandActions = actions?.isEmpty == false ? actions : lifecycle?.commandActions
        let explicitStatusValue = explicitStatus?.nilIfEmpty
        let itemStatus = self.status?.nilIfEmpty
        let resolvedStatus: String? = explicitStatusValue ?? itemStatus
        let resolvedCommandStatus: String? = itemStatus ?? explicitStatusValue ?? lifecycle?.commandStatus
        let isCommandExecution = type == "commandExecution"
        let isLifecycleItem = isCommandExecution || type == "contextCompaction"
        return .init(
            sourceType: type,
            title: title?.nilIfEmpty,
            status: resolvedStatus,
            detail: detail?.nilIfEmpty,
            itemID: isLifecycleItem ? id : nil,
            command: command?.nilIfEmpty ?? lifecycle?.command,
            cwd: cwd?.nilIfEmpty ?? lifecycle?.cwd?.nilIfEmpty,
            exitCode: exitCode,
            startedAt: isLifecycleItem ? resolvedStartedAt : nil,
            completedAt: isLifecycleItem ? resolvedCompletedAt : nil,
            durationMs: isCommandExecution ? resolvedDurationMs : nil,
            commandActions: isCommandExecution ? resolvedCommandActions : nil,
            commandStatus: isCommandExecution ? resolvedCommandStatus : nil,
            namespace: namespace,
            server: server,
            tool: tool,
            query: query,
            path: path,
            resultText: result?.nonNullDebugText?.nilIfEmpty,
            errorText: error?.nonNullDebugText?.nilIfEmpty
        )
    }

    var metadataCommandActions: [ReviewLogEntry.Metadata.CommandAction]? {
        guard commandActions.isEmpty == false else {
            return nil
        }
        return commandActions.map(\.metadataAction)
    }

    private static func durationMs(startedAt: Date?, completedAt: Date?) -> Int? {
        guard let startedAt, let completedAt else {
            return nil
        }
        let milliseconds = completedAt.timeIntervalSince(startedAt) * 1000
        guard milliseconds.isFinite else {
            return nil
        }
        return max(0, Int(milliseconds.rounded()))
    }

    private static func resolvedDurationMs(reported: Int?, computed: Int?) -> Int? {
        guard let reported else {
            return computed
        }
        guard reported <= 0,
              let computed,
              computed > 0
        else {
            return max(0, reported)
        }
        return computed
    }

    private var completedStatus: String? {
        if let status = status?.nilIfEmpty {
            return status
        }
        if let exitCode {
            return exitCode == 0 ? "succeeded" : "failed"
        }
        if error?.nonNullDebugText?.nilIfEmpty != nil {
            return "failed"
        }
        if let success {
            return success ? "succeeded" : "failed"
        }
        return "completed"
    }

    private static func contextCompactionCompletionText(for status: String?) -> String {
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

    private var toolLabel: String {
        [namespace, server, tool]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: ".")
            .nilIfEmpty ?? type
    }

    private var resultSuffix: String {
        if let error = error?.nonNullDebugText?.nilIfEmpty {
            return " Error: \(error)"
        }
        if let result = result?.nonNullDebugText?.nilIfEmpty {
            return " Result: \(result)"
        }
        return ""
    }

    private var promptSuffix: String {
        prompt?.nilIfEmpty.map { " Prompt: \($0)" } ?? resultSuffix
    }

    private func reasoningCompletionEvents(replacesGroup: Bool) -> [CodexReviewBackendModel.Review.Event] {
        let summaryEvents = (summary ?? []).enumerated().compactMap { index, text -> CodexReviewBackendModel.Review.Event? in
            guard text.isEmpty == false else {
                return nil
            }
            return .logEntry(
                kind: .reasoningSummary,
                text: text,
                groupID: reasoningSummaryGroupID(itemID: id, summaryIndex: index),
                replacesGroup: replacesGroup
            )
        }
        let rawEvents = (content ?? []).enumerated().compactMap { index, text -> CodexReviewBackendModel.Review.Event? in
            guard text.isEmpty == false else {
                return nil
            }
            return .logEntry(
                kind: .rawReasoning,
                text: text,
                groupID: rawReasoningGroupID(itemID: id, contentIndex: index),
                replacesGroup: replacesGroup
            )
        }
        return summaryEvents + rawEvents
    }
}

private struct AppServerTurnPlanStep: Decodable, Sendable {
    var step: String
    var status: String
}

private enum AppServerNotificationValue: Decodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AppServerNotificationValue])
    case array([AppServerNotificationValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: AppServerNotificationValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([AppServerNotificationValue].self))
        }
    }

    var nonNullDebugText: String? {
        if case .null = self {
            return nil
        }
        return debugText
    }

    private var debugText: String {
        switch self {
        case .string(let value):
            value
        case .int(let value):
            String(value)
        case .double(let value):
            String(value)
        case .bool(let value):
            String(value)
        case .object(let value):
            Self.jsonText(value.mapValues(\.foundationObject), fallback: "{}")
        case .array(let value):
            Self.jsonText(value.map(\.foundationObject), fallback: "[]")
        case .null:
            "null"
        }
    }

    private var foundationObject: Any {
        switch self {
        case .string(let value):
            value
        case .int(let value):
            value
        case .double(let value):
            value
        case .bool(let value):
            value
        case .object(let value):
            value.mapValues(\.foundationObject)
        case .array(let value):
            value.map(\.foundationObject)
        case .null:
            NSNull()
        }
    }

    private static func jsonText(_ object: Any, fallback: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ),
              let text = String(data: data, encoding: .utf8)
        else {
            return fallback
        }
        return text
    }
}

private extension KeyedDecodingContainer {
    func decodeStringIfPresent(forKey key: Key) throws -> String? {
        try decodeIfPresent(String.self, forKey: key)
    }
}
