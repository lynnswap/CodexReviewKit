import Foundation
import CodexReview

package actor AppServerCodexReviewBackend: CodexReviewBackend {
    private static let reviewPermissionProfileID = ":danger-full-access"

    private let client: AppServerClient
    private let threadStartPermissionStrategy: AppServerThreadStartPermissionStrategy
    private var controlsByThreadID: [String: AppServerReviewControl] = [:]
    private var notificationStreamsByThreadID: [String: AsyncThrowingStream<JSONRPCNotification, Error>] = [:]
    private var reviewEventContinuationsByThreadID: [
        String: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation
    ] = [:]
    private var pendingReviewEventStreamFinishesByThreadID: [String: PendingReviewEventStreamFinish] = [:]
    private var activeCommandLifecyclesByThreadID: [String: [String: AppServerCommandLifecycle]] = [:]

    package init(
        client: AppServerClient,
        threadStartPermissionStrategy: AppServerThreadStartPermissionStrategy = .modernPermissions
    ) {
        self.client = client
        self.threadStartPermissionStrategy = threadStartPermissionStrategy
    }

    package func readSettings() async throws -> BackendSettingsSnapshot {
        _ = try await client.initialize()
        let response = try await client.send(ConfigReadRequest())
        let models = try await readModelCatalog()
        return .init(
            model: response.config.reviewModel?.nilIfEmpty,
            fallbackModel: response.config.model?.nilIfEmpty ?? models.first(where: \.isDefault)?.model,
            reasoningEffort: response.config.modelReasoningEffort,
            serviceTier: response.config.serviceTier,
            models: models
        )
    }

    package func applySettings(_ change: BackendSettingsChange) async throws -> BackendSettingsSnapshot {
        _ = try await client.initialize()
        let edits = Self.configEdits(from: change)
        if edits.isEmpty == false {
            let _: ConfigWriteResponse = try await client.send(ConfigBatchWriteRequest(
                params: .init(edits: edits)
            ))
        }
        return try await readSettings()
    }

    package func readAuth() async throws -> BackendAuthSnapshot {
        _ = try await client.initialize()
        let response = try await client.send(AuthReadRequest())
        guard let account = response.account?.backendAccount else {
            return .init()
        }
        return .init(accounts: [account], activeAccountID: account.id)
    }

    package func readRateLimits() async throws -> AppServerAccountRateLimitsResponse {
        _ = try await client.initialize()
        return try await client.send(AccountRateLimitsReadRequest())
    }

    package func startLogin(_ request: BackendLoginRequest) async throws -> BackendLoginChallenge {
        _ = try await client.initialize()
        let nativeWebAuthentication = request.nativeWebAuthenticationCallbackScheme
            .map(AppServerNativeWebAuthenticationRequest.init(callbackURLScheme:))
        let response: LoginAccountResponse = try await client.send(
            method: "account/login/start",
            params: LoginAccountParams(nativeWebAuthentication: nativeWebAuthentication),
            responseType: LoginAccountResponse.self
        )
        return try response.backendChallenge
    }

    package func cancelLogin(_ challenge: BackendLoginChallenge) async throws {
        _ = try await client.initialize()
        let _: CancelLoginAccountResponse = try await client.send(
            method: "account/login/cancel",
            params: CancelLoginAccountParams(loginID: challenge.id),
            responseType: CancelLoginAccountResponse.self
        )
    }

    package func completeLogin(_ response: BackendLoginResponse) async throws -> BackendAuthSnapshot {
        if let callbackURL = response.callbackURL {
            _ = try await client.initialize()
            let _: CompleteLoginAccountResponse = try await client.send(
                method: "account/login/complete",
                params: CompleteLoginAccountParams(loginID: response.challengeID, callbackURL: callbackURL),
                responseType: CompleteLoginAccountResponse.self
            )
        }
        return try await readAuth()
    }

    package func logout(_: BackendAccountID) async throws -> BackendAuthSnapshot {
        _ = try await client.initialize()
        let _: EmptyResponse = try await client.send(
            method: "account/logout",
            params: EmptyResponse(),
            responseType: EmptyResponse.self
        )
        return try await readAuth()
    }

    package func startReview(_ request: BackendReviewStart) async throws -> BackendReviewRun {
        _ = try await client.initialize()
        let control = AppServerReviewControl(client: client)

        let thread = try await startReviewThread(request)
        await control.recordThreadStarted(threadID: thread.threadID)
        controlsByThreadID[thread.threadID] = control
        notificationStreamsByThreadID[thread.threadID] = await client.notificationStream()

        let review: ReviewStartResponse
        do {
            review = try await client.send(ReviewStartRequest(
                params: .init(threadID: thread.threadID, target: request.request.target)
            ))
        } catch {
            await cleanupReview(.init(threadID: thread.threadID, model: thread.model))
            throw error
        }
        let reviewThreadID = review.reviewThreadID ?? thread.threadID
        await control.recordReviewStarted(threadID: thread.threadID, turnID: review.turnID)

        return .init(
            threadID: thread.threadID,
            turnID: review.turnID,
            reviewThreadID: reviewThreadID,
            model: thread.model ?? request.model
        )
    }

    private func startReviewThread(_ request: BackendReviewStart) async throws -> ThreadStartResponse {
        if threadStartPermissionStrategy == .legacySandbox {
            // Deprecated compatibility: installed Codex builds without the app-server v2
            // session-source flag can ignore permissions without failing the request.
            return try await client.send(ThreadStartRequest(
                params: threadStartParamsWithLegacySandbox(request)
            ))
        }
        do {
            return try await startReviewThreadWithProfileIDPermissions(request)
        } catch let error as JSONRPCError where Self.shouldRetryThreadStartWithLegacySandbox(error) {
            // Deprecated compatibility: some builds accept the permissions field shape
            // without registering the danger-full-access built-in profile.
            return try await client.send(ThreadStartRequest(
                params: threadStartParamsWithLegacySandbox(request)
            ))
        } catch let error as JSONRPCError where Self.shouldRetryThreadStartWithObjectPermissions(error) {
            // Deprecated compatibility: installed Codex builds can require object-shaped
            // permissions while the latest local app-server source accepts a profile ID string.
            return try await startReviewThreadWithProfileSelectionPermissions(request)
        }
    }

    private func startReviewThreadWithProfileIDPermissions(
        _ request: BackendReviewStart
    ) async throws -> ThreadStartResponse {
        try await client.send(ThreadStartRequest(
            params: threadStartParams(
                request,
                permissions: .profileID(Self.reviewPermissionProfileID)
            )
        ))
    }

    private func startReviewThreadWithProfileSelectionPermissions(
        _ request: BackendReviewStart
    ) async throws -> ThreadStartResponse {
        do {
            return try await client.send(ThreadStartRequest(
                params: threadStartParams(
                    request,
                    permissions: .profileSelection(.init(id: Self.reviewPermissionProfileID))
                )
            ))
        } catch let error as JSONRPCError
            where Self.shouldRetryThreadStartWithLegacySandbox(error)
        {
            // Deprecated compatibility: installed Codex builds can know the permissions
            // object shape without registering the danger-full-access built-in profile.
            return try await client.send(ThreadStartRequest(
                params: threadStartParamsWithLegacySandbox(request)
            ))
        }
    }

    private func threadStartParams(
        _ request: BackendReviewStart,
        permissions: ThreadStartPermissions
    ) -> ThreadStartParams {
        .init(
            cwd: request.request.cwd,
            model: request.model,
            ephemeral: true,
            approvalPolicy: "never",
            permissions: permissions,
            sessionStartSource: .startup,
            threadSource: .user
        )
    }

    private func threadStartParamsWithLegacySandbox(_ request: BackendReviewStart) -> ThreadStartParams {
        .init(
            cwd: request.request.cwd,
            model: request.model,
            ephemeral: true,
            approvalPolicy: "never",
            sandbox: "danger-full-access",
            sessionStartSource: .startup,
            threadSource: .user
        )
    }

    private nonisolated static func shouldRetryThreadStartWithObjectPermissions(_ error: JSONRPCError) -> Bool {
        guard case .responseError(_, let message) = error else {
            return false
        }
        return message.contains("PermissionProfileSelectionParams")
            || message.contains("invalid type: string")
    }

    private nonisolated static func shouldRetryThreadStartWithLegacySandbox(_ error: JSONRPCError) -> Bool {
        guard case .responseError(_, let message) = error else {
            return false
        }
        return message.contains("unknown built-in profile")
            || message.contains("default_permissions refers to unknown")
    }

    package func interruptReview(_ run: BackendReviewRun, reason: BackendCancellationReason) async throws {
        _ = try await client.initialize()
        if let control = controlsByThreadID[run.threadID] {
            if try await control.interrupt() {
                finishReviewEventStream(
                    threadID: run.threadID,
                    cancellationMessage: reason.message,
                    buffersMissingContinuation: true
                )
                return
            }
        }
        let _: EmptyResponse = try await client.send(TurnInterruptRequest(
            params: .init(threadID: run.threadID, turnID: run.turnID ?? "")
        ))
        finishReviewEventStream(
            threadID: run.threadID,
            cancellationMessage: reason.message,
            buffersMissingContinuation: true
        )
    }

    package func cleanupReview(_ run: BackendReviewRun) async {
        _ = try? await client.initialize()
        controlsByThreadID.removeValue(forKey: run.threadID)
        notificationStreamsByThreadID.removeValue(forKey: run.threadID)
        finishReviewEventStream(threadID: run.threadID, cancellationMessage: nil)
        let _: EmptyResponse? = try? await client.send(BackgroundTerminalsCleanRequest(
            params: .init(threadID: run.threadID)
        ))
        let _: ThreadUnsubscribeResponse? = try? await client.send(ThreadUnsubscribeRequest(
            params: .init(threadID: run.threadID)
        ))
    }

    package func events(for run: BackendReviewRun) async -> AsyncThrowingStream<BackendReviewEvent, Error> {
        let notifications: AsyncThrowingStream<JSONRPCNotification, Error>
        if let buffered = notificationStreamsByThreadID[run.threadID] {
            notifications = buffered
        } else {
            notifications = await client.notificationStream()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard self.registerReviewEventContinuation(continuation, threadID: run.threadID) else {
                    return
                }
                var trackedTurnIDs = Set(run.turnID.map { [$0] } ?? [])
                var emittedStartedTurnIDs: Set<String> = []
                var commandLifecycleByItemID: [String: AppServerCommandLifecycle] = [:]
                var awaitingReviewExit = false
                let completionCoordinator = ReviewCompletionCoordinator()
                let recordEvent: @Sendable (BackendReviewEvent) async -> Void = { [weak self] event in
                    guard let self else {
                        return
                    }
                    await self.recordReviewEvent(event, for: run)
                }
                do {
                    for try await notification in notifications {
                        guard let decoded = try decodeReviewNotification(
                            notification,
                            threadID: run.threadID,
                            fallbackReviewThreadID: run.reviewThreadID ?? run.threadID,
                            commandLifecycleByItemID: &commandLifecycleByItemID
                        ) else {
                            continue
                        }
                        guard decoded.events.isEmpty == false else {
                            continue
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
                            else {
                                continue
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
                                    continue
                                }
                            }
                            if decoded.events.contains(where: { $0.isTerminal == false }),
                               emittedStartedTurnIDs.contains(turnID) == false
                            {
                                let started = BackendReviewEvent.started(
                                    turnID: turnID,
                                    reviewThreadID: run.reviewThreadID ?? run.threadID,
                                    model: nil
                                )
                                _ = await completionCoordinator.emit(
                                    started,
                                    continuation: continuation,
                                    record: recordEvent
                                )
                                emittedStartedTurnIDs.insert(turnID)
                            }
                            shouldEmitNotification = true
                        } else {
                            shouldEmitNotification = true
                        }

                        guard shouldEmitNotification else {
                            continue
                        }
                        self.updateActiveCommandLifecycles(commandLifecycleByItemID, threadID: run.threadID)

                        for event in decoded.events {
                            for commandEvent in commandLifecycleByItemID.closeActiveCommands(for: event) {
                                if await completionCoordinator.emit(
                                    commandEvent,
                                    continuation: continuation,
                                    record: recordEvent
                                ) {
                                    return
                                }
                            }
                            if event.activeCommandTerminalStatus != nil {
                                commandLifecycleByItemID.removeAll(keepingCapacity: true)
                                self.updateActiveCommandLifecycles(commandLifecycleByItemID, threadID: run.threadID)
                            }
                            if event.shouldDeferCompletion(awaitingReviewExit: awaitingReviewExit) {
                                // The app-server review task emits exitedReviewMode before the
                                // parent turn completes. If a buffered/replayed stream presents
                                // completion first, keep it pending until the review exit item
                                // arrives instead of guessing with a timer.
                                await completionCoordinator.deferCompletion(event)
                                continue
                            }
                            if await completionCoordinator.emit(
                                event,
                                continuation: continuation,
                                record: recordEvent
                            ) {
                                return
                            }
                        }

                        if decoded.finishesReviewMode {
                            awaitingReviewExit = false
                            if await completionCoordinator.flushPendingCompletion(
                                continuation: continuation,
                                record: recordEvent
                            ) {
                                return
                            }
                        }
                    }
                    if await completionCoordinator.flushPendingCompletion(
                        continuation: continuation,
                        record: recordEvent
                    ) {
                        return
                    }
                    await completionCoordinator.finishIfNeeded(continuation: continuation)
                } catch {
                    await completionCoordinator.cancelPendingCompletion()
                    continuation.finish(throwing: error)
                }
                self.clearActiveCommandLifecycles(threadID: run.threadID)
                self.unregisterReviewEventContinuation(threadID: run.threadID)
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task {
                    await self.clearActiveCommandLifecycles(threadID: run.threadID)
                    await self.unregisterReviewEventContinuation(threadID: run.threadID)
                }
            }
        }
    }

    private func registerReviewEventContinuation(
        _ continuation: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation,
        threadID: String
    ) -> Bool {
        if let pendingFinish = pendingReviewEventStreamFinishesByThreadID.removeValue(forKey: threadID) {
            pendingFinish.emit(to: continuation)
            return false
        }
        reviewEventContinuationsByThreadID[threadID] = continuation
        return true
    }

    private func unregisterReviewEventContinuation(threadID: String) {
        reviewEventContinuationsByThreadID.removeValue(forKey: threadID)
    }

    private func updateActiveCommandLifecycles(
        _ lifecycles: [String: AppServerCommandLifecycle],
        threadID: String
    ) {
        if lifecycles.isEmpty {
            activeCommandLifecyclesByThreadID.removeValue(forKey: threadID)
        } else {
            activeCommandLifecyclesByThreadID[threadID] = lifecycles
        }
    }

    private func clearActiveCommandLifecycles(threadID: String) {
        activeCommandLifecyclesByThreadID.removeValue(forKey: threadID)
    }

    private func finishReviewEventStream(
        threadID: String,
        cancellationMessage: String?,
        buffersMissingContinuation: Bool = false
    ) {
        let precedingEvents: [BackendReviewEvent]
        if cancellationMessage == nil {
            precedingEvents = []
        } else {
            precedingEvents = activeCommandLifecyclesByThreadID
                .removeValue(forKey: threadID)?
                .closeActiveCommands(status: "canceled") ?? []
        }
        guard let continuation = reviewEventContinuationsByThreadID.removeValue(forKey: threadID) else {
            if buffersMissingContinuation {
                pendingReviewEventStreamFinishesByThreadID[threadID] = .init(
                    precedingEvents: precedingEvents,
                    cancellationMessage: cancellationMessage
                )
            }
            return
        }
        PendingReviewEventStreamFinish(
            precedingEvents: precedingEvents,
            cancellationMessage: cancellationMessage
        ).emit(to: continuation)
    }

    private func recordReviewEvent(_ event: BackendReviewEvent, for run: BackendReviewRun) async {
        guard let control = controlsByThreadID[run.threadID] else {
            return
        }
        switch event {
        case .started(let turnID, _, _):
            await control.recordTurnStarted(threadID: run.threadID, turnID: turnID)
        case .completed, .failed, .cancelled:
            await control.finish()
        case .message, .messageDelta, .log, .logEntry:
            break
        }
    }

    private func readModelCatalog() async throws -> [CodexReviewModelCatalogItem] {
        var cursor: String?
        var models: [CodexReviewModelCatalogItem] = []
        repeat {
            let response = try await client.send(ModelListRequest(
                params: .init(cursor: cursor, includeHidden: true)
            ))
            models.append(contentsOf: response.data)
            cursor = response.nextCursor?.nilIfEmpty
        } while cursor != nil
        return models
    }
}

private struct PendingReviewEventStreamFinish {
    var precedingEvents: [BackendReviewEvent] = []
    var cancellationMessage: String?

    func emit(to continuation: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation) {
        for event in precedingEvents {
            continuation.yield(event)
        }
        if let cancellationMessage {
            continuation.yield(.cancelled(cancellationMessage))
        }
        continuation.finish()
    }
}

private struct DecodedReviewNotification {
    var events: [BackendReviewEvent]
    var turnID: String?
    var startsReviewMode: Bool
    var finishesReviewMode: Bool
}

private extension BackendReviewEvent {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .started, .message, .messageDelta, .log, .logEntry:
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
        case .started, .message, .messageDelta, .log, .logEntry:
            return nil
        }
    }
}

private actor ReviewCompletionCoordinator {
    private var pendingCompletion: BackendReviewEvent?
    private var finished = false

    func emit(
        _ event: BackendReviewEvent,
        continuation: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation,
        record: @Sendable (BackendReviewEvent) async -> Void
    ) async -> Bool {
        guard finished == false else {
            return true
        }
        await record(event)
        continuation.yield(event)
        guard event.isTerminal else {
            return false
        }
        finish(continuation: continuation)
        return true
    }

    func deferCompletion(_ event: BackendReviewEvent) {
        guard finished == false else {
            return
        }
        pendingCompletion = event
    }

    func flushPendingCompletion(
        continuation: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation,
        record: @Sendable (BackendReviewEvent) async -> Void
    ) async -> Bool {
        guard finished == false,
              let event = pendingCompletion
        else {
            return false
        }
        pendingCompletion = nil
        await record(event)
        continuation.yield(event)
        finish(continuation: continuation)
        return true
    }

    func cancelPendingCompletion() {
        pendingCompletion = nil
    }

    func finishIfNeeded(
        continuation: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation
    ) {
        guard finished == false else {
            return
        }
        finish(continuation: continuation)
    }

    private func finish(
        continuation: AsyncThrowingStream<BackendReviewEvent, Error>.Continuation
    ) {
        finished = true
        pendingCompletion = nil
        continuation.finish()
    }
}

private extension AppServerCodexReviewBackend {
    static func configEdits(from change: BackendSettingsChange) -> [AppServerConfigEdit] {
        var edits: [AppServerConfigEdit] = []
        if change.updatesModel {
            edits.append(.init(
                keyPath: "review_model",
                value: change.model.map(AppServerJSONValue.string) ?? .null
            ))
        }
        if change.updatesReasoningEffort {
            edits.append(.init(
                keyPath: "model_reasoning_effort",
                value: change.reasoningEffort.map(AppServerJSONValue.string) ?? .null
            ))
        }
        if change.updatesServiceTier {
            edits.append(.init(
                keyPath: "service_tier",
                value: change.serviceTier.map(AppServerJSONValue.string) ?? .null
            ))
        }
        return edits
    }
}

private extension AppServerAccount {
    var backendAccount: BackendAccountSnapshot {
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

private extension LoginAccountResponse {
    var backendChallenge: BackendLoginChallenge {
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
            throw ReviewError.io("Invalid ChatGPT authentication URL in \(field).")
        }
        return url
    }
}

private struct TurnNotificationPayload: Decodable {
    var threadID: String?
    var turn: AppServerNotificationTurn?
    var turnID: String?
    var itemID: String?
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
    var deltaBase64: String?
    var diff: String?
    var result: String?
    var error: AppServerTurnError?
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
        case deltaBase64
        case diff
        case result
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
        self.turn = try? container.decodeIfPresent(AppServerNotificationTurn.self, forKey: .turn)
        self.turnID = try container.decodeStringIfPresent(forKey: .turnID)
        self.itemID = try container.decodeStringIfPresent(forKey: .itemID)
        self.item = try? container.decodeIfPresent(AppServerThreadItem.self, forKey: .item)
        self.startedAtMs = try? container.decodeIfPresent(Int64.self, forKey: .startedAtMs)
        self.completedAtMs = try? container.decodeIfPresent(Int64.self, forKey: .completedAtMs)
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
        self.deltaBase64 = try container.decodeStringIfPresent(forKey: .deltaBase64)
        self.diff = try container.decodeStringIfPresent(forKey: .diff)
        self.result = try container.decodeStringIfPresent(forKey: .result)
        self.error = try? container.decodeIfPresent(AppServerTurnError.self, forKey: .error)
        self.willRetry = try? container.decodeIfPresent(Bool.self, forKey: .willRetry)
        self.status = try? container.decodeIfPresent(AppServerThreadStatus.self, forKey: .status)
        self.summaryIndex = try? container.decodeIfPresent(Int.self, forKey: .summaryIndex)
        self.contentIndex = try? container.decodeIfPresent(Int.self, forKey: .contentIndex)
        self.plan = (try? container.decodeIfPresent([AppServerTurnPlanStep].self, forKey: .plan)) ?? []
        self.verifications = (try? container.decodeIfPresent([String].self, forKey: .verifications)) ?? []
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
        self.id = try container.decodeStringIfPresent(forKey: .id) ?? ""
        self.status = try container.decodeStringIfPresent(forKey: .status)
        self.error = try? container.decodeIfPresent(AppServerNotificationTurnError.self, forKey: .error)
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

private func decodeReviewNotification(
    _ notification: JSONRPCNotification,
    threadID: String,
    fallbackReviewThreadID: String,
    commandLifecycleByItemID: inout [String: AppServerCommandLifecycle]
) throws -> DecodedReviewNotification? {
    guard isReviewNotificationMethod(notification.method) else {
        return nil
    }
    guard let payload = try? JSONDecoder().decode(TurnNotificationPayload.self, from: notification.params) else {
        return nil
    }
    guard payload.threadID == threadID || (payload.threadID == nil && isGlobalDiagnosticMethod(notification.method)) else {
        return nil
    }
    let events: [BackendReviewEvent]
    switch notification.method {
    case "turn/started":
        events = [.started(
            turnID: payload.resolvedTurnID ?? "",
            reviewThreadID: payload.reviewThreadID ?? fallbackReviewThreadID,
            model: payload.model
        )]
    case "item/started":
        if let item = payload.item,
           item.type == "commandExecution" {
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
    case "item/completed":
        if let item = payload.item,
           item.type == "commandExecution" {
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
        events = payload.deltaLog(
            kind: .commandOutput,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: payload.itemID)
        ).map { [$0] } ?? []
    case "item/fileChange/outputDelta":
        events = payload.deltaLog(
            kind: .commandOutput,
            metadata: .init(sourceType: "fileChange", title: "File change output")
        ).map { [$0] } ?? []
    case "command/exec/outputDelta",
        "process/outputDelta":
        events = payload.base64OutputLog(
            kind: .commandOutput,
            metadata: .init(sourceType: "commandExecution", title: "Command output", itemID: payload.itemID)
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
                result: payload.result
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
    case "warning", "guardianWarning", "deprecationNotice", "configWarning":
        guard let message = payload.diagnosticText?.nilIfEmpty else {
            return nil
        }
        events = [.logEntry(kind: .diagnostic, text: message, groupID: payload.turnID, replacesGroup: false)]
    default:
        return nil
    }
    return .init(
        events: events,
        turnID: payload.resolvedTurnID,
        startsReviewMode: notification.method == "item/started" && payload.item?.type == "enteredReviewMode",
        finishesReviewMode: notification.method == "item/completed" && payload.item?.type == "exitedReviewMode"
    )
}

private func isReviewNotificationMethod(_ method: String) -> Bool {
    switch method {
    case "thread/closed",
        "thread/status/changed",
        "turn/started",
        "turn/completed",
        "turn/failed",
        "turn/cancelled",
        "turn/diff/updated",
        "turn/plan/updated",
        "item/started",
        "item/completed",
        "item/autoApprovalReview/started",
        "item/autoApprovalReview/completed",
        "item/agentMessage/delta",
        "item/plan/delta",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/summaryPartAdded",
        "item/reasoning/textDelta",
        "item/commandExecution/outputDelta",
        "item/commandExecution/terminalInteraction",
        "command/exec/outputDelta",
        "process/outputDelta",
        "item/fileChange/outputDelta",
        "item/fileChange/patchUpdated",
        "item/mcpToolCall/progress",
        "agent/message",
        "log",
        "error",
        "model/rerouted",
        "model/verification",
        "thread/compacted",
        "warning",
        "guardianWarning",
        "deprecationNotice",
        "configWarning":
        true
    default:
        false
    }
}

private func isGlobalDiagnosticMethod(_ method: String) -> Bool {
    switch method {
    case "warning", "deprecationNotice", "configWarning":
        true
    default:
        false
    }
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
    ) -> BackendReviewEvent? {
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

    func base64OutputLog(
        kind: ReviewLogEntry.Kind,
        metadata: ReviewLogEntry.Metadata? = nil
    ) -> BackendReviewEvent? {
        guard let deltaBase64,
              let data = Data(base64Encoded: deltaBase64),
              let text = String(data: data, encoding: .utf8),
              text.isEmpty == false
        else {
            return nil
        }
        return .logEntry(
            kind: kind,
            text: text,
            groupID: itemID,
            replacesGroup: false,
            metadata: metadata
        )
    }

    func messageLog(
        kind: ReviewLogEntry.Kind,
        metadata: ReviewLogEntry.Metadata? = nil
    ) -> BackendReviewEvent? {
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
        self.type = try container.decodeStringIfPresent(forKey: .type) ?? "unknown"
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

    init(
        item: AppServerThreadItem,
        startedAt: Date?,
        completedAt: Date?,
        fallback: AppServerCommandLifecycle? = nil
    ) {
        self.itemID = item.id
        self.command = item.command ?? fallback?.command
        self.cwd = item.cwd ?? fallback?.cwd
        self.startedAt = startedAt ?? fallback?.startedAt
        self.completedAt = completedAt ?? fallback?.completedAt
        self.durationMs = item.durationMs ?? fallback?.durationMs
        let actions = item.metadataCommandActions
        self.commandActions = actions?.isEmpty == false ? actions : fallback?.commandActions
        self.commandStatus = item.status?.nilIfEmpty ?? fallback?.commandStatus
    }

    func closingEvent(status: String, completedAt: Date) -> BackendReviewEvent? {
        guard let command = command?.nilIfEmpty else {
            return nil
        }
        return .logEntry(
            kind: .command,
            text: "$ \(command)",
            groupID: itemID,
            replacesGroup: true,
            metadata: .init(
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
        )
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
    func closeActiveCommands(for terminalEvent: BackendReviewEvent) -> [BackendReviewEvent] {
        guard let status = terminalEvent.activeCommandTerminalStatus else {
            return []
        }
        return closeActiveCommands(status: status)
    }

    func closeActiveCommands(status: String, completedAt: Date = Date()) -> [BackendReviewEvent] {
        values
            .sorted {
                switch ($0.startedAt, $1.startedAt) {
                case let (lhs?, rhs?) where lhs != rhs:
                    return lhs < rhs
                default:
                    return $0.itemID < $1.itemID
                }
            }
            .compactMap { $0.closingEvent(status: status, completedAt: completedAt) }
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeStringIfPresent(forKey: .type) ?? "unknown"
        self.id = try container.decodeStringIfPresent(forKey: .id) ?? UUID().uuidString
        self.text = try container.decodeStringIfPresent(forKey: .text)
        self.command = try container.decodeStringIfPresent(forKey: .command)
        self.cwd = try container.decodeStringIfPresent(forKey: .cwd)
        self.processID = try container.decodeStringIfPresent(forKey: .processID)
        self.source = try container.decodeStringIfPresent(forKey: .source)
        self.aggregatedOutput = try container.decodeStringIfPresent(forKey: .aggregatedOutput)
        self.exitCode = try? container.decodeIfPresent(Int.self, forKey: .exitCode)
        self.durationMs = try? container.decodeIfPresent(Int.self, forKey: .durationMs)
        self.commandActions = (try? container.decodeIfPresent([AppServerCommandAction].self, forKey: .commandActions)) ?? []
        self.status = try container.decodeStringIfPresent(forKey: .status)
        self.server = try container.decodeStringIfPresent(forKey: .server)
        self.tool = try container.decodeStringIfPresent(forKey: .tool)
        self.namespace = try container.decodeStringIfPresent(forKey: .namespace)
        self.query = try container.decodeStringIfPresent(forKey: .query)
        self.path = try container.decodeStringIfPresent(forKey: .path)
        self.review = try container.decodeStringIfPresent(forKey: .review)
        self.summary = (try? container.decodeIfPresent([String].self, forKey: .summary)) ?? []
        self.content = (try? container.decodeIfPresent([String].self, forKey: .content)) ?? []
        self.result = try? container.decodeIfPresent(AppServerNotificationValue.self, forKey: .result)
        self.error = try? container.decodeIfPresent(AppServerNotificationValue.self, forKey: .error)
        self.success = try? container.decodeIfPresent(Bool.self, forKey: .success)
        self.prompt = try container.decodeStringIfPresent(forKey: .prompt)
    }

    func startedEvents(
        startedAt: Date?,
        lifecycle: AppServerCommandLifecycle?
    ) -> [BackendReviewEvent] {
        switch type {
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
            return [.logEntry(kind: .event, text: "App-server item started: \(type).", groupID: id, replacesGroup: true)]
        }
    }

    func completedEvents(
        completedAt: Date?,
        lifecycle: AppServerCommandLifecycle?
    ) -> [BackendReviewEvent] {
        switch type {
        case "agentMessage":
            return text.map { [.logEntry(kind: .agentMessage, text: $0, groupID: id, replacesGroup: true)] } ?? []
        case "exitedReviewMode":
            return review.map { [.logEntry(kind: .agentMessage, text: $0, groupID: id, replacesGroup: true)] } ?? []
        case "commandExecution":
            if let output = aggregatedOutput?.nilIfEmpty {
                var events: [BackendReviewEvent] = []
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
            return [logEntry(kind: .toolCall, text: "\(toolLabel) \(status ?? "completed").\(resultSuffix)", replacesGroup: true, title: toolLabel, status: completedStatus)]
        case "dynamicToolCall":
            return [logEntry(kind: .toolCall, text: "Dynamic tool \(toolLabel) \(status ?? "completed").\(resultSuffix)", replacesGroup: true, title: toolLabel, status: completedStatus)]
        case "collabAgentToolCall":
            return [logEntry(kind: .toolCall, text: "Collab tool \(toolLabel) \(status ?? "completed").\(promptSuffix)", replacesGroup: true, title: toolLabel, status: completedStatus, detail: prompt)]
        case "webSearch":
            return [logEntry(kind: .toolCall, text: "Web search completed: \(query ?? "search").", replacesGroup: true, title: "Web search", status: completedStatus)]
        case "imageView":
            return [logEntry(kind: .toolCall, text: "Image viewed: \(path ?? "image").", replacesGroup: true, title: "Image view", status: completedStatus)]
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
            return [.logEntry(kind: .event, text: "App-server item completed: \(type).", groupID: id, replacesGroup: true)]
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
    ) -> BackendReviewEvent {
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
        let isCommandExecution = type == "commandExecution"
        let isLifecycleItem = isCommandExecution || type == "contextCompaction"
        return .init(
            sourceType: type,
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

    private func reasoningCompletionEvents(replacesGroup: Bool) -> [BackendReviewEvent] {
        let summaryEvents = (summary ?? []).enumerated().compactMap { index, text -> BackendReviewEvent? in
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
        let rawEvents = (content ?? []).enumerated().compactMap { index, text -> BackendReviewEvent? in
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
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        return nil
    }
}
