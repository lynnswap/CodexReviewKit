import Foundation
import CodexAppServerKit
import CodexReviewKit
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

    private let appServer: CodexAppServer?
    private let client: AppServerClient
    private let threadStartPermissionStrategy: AppServerAPI.Thread.Start.PermissionStrategy
    private var controlsByThreadID: [String: AppServerReviewControl] = [:]
    private var reviewEventSessionsByAttemptID: [String: AppServerReviewEventSession] = [:]
    private var activeReviewAttemptIDByThreadID: [String: String] = [:]
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

    package init(appServer: CodexAppServer) {
        self.appServer = appServer
        self.client = appServer.appServerClient
        self.threadStartPermissionStrategy = appServer.threadStartPermissionStrategy
    }

    package init(
        client: AppServerClient,
        threadStartPermissionStrategy: AppServerAPI.Thread.Start.PermissionStrategy = .modernPermissions
    ) {
        self.appServer = nil
        self.client = client
        self.threadStartPermissionStrategy = threadStartPermissionStrategy
    }

    package func readSettings() async throws -> CodexReviewBackendModel.Settings.Snapshot {
        if let appServer {
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
        if let appServer {
            guard let account = try await appServer.account() else {
                return .init()
            }
            let backendAccount = account.backendAccount
            return .init(accounts: [backendAccount], activeAccountID: backendAccount.id)
        }
        _ = try await client.initialize()
        let response = try await client.send(AppServerAPI.Auth.Read.Request())
        guard let account = response.account?.backendAccount else {
            return .init()
        }
        return .init(accounts: [account], activeAccountID: account.id)
    }

    package func readRateLimits() async throws -> CodexRateLimits {
        if let appServer {
            return try await appServer.rateLimits()
        }
        _ = try await client.initialize()
        let response = try await client.send(AppServerAPI.Account.RateLimits.Read.Request())
        return .init(appServer: response)
    }

    package func startLogin(_ request: CodexReviewBackendModel.Login.Request) async throws -> CodexReviewBackendModel.Login.Challenge {
        if let appServer {
            let handle = try await appServer.loginChatGPT(
                callbackURLScheme: request.nativeWebAuthenticationCallbackScheme
            )
            return try handle.backendChallenge(
                nativeWebAuthenticationCallbackScheme: request.nativeWebAuthenticationCallbackScheme
            )
        }
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
        if let appServer {
            try await appServer.cancelLogin(id: .init(rawValue: challenge.id))
            return
        }
        _ = try await client.initialize()
        let _: AppServerAPI.Account.Login.Cancel.Response = try await client.send(
            method: "account/login/cancel",
            params: AppServerAPI.Account.Login.Cancel.Params(loginID: challenge.id),
            responseType: AppServerAPI.Account.Login.Cancel.Response.self
        )
    }

    package func completeLogin(_ response: CodexReviewBackendModel.Login.Response) async throws -> CodexReviewBackendModel.Auth.Snapshot {
        if let callbackURL = response.callbackURL {
            if let appServer {
                guard let url = URL(string: callbackURL) else {
                    throw CodexReviewAPI.Error.io("Invalid ChatGPT authentication callback URL.")
                }
                try await appServer.completeLogin(
                    id: .init(rawValue: response.challengeID),
                    callbackURL: url
                )
                return try await readAuth()
            }
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
        if let appServer {
            try await appServer.logout()
            return try await readAuth()
        }
        _ = try await client.initialize()
        let _: EmptyResponse = try await client.send(
            method: "account/logout",
            params: EmptyResponse(),
            responseType: EmptyResponse.self
        )
        return try await readAuth()
    }

    package func startReview(_ request: CodexReviewBackendModel.Review.Start) async throws -> BackendReviewAttempt {
        if let appServer {
            return try await startReview(appServer: appServer, request: request)
        }
        _ = try await client.initialize()
        await ensureNotificationRouterStarted()
        let control = AppServerReviewControl(client: client)

        let thread = try await startReviewThread(request)
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

        let review: AppServerAPI.Review.Start.Response
        reviewStartRequestsInFlight += 1
        do {
            review = try await client.send(AppServerAPI.Review.Start.Request(
                params: .init(
                    threadID: thread.threadID,
                    target: request.request.target.appServerReviewTarget
                )
            ))
        } catch {
            reviewStartRequestsInFlight -= 1
            discardUnmatchedReviewNotificationsIfIdle()
            await cleanupReview(provisionalRun)
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
        reviewStartRequestsInFlight -= 1
        discardUnmatchedReviewNotificationsIfIdle()

        return await session.attempt()
    }

    private func startReview(
        appServer: CodexAppServer,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> BackendReviewAttempt {
        let control = AppServerReviewControl(client: client)
        let thread = try await startReviewThread(appServer: appServer, request: request)
        controlsByThreadID[thread.id.rawValue] = control

        let attemptID = makeAppServerReviewAttemptID()
        let provisionalRun = CodexReviewBackendModel.Review.Run(
            attemptID: attemptID,
            threadID: thread.id.rawValue,
            reviewThreadID: thread.id.rawValue,
            model: thread.model ?? request.model
        )
        let session = AppServerReviewEventSession(
            run: provisionalRun,
            control: control,
            isRunFinalized: false
        )
        registerReviewEventSession(session, for: provisionalRun)
        control.recordThreadStarted(threadID: thread.id.rawValue)

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
        await session.finalizeRun()
        await session.startConsuming(review)

        return await session.attempt()
    }

    private func startReviewThread(
        appServer: CodexAppServer,
        request: CodexReviewBackendModel.Review.Start
    ) async throws -> CodexThread {
        let workspace = URL(fileURLWithPath: request.request.cwd, isDirectory: true)
        if threadStartPermissionStrategy == .legacySandbox {
            // Deprecated compatibility: installed Codex builds without the app-server v2
            // session-source flag can ignore permissions without failing the request.
            return try await appServer.startThread(
                in: workspace,
                options: reviewThreadOptions(request, sandbox: .fullAccess)
            )
        }
        do {
            return try await appServer.startThread(
                in: workspace,
                options: reviewThreadOptions(request, permissions: .profile(id: Self.reviewPermissionProfileID))
            )
        } catch let error as JSONRPC.Error where Self.shouldRetryThreadStartWithObjectPermissions(error) {
            // Deprecated compatibility: installed Codex builds can require object-shaped
            // permissions while the latest local app-server source accepts a profile ID string.
            do {
                return try await appServer.startThread(
                    in: workspace,
                    options: reviewThreadOptions(
                        request,
                        permissions: .profileSelection(id: Self.reviewPermissionProfileID)
                    )
                )
            } catch let error as JSONRPC.Error where Self.shouldRetryThreadStartWithLegacySandbox(error) {
                // Deprecated compatibility: installed Codex builds can know the permissions
                // object shape without registering the danger-full-access built-in profile.
                return try await appServer.startThread(
                    in: workspace,
                    options: reviewThreadOptions(request, sandbox: .fullAccess)
                )
            }
        } catch let error as JSONRPC.Error where Self.shouldRetryThreadStartWithLegacySandbox(error) {
            // Deprecated compatibility: some builds accept the permissions field shape
            // without registering the danger-full-access built-in profile.
            return try await appServer.startThread(
                in: workspace,
                options: reviewThreadOptions(request, sandbox: .fullAccess)
            )
        }
    }

    private func reviewThreadOptions(
        _ request: CodexReviewBackendModel.Review.Start,
        permissions: CodexThreadPermissions? = nil,
        sandbox: CodexSandbox? = nil
    ) -> CodexThread.Options {
        .init(
            model: request.model,
            approvalMode: .denyAll,
            sandbox: sandbox,
            permissions: permissions,
            ephemeral: false,
            sessionStartSource: .startup,
            threadSource: .user
        )
    }

    private func startReviewThread(_ request: CodexReviewBackendModel.Review.Start) async throws -> AppServerAPI.Thread.Start.Response {
        if threadStartPermissionStrategy == .legacySandbox {
            // Deprecated compatibility: installed Codex builds without the app-server v2
            // session-source flag can ignore permissions without failing the request.
            return try await client.send(AppServerAPI.Thread.Start.Request(
                params: threadStartParamsWithLegacySandbox(request)
            ))
        }
        do {
            return try await startReviewThreadWithProfileIDPermissions(request)
        } catch let error as JSONRPC.Error where Self.shouldRetryThreadStartWithLegacySandbox(error) {
            // Deprecated compatibility: some builds accept the permissions field shape
            // without registering the danger-full-access built-in profile.
            return try await client.send(AppServerAPI.Thread.Start.Request(
                params: threadStartParamsWithLegacySandbox(request)
            ))
        } catch let error as JSONRPC.Error where Self.shouldRetryThreadStartWithObjectPermissions(error) {
            // Deprecated compatibility: installed Codex builds can require object-shaped
            // permissions while the latest local app-server source accepts a profile ID string.
            return try await startReviewThreadWithProfileSelectionPermissions(request)
        }
    }

    private func startReviewThreadWithProfileIDPermissions(
        _ request: CodexReviewBackendModel.Review.Start
    ) async throws -> AppServerAPI.Thread.Start.Response {
        try await client.send(AppServerAPI.Thread.Start.Request(
            params: threadStartParams(
                request,
                permissions: .profileID(Self.reviewPermissionProfileID)
            )
        ))
    }

    private func startReviewThreadWithProfileSelectionPermissions(
        _ request: CodexReviewBackendModel.Review.Start
    ) async throws -> AppServerAPI.Thread.Start.Response {
        do {
            return try await client.send(AppServerAPI.Thread.Start.Request(
                params: threadStartParams(
                    request,
                    permissions: .profileSelection(.init(id: Self.reviewPermissionProfileID))
                )
            ))
        } catch let error as JSONRPC.Error
            where Self.shouldRetryThreadStartWithLegacySandbox(error)
        {
            // Deprecated compatibility: installed Codex builds can know the permissions
            // object shape without registering the danger-full-access built-in profile.
            return try await client.send(AppServerAPI.Thread.Start.Request(
                params: threadStartParamsWithLegacySandbox(request)
            ))
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

    package func interruptReview(_ run: CodexReviewBackendModel.Review.Run, reason: CodexReviewBackendModel.CancellationReason) async throws {
        _ = try await client.initialize()
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
        _ = try await client.initialize()
        await ensureNotificationRouterStarted()
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
        _ = try await client.initialize()
        await ensureNotificationRouterStarted()
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

        let review: AppServerAPI.Review.Start.Response
        reviewStartRequestsInFlight += 1
        do {
            review = try await client.send(AppServerAPI.Review.Start.Request(
                params: .init(
                    threadID: interruptedRun.threadID,
                    target: request.request.target.appServerReviewTarget
                )
            ))
        } catch {
            reviewStartRequestsInFlight -= 1
            _ = unregisterReviewEventSession(for: provisionalRun)
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
        reviewStartRequestsInFlight -= 1
        discardUnmatchedReviewNotificationsIfIdle()

        return await session.attempt()
    }

    package func cleanupReview(_ run: CodexReviewBackendModel.Review.Run) async {
        _ = try? await client.initialize()
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
        let _: EmptyResponse? = try? await client.send(AppServerAPI.Thread.BackgroundTerminals.Clean.Request(
            params: .init(threadID: run.threadID)
        ))
        let _: AppServerAPI.Thread.Unsubscribe.Response? = try? await client.send(AppServerAPI.Thread.Unsubscribe.Request(
            params: .init(threadID: run.threadID)
        ))
        for threadID in cleanupThreadIDs {
            let _: EmptyResponse? = try? await client.send(AppServerAPI.Thread.Delete.Request(
                params: .init(threadID: threadID)
            ))
        }
        for threadID in cleanupThreadIDs {
            reviewEventSessionCanonicalThreadIDByThreadID.removeValue(forKey: threadID)
            activeReviewAttemptIDByThreadID.removeValue(forKey: threadID)
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
        if appServer == nil {
            await ensureNotificationRouterStarted()
        }
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
            await finishAllReviewEventSessions(throwing: nil)
        } catch {
            await finishAllReviewEventSessions(throwing: error)
        }
        notificationRouterTask = nil
    }

    private func routeReviewNotification(_ notification: JSONRPC.Notification) async {
        notificationRouterMetrics.received += 1
        let method = AppServerReviewNotification.Method(rawValue: notification.method)
        guard method.isReviewNotificationMethod else {
            notificationRouterMetrics.ignored += 1
            return
        }
        guard let reviewNotification = try? AppServerReviewNotification(
            method: notification.method,
            paramsData: notification.params
        ) else {
            notificationRouterMetrics.ignored += 1
            return
        }
        let payload = reviewNotification.payload
        notificationRouterMetrics.decoded += 1
        if let turnID = payload.resolvedTurnID,
           abandonedTurnIDs.contains(turnID) {
            notificationRouterMetrics.ignored += 1
            return
        }

        reviewNotificationSequence += 1
        let routed = AppServerRoutedReviewNotification(
            sequence: reviewNotificationSequence,
            reviewNotification: reviewNotification
        )
        if let threadID = payload.threadID {
            guard let session = reviewEventSession(forThreadID: threadID) else {
                if bufferUnmatchedReviewNotification(routed) {
                    return
                }
                notificationRouterMetrics.ignored += 1
                return
            }
            notificationRouterMetrics.routed += 1
            await session.receive(routed)
        } else if method.isThreadlessReviewBroadcast {
            let sessions = Array(reviewEventSessionsByAttemptID.values)
            guard sessions.isEmpty == false else {
                notificationRouterMetrics.ignored += 1
                return
            }
            notificationRouterMetrics.routed += sessions.count
            for session in sessions {
                await session.receive(routed)
            }
        } else {
            notificationRouterMetrics.ignored += 1
        }
    }

    private func finishAllReviewEventSessions(throwing error: (any Error)?) async {
        let sessions = Array(reviewEventSessionsByAttemptID.values)
        for session in sessions {
            await session.finish(throwing: error)
        }
    }

    private func readModelCatalog() async throws -> [CodexReviewSettings.ModelCatalogItem] {
        var cursor: String?
        var models: [CodexReviewSettings.ModelCatalogItem] = []
        repeat {
            let response = try await client.send(AppServerAPI.Model.List.Request(
                params: .init(cursor: cursor, includeHidden: true)
            ))
            models.append(contentsOf: response.data.map(\.reviewModelCatalogItem))
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
    var reviewNotification: AppServerReviewNotification

    var method: String {
        reviewNotification.rawMethod
    }

    var payload: TurnNotificationPayload {
        reviewNotification.payload
    }
}

private struct DecodedReviewNotification {
    var events: [CodexReviewBackendModel.Review.Event]
    var turnID: String?
    var startsReviewMode: Bool
    var finishesReviewMode: Bool
    var hasDirectTimelineEvents: Bool

    var reviewExitResult: String? {
        guard finishesReviewMode else {
            return nil
        }
        var result: String?
        for event in events {
            guard case .logEntry(.agentMessage, let text, _, _, _) = event,
                  let text = text.nilIfEmpty
            else {
                continue
            }
            result = text
        }
        return result
    }

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
        guard command.command.isEmpty == false else {
            return []
        }
        var events: [CodexReviewBackendModel.Review.Event] = [
            item.logEntry(
                kind: .command,
                text: "$ \(command.command)",
                phase: phase,
                title: nil
            ),
        ]
        if let output = command.output?.nilIfEmpty {
            events.append(item.logEntry(
                kind: .commandOutput,
                text: output,
                phase: phase,
                title: nil
            ))
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
    private var trackedTurnIDs: Set<String>
    private var emittedStartedTurnIDs: Set<String> = []
    private var reviewThreadIDsForCleanup: [String] = []
    private var commandLifecycleByItemID: [String: AppServerCommandLifecycle] = [:]
    private var pendingStreamedLogEntries: [PendingStreamedLogEntry] = []
    private var pendingStreamedLogIndexByKey: [PendingStreamedLogEntry.Key: Int] = [:]
    private var streamedLogFlushTask: Task<Void, Never>?
    private var awaitingReviewExit = false
    private var cancellationRequestedMessage: String?
    private let completionCoordinator = ReviewCompletionCoordinator()
    private let createdAt = Date()
    private var finished = false
    private var isRunFinalized: Bool
    private var isDrainingStartupNotifications = false
    private var pendingStartupNotifications: [AppServerRoutedReviewNotification] = []
    private var metrics = AppServerReviewEventSessionMetrics()
    private var typedReviewStreamTask: Task<Void, Never>?
    private var typedMessageTextByItemID: [String: String] = [:]
    private var typedReviewResultText: String?

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
        self.trackedTurnIDs = Set(run.turnID.map { [$0] } ?? [])
        if let reviewThreadID = run.reviewThreadID?.nilIfEmpty,
           reviewThreadID != run.threadID {
            self.reviewThreadIDsForCleanup.append(reviewThreadID)
        }
    }

    func updateRun(_ run: CodexReviewBackendModel.Review.Run) {
        self.run = run
        if let turnID = run.turnID {
            trackedTurnIDs.insert(turnID)
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
        cancelTypedReviewStream()
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

    func finish(throwing error: (any Error)?) async {
        guard finished == false else {
            return
        }
        cancelTypedReviewStream()
        let precedingEvents = drainPendingStreamedLogEvents()
        finished = true
        completionCoordinator.cancelPendingCompletion()
        cancelPendingStreamedLogFlush()
        commandLifecycleByItemID.removeAll(keepingCapacity: true)
        pendingStartupNotifications.removeAll(keepingCapacity: true)
        await emitPrecedingEvents(precedingEvents)
        if let error {
            await mailbox.fail(error)
        } else {
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
        pendingStartupNotifications.removeAll(keepingCapacity: true)
        await emitPrecedingEvents(precedingEvents)
        if let cancellationMessage {
            _ = await emit(.cancelled(cancellationMessage))
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
        var decodedCommandLifecycleByItemID = commandLifecycleByItemID
        guard let decoded = try? decodeReviewNotification(
            notification,
            fallbackReviewThreadID: run.reviewThreadID ?? run.threadID,
            commandLifecycleByItemID: &decodedCommandLifecycleByItemID
        ) else {
            metrics.ignored += 1
            return
        }
        metrics.decoded += 1
        let controlThreadID = notification.payload.threadID
        guard decoded.events.isEmpty == false else {
            metrics.ignored += 1
            return
        }
        if decoded.startsReviewMode {
            awaitingReviewExit = true
        }

        let shouldEmitNotification: Bool
        if decoded.events.count == 1,
           case .started(let turnID, let reviewThreadID, _) = decoded.events[0]
        {
            let matchesDetachedReviewThread = run.reviewThreadID != nil
                && run.reviewThreadID != run.threadID
                && reviewThreadID == run.reviewThreadID
            guard trackedTurnIDs.isEmpty
                || trackedTurnIDs.contains(turnID)
                || matchesDetachedReviewThread
                || notification.payload.threadID == run.threadID
            else {
                metrics.ignored += 1
                return
            }
            trackedTurnIDs.insert(turnID)
            shouldEmitNotification = emittedStartedTurnIDs.insert(turnID).inserted
        } else if let turnID = decoded.turnID {
            if trackedTurnIDs.contains(turnID) == false {
                let preservesReviewModeCompletion = awaitingReviewExit
                    && decoded.finishesReviewMode
                if decoded.startsReviewMode || trackedTurnIDs.isEmpty {
                    trackedTurnIDs.insert(turnID)
                } else if preservesReviewModeCompletion {
                    trackedTurnIDs.insert(turnID)
                } else {
                    metrics.ignored += 1
                    return
                }
            }
            if decoded.events.contains(where: \.triggersSyntheticStartedTurn),
               emittedStartedTurnIDs.contains(turnID) == false
            {
                emittedStartedTurnIDs.insert(turnID)
                let started = CodexReviewBackendModel.Review.Event.started(
                    turnID: turnID,
                    reviewThreadID: run.reviewThreadID ?? run.threadID,
                    model: nil
                )
                if await emit(started, controlThreadID: controlThreadID) {
                    return
                }
            }
            shouldEmitNotification = true
        } else {
            shouldEmitNotification = true
        }

        guard shouldEmitNotification else {
            metrics.ignored += 1
            return
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

        for index in decoded.events.indices {
            let event = decoded.events[index]
            if case .domainEvents = event {
                let followingEvents = decoded.events[decoded.events.index(after: index)...]
                if shouldFlushPendingStreamedLogBeforeDomainEvent(
                    followingEvents: followingEvents,
                    suppressTimelineProjection: decoded.hasDirectTimelineEvents
                ),
                   await flushPendingStreamedLog(controlThreadID: controlThreadID) {
                    return
                }
                if await emit(event, controlThreadID: controlThreadID) {
                    return
                }
                continue
            }
            if bufferStreamedLog(
                event,
                suppressTimelineProjection: decoded.hasDirectTimelineEvents
            ) {
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
            if event.shouldDeferCompletion(awaitingReviewExit: awaitingReviewExit) {
                completionCoordinator.deferCompletion(event)
                continue
            }
            if await emit(event, controlThreadID: controlThreadID) {
                return
            }
        }

        if decoded.finishesReviewMode {
            if await flushPendingStreamedLog(controlThreadID: controlThreadID) {
                return
            }
            awaitingReviewExit = false
            if let cancellationRequestedMessage {
                if await emit(
                    .cancelled(cancellationRequestedMessage),
                    controlThreadID: controlThreadID
                ) {
                    return
                }
            }
            if let reviewExitResult = decoded.reviewExitResult {
                completionCoordinator.cancelPendingCompletion()
                if await emit(
                    .completed(summary: "Succeeded.", result: reviewExitResult),
                    controlThreadID: controlThreadID
                ) {
                    return
                }
            } else if await flushPendingCompletion(controlThreadID: controlThreadID) {
                return
            } else if await emit(
                .completed(summary: "Succeeded.", result: nil),
                controlThreadID: controlThreadID
            ) {
                return
            }
        }
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

    private func shouldCloseActiveCommandsBeforeEvents(
        notification: AppServerRoutedReviewNotification,
        decoded: DecodedReviewNotification
    ) -> Bool {
        guard commandLifecycleByItemID.isEmpty == false else {
            return false
        }
        let startsNewCommand = notification.method == "item/started"
            && notification.payload.item?.rawType == "commandExecution"
        let reachesModelProgress = decoded.events.contains(where: Self.isCommandProgressBoundary(_:))
        guard startsNewCommand || reachesModelProgress else {
            return false
        }

        switch notification.method {
        case "item/commandExecution/outputDelta",
            "command/exec/outputDelta",
            "process/outputDelta",
            "item/commandExecution/terminalInteraction":
            return false
        case "item/completed" where notification.payload.item?.rawType == "commandExecution":
            return false
        case "turn/completed", "turn/failed", "turn/cancelled", "thread/closed":
            return false
        default:
            return true
        }
    }

    private static func isCommandProgressBoundary(_ event: CodexReviewBackendModel.Review.Event) -> Bool {
        switch event {
        case .started, .message, .messageDelta, .log:
            return true
        case .domainEvents(let events, _):
            return events.contains(where: \.isCommandProgressBoundary)
        case .suppressNextLegacyTimelineProjection,
             .suppressNextTerminalFailureLogTimelineProjection:
            return false
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
        noteEmission(event)
        await mailbox.append(event)
        recordReviewEvent(event, controlThreadID: controlThreadID)
        return true
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

    var triggersSyntheticStartedTurn: Bool {
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

    func shouldDeferCompletion(awaitingReviewExit: Bool) -> Bool {
        guard case .completed(_, let result) = self else {
            return false
        }
        return awaitingReviewExit && result?.nilIfEmpty == nil
    }

    var activeCommandTerminalStatus: String? {
        switch self {
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .cancelled:
            return "canceled"
        case .domainEvents,
             .suppressNextLegacyTimelineProjection,
             .suppressNextTerminalFailureLogTimelineProjection,
             .started,
             .message,
             .messageDelta,
             .log,
             .logEntry:
            return nil
        }
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

private extension ReviewDomainEvent {
    var isDirectTimelineEvent: Bool {
        switch self {
        case .itemStarted(let seed),
             .itemUpdated(let seed),
             .itemCompleted(let seed):
            seed.family.hasEquivalentDirectTimelineProjection
        case .textDelta(_, _, let family, _, _):
            family.hasEquivalentDirectTimelineProjection
        case .runStarted, .reviewCompleted, .reviewFailed, .reviewCancelled:
            false
        }
    }

    var isCommandProgressBoundary: Bool {
        switch self {
        case .itemStarted(let seed),
             .itemUpdated(let seed),
             .itemCompleted(let seed):
            return seed.family.isCommandProgressBoundary
        case .textDelta(_, _, let family, _, _):
            return family.isCommandProgressBoundary
        case .runStarted, .reviewCompleted, .reviewFailed, .reviewCancelled:
            return false
        }
    }
}

private extension ReviewItemFamily {
    var hasEquivalentDirectTimelineProjection: Bool {
        switch self {
        case .approval,
             .command,
             .diagnostic,
             .fileChange,
             .message,
             .plan,
             .reasoning,
             .search,
             .tool:
            true
        case .contextCompaction,
             .lifecycle,
             .unknown:
            false
        }
    }
}

private extension ReviewItemFamily {
    var isCommandProgressBoundary: Bool {
        switch self {
        case .approval,
             .contextCompaction,
             .fileChange,
             .message,
             .plan,
             .reasoning,
             .search,
             .tool,
             .unknown:
            true
        case .command,
             .diagnostic,
             .lifecycle:
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

private extension AppServerAPI.Account.Snapshot {
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

private typealias TurnNotificationPayload = AppServerReviewNotification.Payload
private typealias AppServerCommandAction = AppServerReviewNotification.Payload.Item.CommandAction
private typealias AppServerThreadItem = AppServerReviewNotification.Payload.Item

private let appServerContextCompactionStartedText = "Automatically compacting context"
private let appServerContextCompactionCompletedText = "Context automatically compacted"
private let appServerContextCompactionFailedText = "Context compaction failed"
private let appServerContextCompactionCancelledText = "Context compaction cancelled"

private func decodeReviewNotification(
    _ notification: AppServerRoutedReviewNotification,
    fallbackReviewThreadID: String,
    commandLifecycleByItemID: inout [String: AppServerCommandLifecycle]
) throws -> DecodedReviewNotification? {
    let payload = notification.payload
    let events: [CodexReviewBackendModel.Review.Event]
    switch notification.method {
    case "turn/started":
        events = [.started(
            turnID: payload.resolvedTurnID ?? "",
            reviewThreadID: payload.reviewThreadID ?? fallbackReviewThreadID,
            model: payload.model
        )]
    case "item/started":
        if let item = payload.item,
           item.rawType == "commandExecution" {
            let lifecycle = AppServerCommandLifecycle(
                item: item,
                startedAt: payload.startedAt,
                completedAt: nil
            )
            commandLifecycleByItemID[item.id] = lifecycle
            events = item.startedEvents(startedAt: payload.startedAt, lifecycle: lifecycle)
        } else {
            events = payload.item?.startedEvents(startedAt: payload.startedAt, lifecycle: nil) ?? []
        }
    case "item/updated":
        events = payload.item?.updatedEvents() ?? []
    case "item/completed":
        if let item = payload.item,
           item.rawType == "commandExecution" {
            let previous = commandLifecycleByItemID[item.id]
            let lifecycle = AppServerCommandLifecycle(
                item: item,
                startedAt: previous?.startedAt,
                completedAt: payload.completedAt,
                fallback: previous
            )
            events = item.completedEvents(completedAt: payload.completedAt, lifecycle: lifecycle)
            commandLifecycleByItemID.removeValue(forKey: item.id)
        } else {
            events = payload.item?.completedEvents(completedAt: payload.completedAt, lifecycle: nil) ?? []
        }
    case "item/agentMessage/delta":
        guard let delta = payload.delta,
              delta.isEmpty == false
        else {
            return nil
        }
        events = [.messageDelta(delta, itemID: payload.itemID ?? "agent-message")]
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
        let commandOutputItemID = commandLifecycleByItemID.appendCommandOutput(
            payload.commandOutputText,
            outputID: payload.commandOutputID
        )
        events = payload.commandOutputLog(
            kind: .commandOutput,
            groupID: commandOutputItemID,
            metadata: .init(
                sourceType: "commandExecution",
                title: "Command output",
                itemID: commandOutputItemID ?? payload.commandOutputID
            )
        ).map { [$0] } ?? []
    case "item/fileChange/outputDelta":
        events = payload.deltaLog(
            kind: .commandOutput,
            metadata: .init(sourceType: "fileChange", title: "File change output")
        ).map { [$0] } ?? []
    case "command/exec/outputDelta",
        "process/outputDelta":
        let commandOutputItemID = commandLifecycleByItemID.appendCommandOutput(
            payload.commandOutputText,
            outputID: payload.commandOutputID
        )
        events = payload.commandOutputLog(
            kind: .commandOutput,
            groupID: commandOutputItemID,
            metadata: .init(
                sourceType: "commandExecution",
                title: "Command output",
                itemID: commandOutputItemID ?? payload.commandOutputID
            )
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
        events = payload.itemID.map {
            [.logEntry(kind: .diagnostic, text: "Approval review started.", groupID: $0, replacesGroup: false)]
        } ?? [.logEntry(kind: .diagnostic, text: "Approval review started.", groupID: nil, replacesGroup: false)]
    case "item/autoApprovalReview/completed":
        events = payload.itemID.map {
            [.logEntry(kind: .diagnostic, text: "Approval review completed.", groupID: $0, replacesGroup: false)]
        } ?? [.logEntry(kind: .diagnostic, text: "Approval review completed.", groupID: nil, replacesGroup: false)]
    case "agent/message":
        events = [.message(payload.message ?? "")]
    case "log":
        events = [.log(payload.message ?? "")]
    case "turn/diff/updated":
        guard let diff = payload.diff?.nilIfEmpty else {
            return nil
        }
        events = [.logEntry(kind: .event, text: diff, groupID: payload.turnID, replacesGroup: true)]
    case "turn/plan/updated":
        guard let planText = payload.renderedPlan?.nilIfEmpty else {
            return nil
        }
        events = [.logEntry(kind: .todoList, text: planText, groupID: payload.turnID, replacesGroup: true)]
    case "turn/completed":
        switch payload.turn?.status {
        case "failed":
            events = [.failed(payload.turn?.error?.message ?? "Failed.")]
        case "interrupted":
            events = [.cancelled(payload.turn?.error?.message ?? "Cancellation requested.")]
        default:
            events = [.completed(
                summary: payload.message ?? "Succeeded.",
                result: payload.result?.nonNullText
            )]
        }
    case "error":
        let message = payload.error?.message ?? payload.message ?? "Failed."
        events = [
            payload.willRetry == true
                ? .logEntry(kind: .progress, text: message, groupID: payload.turnID, replacesGroup: false)
                : .failed(message)
        ]
    case "turn/failed":
        events = [.failed(payload.message ?? "Failed.")]
    case "turn/cancelled":
        events = [.cancelled(payload.message ?? "Cancellation requested.")]
    case "turn/aborted":
        events = [.cancelled(payload.message ?? "Cancellation requested.")]
    case "thread/closed":
        events = [.failed("Review thread closed.")]
    case "thread/status/changed":
        switch payload.status?.type {
        case "notLoaded":
            events = [.failed("Review thread is no longer loaded.")]
        case "systemError":
            events = [.logEntry(
                kind: .diagnostic,
                text: "Review thread entered a system error state.",
                groupID: payload.turnID,
                replacesGroup: false
            )]
        default:
            return nil
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
    case "warning", "guardianWarning", "deprecationNotice", "configWarning", "diagnostic":
        guard let message = payload.diagnosticText?.nilIfEmpty else {
            return nil
        }
        events = [.logEntry(kind: .diagnostic, text: message, groupID: payload.turnID, replacesGroup: false)]
    default:
        return nil
    }
    let directEvents = directTimelineDomainEvents(
        for: notification,
        fallbackReviewThreadID: fallbackReviewThreadID
    )
    let orderedEvents: [CodexReviewBackendModel.Review.Event] = if directEvents.isEmpty {
        events
    } else {
        [.domainEvents(
            directEvents,
            legacyProjectionSuppressionCount: events.legacyTimelineProjectionCount
        )] + events.addingTerminalFailureLogProjectionSuppressionIfNeeded
    }
    return .init(
        events: orderedEvents,
        turnID: payload.resolvedTurnID,
        startsReviewMode: notification.reviewNotification.startsReviewMode,
        finishesReviewMode: notification.reviewNotification.finishesReviewMode,
        hasDirectTimelineEvents: directEvents.isEmpty == false
    )
}

private func directTimelineDomainEvents(
    for notification: AppServerRoutedReviewNotification,
    fallbackReviewThreadID: String
) -> [ReviewDomainEvent] {
    let reviewNotification = notification.reviewNotification
    return reviewNotification
        .domainEvents(fallbackReviewThreadID: .init(rawValue: fallbackReviewThreadID))
        .filter { reviewNotification.allowsDirectTimelineEvent($0) }
}

private extension AppServerReviewNotification {
    func domainEvents(fallbackReviewThreadID: ReviewThread.ID? = nil) -> [ReviewDomainEvent] {
        switch method {
        case .turnStarted:
            return [.runStarted(
                turnID: ReviewTurn.ID(rawValue: payload.resolvedTurnID ?? ""),
                reviewThreadID: (payload.reviewThreadID ?? payload.threadID).map(ReviewThread.ID.init(rawValue:))
                    ?? fallbackReviewThreadID,
                model: payload.model
            )]
        case .turnCompleted:
            return payload.turnCompletedEvents()
        case .turnFailed:
            return [.reviewFailed(payload.terminalMessage ?? "")]
        case .turnCancelled, .turnAborted:
            return [.reviewCancelled(payload.terminalMessage ?? "")]
        case .itemStarted:
            return payload.itemStartedEvents(method: method)
        case .itemUpdated:
            return payload.itemUpdateEvents(method: method)
        case .itemCompleted:
            return payload.itemCompletionEvents(method: method)
        case .agentMessageDelta:
            return payload.deltaDomainEvent(
                kind: .agentMessage,
                family: .message,
                content: .message(.init(text: ""))
            )
        case .planDelta:
            return payload.deltaDomainEvent(
                kind: .plan,
                family: .plan,
                content: .plan(.init(markdown: ""))
            )
        case .reasoningSummaryTextDelta:
            return payload.deltaDomainEvent(
                kind: .reasoning,
                family: .reasoning,
                content: .reasoning(.init(text: "", style: .summary)),
                itemID: payload.reasoningSummaryItemID
            )
        case .reasoningTextDelta:
            return payload.deltaDomainEvent(
                kind: .reasoning,
                family: .reasoning,
                content: .reasoning(.init(text: "", style: .raw)),
                itemID: payload.rawReasoningItemID
            )
        case .reasoningSummaryPartAdded:
            return []
        case .autoApprovalReviewStarted, .autoApprovalReviewCompleted:
            return []
        case .commandExecutionOutputDelta, .commandExecOutputDelta, .processOutputDelta:
            return payload.deltaDomainEvent(
                kind: .commandExecution,
                family: .command,
                content: .command(.init(command: payload.item?.command ?? "", cwd: payload.item?.cwd)),
                delta: payload.outputDelta,
                itemID: payload.outputItemID
            )
        case .commandExecutionTerminalInteraction:
            return payload.deltaDomainEvent(
                kind: .commandExecution,
                family: .command,
                content: .command(.init(command: payload.item?.command ?? "", cwd: payload.item?.cwd)),
                delta: payload.stdin
            )
        case .fileChangeOutputDelta:
            return payload.deltaDomainEvent(
                kind: .fileChange,
                family: .fileChange,
                content: .fileChange(.init(title: payload.item?.path ?? "")),
                delta: payload.delta
            )
        case .mcpToolCallProgress:
            return payload.toolProgressEvent(method: method)
        case .fileChangePatchUpdated:
            return payload.fileChangeUpdateEvent(method: method)
        case .turnDiffUpdated:
            return payload.diffUpdateEvent(method: method)
        case .turnPlanUpdated:
            return payload.planUpdateEvent(method: method)
        case .threadCompacted:
            return payload.contextCompactionEvent(method: method)
        case .threadClosed:
            return [.reviewFailed(payload.terminalMessage ?? payload.status?.type ?? "")]
        case .threadStatusChanged:
            return payload.threadStatusEvents(method: method)
        case .error:
            return payload.errorEvents(method: method)
        case .warning, .guardianWarning, .deprecationNotice, .configWarning, .diagnostic:
            return payload.diagnosticEvents(method: method)
        case .modelRerouted:
            return payload.modelReroutedEvents(method: method)
        case .modelVerification:
            return payload.modelVerificationEvents(method: method)
        case .agentMessage:
            return payload.messageEvent(method: method)
        case .log:
            return payload.diagnosticEvents(method: method)
        default:
            return payload.unknownEvent(method: method)
        }
    }
}

private extension TurnNotificationPayload {
    var terminalMessage: String? {
        turn?.error?.message?.nilIfEmpty
            ?? error?.message?.nilIfEmpty
            ?? message?.nilIfEmpty
            ?? summary?.nilIfEmpty
    }

    var outputDelta: String? {
        if let delta, delta.isEmpty == false {
            return delta
        }
        if let decodedBase64Output, decodedBase64Output.isEmpty == false {
            return decodedBase64Output
        }
        return nil
    }

    var outputItemID: String? {
        itemID ?? processID ?? processHandle ?? item?.id.nilIfEmpty ?? item?.processID
    }

    var reasoningSummaryItemID: String? {
        itemID.map { Self.reasoningSummaryItemID(itemID: $0, summaryIndex: summaryIndex ?? 0) }
    }

    var rawReasoningItemID: String? {
        itemID.map { Self.rawReasoningItemID(itemID: $0, contentIndex: contentIndex ?? 0) }
    }

    func turnCompletedEvents() -> [ReviewDomainEvent] {
        switch terminalDisposition {
        case .failed:
            return [.reviewFailed(terminalMessage ?? "")]
        case .cancelled:
            return [.reviewCancelled(terminalMessage ?? "")]
        case .completed:
            return [.reviewCompleted(summary: message ?? summary ?? "", result: result?.nonNullText)]
        }
    }

    func itemStartedEvents(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        guard let item else {
            return []
        }
        let phase = item.phase(default: .running)
        if item.family == .reasoning {
            let reasoningSeeds = reasoningPartSeeds(for: item, phase: phase)
            if reasoningSeeds.isEmpty == false {
                return reasoningSeeds.map(ReviewDomainEvent.itemStarted)
            }
            guard item.hasReasoningParentContent(fallbackDelta: delta) else {
                return []
            }
        }
        return [.itemStarted(seed(for: item, phase: phase))]
    }

    func itemUpdateEvents(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        if let item {
            let phase = item.phase(default: .running)
            if item.family == .reasoning {
                let reasoningSeeds = reasoningPartSeeds(for: item, phase: phase)
                if reasoningSeeds.isEmpty == false {
                    return reasoningSeeds.map(ReviewDomainEvent.itemUpdated)
                }
                guard item.hasReasoningParentContent(fallbackDelta: delta)
                    || item.hasReasoningLifecycleUpdate(phase: phase)
                else {
                    return []
                }
            }
            return [.itemUpdated(seed(for: item, phase: phase))]
        }
        return unknownEvent(method: method)
    }

    func itemCompletionEvents(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        guard let item else {
            return []
        }
        let phase = item.phase(default: .completed)
        if item.family == .reasoning {
            let reasoningSeeds = reasoningPartSeeds(for: item, phase: phase)
            if reasoningSeeds.isEmpty == false {
                return reasoningSeeds.map(ReviewDomainEvent.itemCompleted)
            }
        }
        if item.wouldEraseStreamedCommandOutput(
            fallbackDelta: delta,
            phase: phase,
            hasCompletionMetadata: completedAt != nil
        ) {
            return []
        }
        return [.itemCompleted(seed(for: item, phase: phase))]
    }

    func deltaDomainEvent(
        kind: ReviewItemKind,
        family: ReviewItemFamily,
        content: ReviewTimelineItem.Content,
        delta explicitDelta: String? = nil,
        itemID explicitItemID: String? = nil
    ) -> [ReviewDomainEvent] {
        guard let delta = explicitDelta ?? delta,
              delta.isEmpty == false
        else {
            return []
        }
        return [.textDelta(
            itemID: .init(rawValue: explicitItemID ?? itemID ?? syntheticItemID(method: kind.rawValue)),
            kind: kind,
            family: family,
            content: content,
            delta: delta
        )]
    }

    func toolProgressEvent(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        guard let message = message?.nilIfEmpty else {
            return unknownEvent(method: method)
        }
        return [.itemUpdated(ReviewTimelineItemSeed(
            id: .init(rawValue: itemID.map { "\($0):progress" } ?? syntheticItemID(method: method.rawValue)),
            kind: .mcpToolCall,
            family: .tool,
            phase: .running,
            content: .toolCall(.init(
                server: item?.server,
                tool: item?.tool,
                progress: message
            ))
        ))]
    }

    func fileChangeUpdateEvent(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        let changesOutput = changes.map(\.summaryText).joined(separator: "\n").nilIfEmpty
        let changePath = changes.compactMap { $0.path?.nilIfEmpty }.first
        let updateItemID = item?.path?.nilIfEmpty == nil
            ? itemID.map { "\($0):patch" }
            : item?.id.nilIfEmpty ?? itemID
        return [.itemUpdated(ReviewTimelineItemSeed(
            id: .init(rawValue: updateItemID ?? syntheticItemID(method: method.rawValue)),
            kind: ReviewItemKind(rawValue: method.rawValue),
            family: .fileChange,
            phase: item?.phase(default: .running) ?? .running,
            content: .fileChange(.init(title: item?.path ?? changePath ?? "", output: message ?? delta ?? diff ?? changesOutput ?? ""))
        ))]
    }

    func diffUpdateEvent(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        guard let diff = diff?.nilIfEmpty else {
            return unknownEvent(method: method)
        }
        return [.itemUpdated(ReviewTimelineItemSeed(
            id: .init(rawValue: itemID ?? syntheticItemID(method: method.rawValue)),
            kind: ReviewItemKind(rawValue: method.rawValue),
            family: .fileChange,
            phase: .running,
            content: .fileChange(.init(title: "", output: diff))
        ))]
    }

    func planUpdateEvent(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        let markdown = plan.compactMap { step -> String? in
            switch (step.status.nilIfEmpty, step.step.nilIfEmpty) {
            case let (status?, step?):
                return "[\(status)] \(step)"
            case let (status?, nil):
                return "[\(status)]"
            case let (nil, step?):
                return step
            case (nil, nil):
                return nil
            }
        }.joined(separator: "\n")
        guard markdown.isEmpty == false else {
            return unknownEvent(method: method)
        }
        return [.itemUpdated(ReviewTimelineItemSeed(
            id: .init(rawValue: itemID ?? syntheticItemID(method: method.rawValue)),
            kind: .plan,
            family: .plan,
            phase: .running,
            content: .plan(.init(markdown: markdown))
        ))]
    }

    func contextCompactionEvent(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        [.itemCompleted(ReviewTimelineItemSeed(
            id: .init(rawValue: itemID ?? resolvedTurnID.map { "contextCompaction:\($0)" } ?? syntheticItemID(method: method.rawValue)),
            kind: .contextCompaction,
            family: .contextCompaction,
            phase: .completed,
            content: .contextCompaction(.init(title: status?.type ?? ""))
        ))]
    }

    func threadStatusEvents(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        switch normalizedStatus(status?.type) {
        case "notloaded", "closed":
            return [.reviewFailed(terminalMessage ?? status?.type ?? "")]
        case "cancelled", "canceled", "interrupted", "aborted":
            return [.reviewCancelled(terminalMessage ?? status?.type ?? "")]
        case "systemerror":
            return [.itemUpdated(diagnosticSeed(
                method: method,
                message: terminalMessage ?? status?.type ?? "",
                phase: .running
            ))]
        default:
            return unknownEvent(method: method)
        }
    }

    func errorEvents(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        guard let message = diagnosticMessage else {
            return [.reviewFailed("")]
        }
        let diagnostic = diagnosticSeed(method: method, message: message, phase: willRetry == true ? .running : .failed)
        if willRetry == true {
            return [.itemUpdated(diagnostic)]
        }
        return [.itemUpdated(diagnostic), .reviewFailed(message)]
    }

    func diagnosticEvents(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        guard let message = diagnosticMessage else {
            return unknownEvent(method: method)
        }
        return [.itemUpdated(diagnosticSeed(method: method, message: message, phase: .running))]
    }

    func modelReroutedEvents(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        let route = [fromModel?.nilIfEmpty, toModel?.nilIfEmpty].compactMap(\.self).joined(separator: " -> ")
        let message = [route.nilIfEmpty, reason?.nilIfEmpty].compactMap(\.self).joined(separator: "\n")
        guard message.isEmpty == false else {
            return unknownEvent(method: method)
        }
        return [.itemUpdated(diagnosticSeed(method: method, message: message, phase: .running))]
    }

    func modelVerificationEvents(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        let message = diagnosticMessage ?? verifications.joined(separator: "\n").nilIfEmpty
        guard let message else {
            return unknownEvent(method: method)
        }
        return [.itemUpdated(diagnosticSeed(method: method, message: message, phase: .running))]
    }

    func messageEvent(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        guard let message = message?.nilIfEmpty else {
            return unknownEvent(method: method)
        }
        return [.itemUpdated(ReviewTimelineItemSeed(
            id: .init(rawValue: itemID ?? syntheticItemID(method: method.rawValue)),
            kind: .agentMessage,
            family: .message,
            phase: .completed,
            content: .message(.init(text: message))
        ))]
    }

    func unknownEvent(method: AppServerReviewNotification.Method) -> [ReviewDomainEvent] {
        [.itemUpdated(ReviewTimelineItemSeed(
            id: .init(rawValue: itemID ?? syntheticItemID(method: method.rawValue)),
            kind: ReviewItemKind(rawValue: method.rawValue),
            family: .unknown,
            phase: .running,
            content: .unknown(.init(title: method.rawValue, detail: rawValue?.jsonString))
        ))]
    }

    func seed(
        for item: AppServerThreadItem,
        phase: ReviewItemPhase,
        content explicitContent: ReviewTimelineItem.Content? = nil
    ) -> ReviewTimelineItemSeed {
        ReviewTimelineItemSeed(
            id: .init(rawValue: item.id.nilIfEmpty ?? itemID ?? syntheticItemID(method: item.rawType)),
            kind: item.reviewItemKind,
            family: item.family,
            phase: phase,
            content: explicitContent ?? item.content(fallbackDelta: delta),
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: item.durationMs
        )
    }

    private func reasoningPartSeeds(for item: AppServerThreadItem, phase: ReviewItemPhase) -> [ReviewTimelineItemSeed] {
        guard item.family == .reasoning else {
            return []
        }
        let parentItemID = item.id.nilIfEmpty ?? itemID ?? syntheticItemID(method: item.rawType)
        let summarySeeds = item.indexedSummaryTexts.map { index, text in
            reasoningSeed(
                id: Self.reasoningSummaryItemID(itemID: parentItemID, summaryIndex: index),
                text: text,
                style: .summary,
                item: item,
                phase: phase
            )
        }
        let rawSeeds = item.indexedContentTexts.map { index, text in
            reasoningSeed(
                id: Self.rawReasoningItemID(itemID: parentItemID, contentIndex: index),
                text: text,
                style: .raw,
                item: item,
                phase: phase
            )
        }
        return summarySeeds + rawSeeds
    }

    private func reasoningSeed(
        id: String,
        text: String,
        style: ReviewTimelineItem.Reasoning.Style,
        item: AppServerThreadItem,
        phase: ReviewItemPhase
    ) -> ReviewTimelineItemSeed {
        ReviewTimelineItemSeed(
            id: .init(rawValue: id),
            kind: item.reviewItemKind,
            family: .reasoning,
            phase: phase,
            content: .reasoning(.init(text: text, style: style)),
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: item.durationMs
        )
    }

    private var terminalDisposition: AppServerTerminalDisposition {
        switch normalizedStatus(turn?.status ?? status?.type) {
        case "failed", "failure", "error", "errored":
            return .failed
        case "cancelled", "canceled", "interrupted", "aborted":
            return .cancelled
        default:
            return .completed
        }
    }

    private func diagnosticSeed(
        method: AppServerReviewNotification.Method,
        message: String,
        phase: ReviewItemPhase
    ) -> ReviewTimelineItemSeed {
        ReviewTimelineItemSeed(
            id: .init(rawValue: itemID ?? syntheticItemID(method: method.rawValue)),
            kind: ReviewItemKind(rawValue: method.rawValue),
            family: .diagnostic,
            phase: phase,
            content: .diagnostic(.init(message: message))
        )
    }

    private func syntheticItemID(method: String) -> String {
        [resolvedTurnID, method].compactMap(\.self).joined(separator: ":").nilIfEmpty ?? method
    }

    private static func reasoningSummaryItemID(itemID: String, summaryIndex: Int) -> String {
        "\(itemID):summary:\(summaryIndex)"
    }

    private static func rawReasoningItemID(itemID: String, contentIndex: Int) -> String {
        "\(itemID):content:\(contentIndex)"
    }
}

private extension AppServerReviewNotification {
    func allowsDirectTimelineEvent(_ event: ReviewDomainEvent) -> Bool {
        guard event.isDirectTimelineEvent else {
            return false
        }
        switch event {
        case .itemStarted(let seed),
             .itemUpdated(let seed),
             .itemCompleted(let seed):
            return allowsDirectTimelineSeed(seed)
        case .textDelta(let itemID, _, let family, _, _):
            if isStandaloneProcessOutputDelta {
                return false
            }
            return family.hasEquivalentDirectTimelineProjection
                && allowsDirectTimelineTextDelta(itemID: itemID, family: family)
        case .runStarted,
             .reviewCompleted,
             .reviewFailed,
             .reviewCancelled:
            return false
        }
    }

    private func allowsDirectTimelineSeed(_ seed: ReviewTimelineItemSeed) -> Bool {
        if payload.item?.rawType == "userMessage" || seed.kind.rawValue == "userMessage" {
            return false
        }
        if seed.family == .message,
           method.rawValue == "agent/message",
           payload.itemID?.nilIfEmpty == nil {
            return false
        }
        if seed.family == .message,
           isItemLifecycleMethod,
           payload.item?.rawType == "agentMessage",
           payload.item?.id.nilIfEmpty == nil,
           payload.itemID?.nilIfEmpty == nil {
            return false
        }
        if seed.family == .diagnostic,
           shouldKeepSyntheticDiagnosticOnLegacyPath {
            return false
        }
        if seed.family == .search,
           seed.hasSearchResultText,
           payload.item?.result == nil {
            return false
        }
        return seed.family.hasEquivalentDirectTimelineProjection
    }

    private func allowsDirectTimelineTextDelta(
        itemID: ReviewTimelineItem.ID,
        family: ReviewItemFamily
    ) -> Bool {
        if family == .message,
           method.rawValue == "agent/message",
           payload.itemID?.nilIfEmpty == nil {
            return false
        }
        return itemID.rawValue.isEmpty == false
    }

    private var isItemLifecycleMethod: Bool {
        switch method.rawValue {
        case "item/started", "item/updated", "item/completed":
            true
        default:
            false
        }
    }

    private var isStandaloneProcessOutputDelta: Bool {
        switch method.rawValue {
        case "command/exec/outputDelta", "process/outputDelta":
            true
        default:
            false
        }
    }

    private var shouldKeepSyntheticDiagnosticOnLegacyPath: Bool {
        guard payload.itemID?.nilIfEmpty == nil else {
            return false
        }
        switch method.rawValue {
        case "log",
             "warning",
             "guardianWarning",
             "deprecationNotice",
             "configWarning",
             "diagnostic",
             "model/rerouted",
             "model/verification",
             "thread/status/changed":
            return true
        default:
            return false
        }
    }
}

private extension ReviewTimelineItemSeed {
    var hasSearchResultText: Bool {
        guard case .search(let search) = content else {
            return false
        }
        return search.result?.nilIfEmpty != nil
    }
}

private func reasoningSummaryGroupID(itemID: String, summaryIndex: Int) -> String {
    "\(itemID):summary:\(summaryIndex)"
}

private func rawReasoningGroupID(itemID: String, contentIndex: Int) -> String {
    "\(itemID):\(contentIndex)"
}

private extension TurnNotificationPayload {
    var startedAt: Date? {
        startedAtMs.map(Self.date(millisecondsSince1970:))
    }

    var completedAt: Date? {
        completedAtMs.map(Self.date(millisecondsSince1970:))
    }

    var commandOutputID: String? {
        itemID?.nilIfEmpty ?? processID?.nilIfEmpty ?? processHandle?.nilIfEmpty
    }

    var commandOutputText: String? {
        if let delta, delta.isEmpty == false {
            return delta
        }
        if let decodedBase64Output, decodedBase64Output.isEmpty == false {
            return decodedBase64Output
        }
        return nil
    }

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

    func commandOutputLog(
        kind: ReviewLogEntry.Kind,
        groupID explicitGroupID: String? = nil,
        metadata: ReviewLogEntry.Metadata? = nil
    ) -> CodexReviewBackendModel.Review.Event? {
        guard let text = commandOutputText
        else {
            return nil
        }
        return .logEntry(
            kind: kind,
            text: text,
            groupID: explicitGroupID ?? commandOutputID,
            replacesGroup: false,
            metadata: metadata
        )
    }

    var decodedBase64Output: String? {
        guard let deltaBase64,
              let data = Data(base64Encoded: deltaBase64)
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
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
        guard let itemID else {
            return nil
        }
        return reasoningSummaryGroupID(
            itemID: itemID,
            summaryIndex: summaryIndex ?? 0
        )
    }

    var rawReasoningGroupKey: String? {
        guard let itemID else {
            return nil
        }
        return rawReasoningGroupID(
            itemID: itemID,
            contentIndex: contentIndex ?? 0
        )
    }

    var renderedPlan: String? {
        let steps = plan.map { step in
            "[\(step.status)] \(step.step)"
        }
        return steps.joined(separator: "\n").nilIfEmpty
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

    var diagnosticMessage: String? {
        if let message = message?.nilIfEmpty {
            return message
        }
        if let error = error?.message?.nilIfEmpty {
            return error
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

    private static func date(millisecondsSince1970 milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

private extension AppServerCommandAction {
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
        switch kind {
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

    var timelineAction: ReviewTimelineItem.CommandAction {
        .init(
            kind: .init(rawValue: kind),
            command: command,
            name: name,
            path: path,
            query: query
        )
    }
}

private struct AppServerCommandLifecycle: Sendable {
    var itemID: String
    var command: String?
    var cwd: String?
    var processID: String?
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
        self.command = item.command ?? fallback?.command
        self.cwd = item.cwd ?? fallback?.cwd
        self.processID = item.processID?.nilIfEmpty ?? fallback?.processID
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
    mutating func appendCommandOutput(_ output: String?, outputID: String?) -> String? {
        guard let outputID = outputID?.nilIfEmpty else {
            return nil
        }
        guard let output, output.isEmpty == false else {
            return commandLifecycleItemID(forOutputID: outputID) ?? outputID
        }
        if let lifecycleItemID = commandLifecycleItemID(forOutputID: outputID) {
            self[lifecycleItemID]?.appendOutput(output)
            return lifecycleItemID
        }
        return outputID
    }

    private func commandLifecycleItemID(forOutputID outputID: String) -> String? {
        if self[outputID] != nil {
            return outputID
        }
        return first { _, lifecycle in
            lifecycle.processID == outputID
        }?.key
    }

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

private extension AppServerThreadItem {
    var reviewItemKind: ReviewItemKind {
        .init(rawValue: rawType)
    }

    var family: ReviewItemFamily {
        switch rawType {
        case ReviewItemKind.agentMessage.rawValue,
            "userMessage",
            "exitedReviewMode":
            return .message
        case ReviewItemKind.commandExecution.rawValue:
            return .command
        case ReviewItemKind.fileChange.rawValue:
            return .fileChange
        case ReviewItemKind.plan.rawValue:
            return .plan
        case ReviewItemKind.reasoning.rawValue:
            return .reasoning
        case ReviewItemKind.contextCompaction.rawValue:
            return .contextCompaction
        case ReviewItemKind.webSearch.rawValue:
            return .search
        case ReviewItemKind.mcpToolCall.rawValue,
            ReviewItemKind.dynamicToolCall.rawValue,
            "collabAgentToolCall",
            ReviewItemKind.imageGeneration.rawValue,
            ReviewItemKind.imageView.rawValue:
            return .tool
        case "hookPrompt", "autoApprovalReview":
            return .approval
        case "enteredReviewMode":
            return .lifecycle
        case "diagnostic", "warning":
            return .diagnostic
        default:
            return .unknown
        }
    }

    func phase(default defaultPhase: ReviewItemPhase) -> ReviewItemPhase {
        if let status = normalizedStatus(status) {
            switch status {
            case "approved", "completed", "succeeded", "success":
                return .completed
            case "cancelled", "canceled", "interrupted", "aborted":
                return .cancelled
            case "failed", "failure", "error", "errored":
                return .failed
            case "incomplete":
                return .incomplete
            case "skipped":
                return .skipped
            case "approval", "awaitingapproval", "pendingapproval":
                return .awaitingApproval
            case "queued", "pending":
                return .queued
            case "waiting", "waitingforinput", "inputrequired":
                return .waitingForInput
            case "inprogress", "running", "started":
                return .running
            default:
                break
            }
        }
        if error?.nonNullText?.nilIfEmpty != nil || success == false {
            return .failed
        }
        if success == true {
            return .completed
        }
        if let exitCode {
            return exitCode == 0 ? .completed : .failed
        }
        return defaultPhase
    }

    func content(fallbackDelta rawFallbackDelta: String?) -> ReviewTimelineItem.Content {
        let fallbackDelta = rawFallbackDelta?.nilIfEmpty
        switch family {
        case .message:
            return .message(.init(text: text ?? review ?? joinedContentText ?? fallbackDelta ?? ""))
        case .command:
            return .command(.init(
                command: command ?? "",
                cwd: cwd,
                output: aggregatedOutput ?? fallbackDelta ?? "",
                exitCode: exitCode,
                status: status.map(ReviewCommandStatus.init(rawValue:)),
                source: source.map(ReviewCommandSource.init(rawValue:)),
                processID: processID,
                actions: commandActions.map(\.timelineAction),
                durationMs: durationMs
            ))
        case .fileChange:
            return .fileChange(.init(title: path ?? "", output: aggregatedOutput ?? text ?? fallbackDelta ?? ""))
        case .plan:
            return .plan(.init(markdown: text ?? fallbackDelta ?? ""))
        case .reasoning:
            let summaryText = summary.joined(separator: "\n").nilIfEmpty
            let contentText = content.joined(separator: "\n").nilIfEmpty
            let style: ReviewTimelineItem.Reasoning.Style = summaryText == nil ? .raw : .summary
            return .reasoning(.init(text: text ?? summaryText ?? contentText ?? fallbackDelta ?? "", style: style))
        case .contextCompaction:
            return .contextCompaction(.init(title: status ?? text ?? ""))
        case .search:
            return .search(.init(query: query ?? text ?? "", result: result?.nonNullText))
        case .tool:
            return .toolCall(.init(
                namespace: namespace,
                server: server,
                tool: tool,
                arguments: arguments?.nonNullText ?? input?.nonNullText,
                result: result?.nonNullText,
                error: error?.nonNullText
            ))
        case .approval:
            return .approval(.init(title: prompt ?? text ?? joinedFragmentText ?? "", detail: review))
        case .diagnostic:
            return .diagnostic(.init(message: text ?? error?.nonNullText ?? fallbackDelta ?? ""))
        case .lifecycle, .unknown:
            return .unknown(.init(title: rawType, detail: rawValue?.jsonString))
        }
    }

    func wouldEraseStreamedCommandOutput(
        fallbackDelta: String?,
        phase: ReviewItemPhase,
        hasCompletionMetadata: Bool
    ) -> Bool {
        family == .command
            && aggregatedOutput == nil
            && hasAggregatedOutputField == false
            && fallbackDelta?.nilIfEmpty == nil
            && phase == .completed
            && hasCompletionMetadata == false
            && hasCommandCompletionSnapshot == false
    }

    func hasReasoningParentContent(fallbackDelta: String?) -> Bool {
        family == .reasoning
            && (text?.nilIfEmpty != nil || fallbackDelta?.nilIfEmpty != nil)
    }

    func hasReasoningLifecycleUpdate(phase: ReviewItemPhase) -> Bool {
        family == .reasoning
            && phase.isTerminal
            && (
                status?.nilIfEmpty != nil
                    || success != nil
                    || error?.nonNullText?.nilIfEmpty != nil
            )
    }

    var hasCommandCompletionSnapshot: Bool {
        exitCode != nil
            || durationMs != nil
            || status?.nilIfEmpty != nil
            || success != nil
            || command?.nilIfEmpty != nil
            || cwd?.nilIfEmpty != nil
            || processID?.nilIfEmpty != nil
            || source?.nilIfEmpty != nil
    }

    private var joinedContentText: String? {
        indexedContentTexts
            .map { $0.1 }
            .joined(separator: "\n")
            .nilIfEmpty
    }

    var indexedSummaryTexts: [(Int, String)] {
        let strings = summary.enumerated().compactMap { index, text in
            text.nilIfEmpty.map { (index, $0) }
        }
        if strings.isEmpty == false {
            return strings
        }
        return summaryFragments.enumerated().compactMap { index, fragment in
            fragment.text?.nilIfEmpty.map { (index, $0) }
        }
    }

    var indexedContentTexts: [(Int, String)] {
        let strings = content.enumerated().compactMap { index, text in
            text.nilIfEmpty.map { (index, $0) }
        }
        if strings.isEmpty == false {
            return strings
        }
        return contentFragments.enumerated().compactMap { index, fragment in
            fragment.text?.nilIfEmpty.map { (index, $0) }
        }
    }

    private var joinedFragmentText: String? {
        fragments.compactMap { $0.text?.nilIfEmpty }
            .joined(separator: "\n")
            .nilIfEmpty
    }

    func startedEvents(
        startedAt: Date?,
        lifecycle: AppServerCommandLifecycle?
    ) -> [CodexReviewBackendModel.Review.Event] {
        switch rawType {
        case "userMessage":
            return []
        case "enteredReviewMode":
            return review.map { [.logEntry(kind: .progress, text: "Reviewing \($0)", groupID: id, replacesGroup: true)] } ?? []
        case "commandExecution":
            return (command ?? lifecycle?.command).map {
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
        case "webSearch":
            return [logEntry(kind: .toolCall, text: "Web search: \(query ?? "started")", replacesGroup: true, title: "Web search", status: "started")]
        case "imageView":
            return [logEntry(kind: .toolCall, text: "View image: \(path ?? "image")", replacesGroup: true, title: "Image view", status: "started")]
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
            return []
        default:
            return [.logEntry(kind: .event, text: "App-server item started: \(rawType).", groupID: id, replacesGroup: true)]
        }
    }

    func updatedEvents() -> [CodexReviewBackendModel.Review.Event] {
        switch rawType {
        case "agentMessage":
            return text.map {
                [logEntry(
                    kind: .agentMessage,
                    text: $0,
                    replacesGroup: true,
                    title: nil,
                    status: "inProgress"
                )]
            } ?? []
        case "commandExecution":
            guard let output = aggregatedOutput?.nilIfEmpty else {
                return []
            }
            return [logEntry(
                kind: .commandOutput,
                text: output,
                replacesGroup: true,
                title: nil,
                status: status
            )]
        case "fileChange":
            guard let output = aggregatedOutput?.nilIfEmpty ?? text?.nilIfEmpty else {
                return []
            }
            return [logEntry(
                kind: .commandOutput,
                text: output,
                replacesGroup: true,
                title: "File changes",
                status: status
            )]
        case "plan":
            return text.map { [.logEntry(kind: .plan, text: $0, groupID: id, replacesGroup: true)] } ?? []
        case "reasoning":
            return reasoningCompletionEvents(replacesGroup: true)
        case "mcpToolCall",
             "dynamicToolCall",
             "collabAgentToolCall",
             "imageGeneration",
             "imageView":
            guard let text = error?.nonNullDebugText?.nilIfEmpty ?? result?.nonNullDebugText?.nilIfEmpty else {
                return []
            }
            return [logEntry(
                kind: .toolCall,
                text: text,
                replacesGroup: true,
                title: toolLabel,
                status: status
            )]
        case "webSearch":
            guard let result = result?.nonNullDebugText?.nilIfEmpty else {
                return []
            }
            return [logEntry(
                kind: .toolCall,
                text: result,
                replacesGroup: true,
                title: "Web search",
                status: status
            )]
        default:
            return []
        }
    }

    func completedEvents(
        completedAt: Date?,
        lifecycle: AppServerCommandLifecycle?
    ) -> [CodexReviewBackendModel.Review.Event] {
        switch rawType {
        case "userMessage":
            return []
        case "agentMessage":
            return text.map { [.logEntry(kind: .agentMessage, text: $0, groupID: id, replacesGroup: true)] } ?? []
        case "exitedReviewMode":
            return review.map { [.logEntry(kind: .agentMessage, text: $0, groupID: id, replacesGroup: true)] } ?? []
        case "commandExecution":
            if let output = aggregatedOutput?.nilIfEmpty ?? lifecycle?.streamedOutputIfAvailable {
                var events: [CodexReviewBackendModel.Review.Event] = []
                if let command = command ?? lifecycle?.command {
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
            if let command = command ?? lifecycle?.command {
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
            if let text = toolResultOrErrorText {
                return [logEntry(kind: .toolCall, text: text, replacesGroup: true, title: toolLabel, status: completedStatus)]
            }
            return [logEntry(kind: .toolCall, text: "\(toolLabel) \(status ?? "completed").\(resultSuffix)", replacesGroup: true, title: toolLabel, status: completedStatus)]
        case "dynamicToolCall":
            if let text = toolResultOrErrorText {
                return [logEntry(kind: .toolCall, text: text, replacesGroup: true, title: toolLabel, status: completedStatus)]
            }
            return [logEntry(kind: .toolCall, text: "Dynamic tool \(toolLabel) \(status ?? "completed").\(resultSuffix)", replacesGroup: true, title: toolLabel, status: completedStatus)]
        case "collabAgentToolCall":
            if let text = toolResultOrErrorText {
                return [logEntry(kind: .toolCall, text: text, replacesGroup: true, title: toolLabel, status: completedStatus, detail: prompt)]
            }
            return [logEntry(kind: .toolCall, text: "Collab tool \(toolLabel) \(status ?? "completed").\(promptSuffix)", replacesGroup: true, title: toolLabel, status: completedStatus, detail: prompt)]
        case "webSearch":
            if let result = result?.nonNullDebugText?.nilIfEmpty {
                return [logEntry(kind: .toolCall, text: result, replacesGroup: true, title: "Web search", status: completedStatus)]
            }
            return [logEntry(kind: .toolCall, text: "Web search completed: \(query ?? "search").", replacesGroup: true, title: "Web search", status: completedStatus)]
        case "imageView":
            if let text = toolResultOrErrorText {
                return [logEntry(kind: .toolCall, text: text, replacesGroup: true, title: "Image view", status: completedStatus)]
            }
            return [logEntry(kind: .toolCall, text: "Image viewed: \(path ?? "image").", replacesGroup: true, title: "Image view", status: completedStatus)]
        case "imageGeneration":
            if let text = toolResultOrErrorText {
                return [logEntry(kind: .toolCall, text: text, replacesGroup: true, title: "Image generation", status: completedStatus)]
            }
            return [logEntry(kind: .toolCall, text: "Image generation \(status ?? "completed").\(resultSuffix)", replacesGroup: true, title: "Image generation", status: completedStatus)]
        case "fileChange":
            if let output = aggregatedOutput?.nilIfEmpty ?? text?.nilIfEmpty {
                return [logEntry(kind: .commandOutput, text: output, replacesGroup: true, title: "File changes", status: completedStatus)]
            }
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
            return [.logEntry(kind: .event, text: "App-server item completed: \(rawType).", groupID: id, replacesGroup: true)]
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
        let isCommandExecution = rawType == "commandExecution"
        let isLifecycleItem = isCommandExecution || rawType == "contextCompaction"
        return .init(
            sourceType: rawType,
            title: title?.nilIfEmpty,
            status: resolvedStatus,
            detail: detail?.nilIfEmpty,
            itemID: isLifecycleItem ? id : nil,
            command: command ?? lifecycle?.command,
            cwd: cwd ?? lifecycle?.cwd,
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

    private var toolResultOrErrorText: String? {
        error?.nonNullDebugText?.nilIfEmpty ?? result?.nonNullDebugText?.nilIfEmpty
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
            .nilIfEmpty ?? rawType
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
        let summaryEvents = summary.enumerated().compactMap { index, text -> CodexReviewBackendModel.Review.Event? in
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
        let rawEvents = content.enumerated().compactMap { index, text -> CodexReviewBackendModel.Review.Event? in
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

private enum AppServerTerminalDisposition {
    case completed
    case failed
    case cancelled
}

private func normalizedStatus(_ value: String?) -> String? {
    value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .nilIfEmpty
}

private extension AppServerJSONValue {
    var nonNullDebugText: String? {
        nonNullText
    }

    var nonNullText: String? {
        switch self {
        case .null:
            return nil
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .array, .object:
            return jsonString
        }
    }

    var jsonString: String {
        let fallback: String
        switch self {
        case .object:
            fallback = "{}"
        case .array:
            fallback = "[]"
        case .string(let value):
            fallback = value
        case .int(let value):
            fallback = String(value)
        case .double(let value):
            fallback = String(value)
        case .bool(let value):
            fallback = String(value)
        case .null:
            fallback = "null"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? fallback
    }
}
