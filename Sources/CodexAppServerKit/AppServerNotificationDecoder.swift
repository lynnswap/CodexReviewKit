import Foundation

package struct AppServerNotificationDecoder {
    package enum Disposition: Equatable, Sendable {
        case route
        case diagnostic
        case explicitIgnore
    }

    package enum Method: String, CaseIterable, Equatable, Sendable {
        case error
        case threadStarted = "thread/started"
        case threadStatusChanged = "thread/status/changed"
        case threadArchived = "thread/archived"
        case threadDeleted = "thread/deleted"
        case threadUnarchived = "thread/unarchived"
        case threadClosed = "thread/closed"
        case skillsChanged = "skills/changed"
        case threadNameUpdated = "thread/name/updated"
        case threadGoalUpdated = "thread/goal/updated"
        case threadGoalCleared = "thread/goal/cleared"
        case threadSettingsUpdated = "thread/settings/updated"
        case threadTokenUsageUpdated = "thread/tokenUsage/updated"
        case turnStarted = "turn/started"
        case hookStarted = "hook/started"
        case turnCompleted = "turn/completed"
        case hookCompleted = "hook/completed"
        case turnDiffUpdated = "turn/diff/updated"
        case turnPlanUpdated = "turn/plan/updated"
        case itemStarted = "item/started"
        case itemAutoApprovalReviewStarted = "item/autoApprovalReview/started"
        case itemAutoApprovalReviewCompleted = "item/autoApprovalReview/completed"
        case itemCompleted = "item/completed"
        case rawResponseItemCompleted = "rawResponseItem/completed"
        case itemAgentMessageDelta = "item/agentMessage/delta"
        case itemPlanDelta = "item/plan/delta"
        case commandExecOutputDelta = "command/exec/outputDelta"
        case processOutputDelta = "process/outputDelta"
        case processExited = "process/exited"
        case itemCommandExecutionOutputDelta = "item/commandExecution/outputDelta"
        case itemCommandExecutionTerminalInteraction =
            "item/commandExecution/terminalInteraction"
        case itemFileChangeOutputDelta = "item/fileChange/outputDelta"
        case itemFileChangePatchUpdated = "item/fileChange/patchUpdated"
        case serverRequestResolved = "serverRequest/resolved"
        case itemMCPToolCallProgress = "item/mcpToolCall/progress"
        case mcpServerOAuthLoginCompleted = "mcpServer/oauthLogin/completed"
        case mcpServerStartupStatusUpdated = "mcpServer/startupStatus/updated"
        case accountUpdated = "account/updated"
        case accountRateLimitsUpdated = "account/rateLimits/updated"
        case appListUpdated = "app/list/updated"
        case remoteControlStatusChanged = "remoteControl/status/changed"
        case externalAgentConfigImportProgress = "externalAgentConfig/import/progress"
        case externalAgentConfigImportCompleted = "externalAgentConfig/import/completed"
        case fsChanged = "fs/changed"
        case itemReasoningSummaryTextDelta = "item/reasoning/summaryTextDelta"
        case itemReasoningSummaryPartAdded = "item/reasoning/summaryPartAdded"
        case itemReasoningTextDelta = "item/reasoning/textDelta"
        case threadCompacted = "thread/compacted"
        case modelRerouted = "model/rerouted"
        case modelVerification = "model/verification"
        case turnModerationMetadata = "turn/moderationMetadata"
        case modelSafetyBufferingUpdated = "model/safetyBuffering/updated"
        case warning
        case guardianWarning
        case deprecationNotice
        case configWarning
        case fuzzyFileSearchSessionUpdated = "fuzzyFileSearch/sessionUpdated"
        case fuzzyFileSearchSessionCompleted = "fuzzyFileSearch/sessionCompleted"
        case threadRealtimeStarted = "thread/realtime/started"
        case threadRealtimeItemAdded = "thread/realtime/itemAdded"
        case threadRealtimeTranscriptDelta = "thread/realtime/transcript/delta"
        case threadRealtimeTranscriptDone = "thread/realtime/transcript/done"
        case threadRealtimeOutputAudioDelta = "thread/realtime/outputAudio/delta"
        case threadRealtimeSDP = "thread/realtime/sdp"
        case threadRealtimeError = "thread/realtime/error"
        case threadRealtimeClosed = "thread/realtime/closed"
        case windowsWorldWritableWarning = "windows/worldWritableWarning"
        case windowsSandboxSetupCompleted = "windowsSandbox/setupCompleted"
        case accountLoginCompleted = "account/login/completed"

        package var disposition: Disposition {
            switch self {
            case .error,
                 .threadStarted,
                 .threadStatusChanged,
                 .threadArchived,
                 .threadDeleted,
                 .threadUnarchived,
                 .threadClosed,
                 .threadNameUpdated,
                 .threadTokenUsageUpdated,
                 .turnStarted,
                 .turnCompleted,
                 .turnDiffUpdated,
                 .turnPlanUpdated,
                 .itemStarted,
                 .itemCompleted,
                 .itemAgentMessageDelta,
                 .itemPlanDelta,
                 .itemCommandExecutionOutputDelta,
                 .itemFileChangePatchUpdated,
                 .serverRequestResolved,
                 .itemMCPToolCallProgress,
                 .accountUpdated,
                 .accountRateLimitsUpdated,
                 .accountLoginCompleted,
                 .itemReasoningSummaryTextDelta,
                 .itemReasoningSummaryPartAdded,
                 .itemReasoningTextDelta:
                .route

            case .warning,
                 .guardianWarning,
                 .deprecationNotice,
                 .configWarning,
                 .modelRerouted,
                 .modelVerification,
                 .turnModerationMetadata,
                 .modelSafetyBufferingUpdated,
                 .windowsWorldWritableWarning,
                 .windowsSandboxSetupCompleted:
                .diagnostic

            case .skillsChanged,
                 .threadGoalUpdated,
                 .threadGoalCleared,
                 .threadSettingsUpdated,
                 .hookStarted,
                 .hookCompleted,
                 .itemAutoApprovalReviewStarted,
                 .itemAutoApprovalReviewCompleted,
                 .rawResponseItemCompleted,
                 .commandExecOutputDelta,
                 .processOutputDelta,
                 .processExited,
                 .itemCommandExecutionTerminalInteraction,
                 .itemFileChangeOutputDelta,
                 .mcpServerOAuthLoginCompleted,
                 .mcpServerStartupStatusUpdated,
                 .appListUpdated,
                 .remoteControlStatusChanged,
                 .externalAgentConfigImportProgress,
                 .externalAgentConfigImportCompleted,
                 .fsChanged,
                 .threadCompacted,
                 .fuzzyFileSearchSessionUpdated,
                 .fuzzyFileSearchSessionCompleted,
                 .threadRealtimeStarted,
                 .threadRealtimeItemAdded,
                 .threadRealtimeTranscriptDelta,
                 .threadRealtimeTranscriptDone,
                 .threadRealtimeOutputAudioDelta,
                 .threadRealtimeSDP,
                 .threadRealtimeError,
                 .threadRealtimeClosed:
                .explicitIgnore
            }
        }
    }

    package struct Context: Equatable, Sendable {
        package var threadID: CodexThreadID?
        package var turnID: CodexTurnID?

        package init(threadID: CodexThreadID? = nil, turnID: CodexTurnID? = nil) {
            self.threadID = threadID
            self.turnID = turnID
        }
    }

    package enum AccountMutation: Equatable, Sendable {
        case updated(AccountUpdate)
        case rateLimitsUpdated(AppServerAPI.Account.RateLimits.Snapshot)
        case loginCompleted(CodexLoginCompletion)
    }

    package struct AccountUpdate: Equatable, Sendable {
        package enum AuthMode: String, Equatable, Sendable {
            case apiKey = "apikey"
            case chatGPT = "chatgpt"
            case chatGPTAuthTokens
            case headers
            case agentIdentity
            case personalAccessToken
            case bedrockAPIKey = "bedrockApiKey"
        }

        package enum PlanType: String, Equatable, Sendable {
            case free
            case go
            case plus
            case pro
            case prolite
            case team
            case selfServeBusinessUsageBased = "self_serve_business_usage_based"
            case business
            case enterpriseCBPUsageBased = "enterprise_cbp_usage_based"
            case enterprise
            case edu
            case unknown
        }

        package var authMode: AuthMode?
        package var planType: PlanType?
    }

    package enum Payload: Equatable, Sendable {
        case turnCompleted(AppServerAPI.Turn.Payload)
        case item(CodexItemReducer.Mutation)
        case turnStarted(CodexTurnID)
        case threadStatus(CodexThreadStatus)
        case tokenUsage(CodexTokenUsage)
        case threadClosed
        case serverRequestResolved(CodexServerRequestID)
        case account(AccountMutation)
        case connectionDiagnostic(CodexConnectionEvent)
        case raw
        case ignored
    }

    package struct DecodedNotification: Equatable, Sendable {
        package var method: Method?
        package var methodName: String
        package var disposition: Disposition
        package var context: Context
        package var payload: Payload
        package var rawData: Data
    }

    private enum ItemLifecycle {
        case started(Date)
        case completed(Date)
    }

    private let decoder = JSONDecoder()

    package init() {}

    package func decode(_ notification: JSONRPC.Notification) throws -> DecodedNotification {
        guard let method = Method(rawValue: notification.method) else {
            let context = Self.bestEffortContext(from: notification.params)
            return .init(
                method: nil,
                methodName: notification.method,
                disposition: .diagnostic,
                context: context,
                payload: .connectionDiagnostic(.unknown(.init(
                    method: notification.method,
                    params: notification.params,
                    threadID: context.threadID,
                    turnID: context.turnID
                ))),
                rawData: notification.params
            )
        }

        do {
            let object = try PayloadObject(data: notification.params, decoder: decoder)
            let context = try validate(method, object: object)
            let payload = try payload(method, object: object, data: notification.params)
            return .init(
                method: method,
                methodName: notification.method,
                disposition: method.disposition,
                context: context,
                payload: payload,
                rawData: notification.params
            )
        } catch let error as CodexAppServerError {
            throw error
        } catch {
            throw CodexAppServerError.malformedNotification(.init(
                method: notification.method,
                message: error.localizedDescription,
                rawData: notification.params
            ))
        }
    }

    private func payload(
        _ method: Method,
        object: PayloadObject,
        data: Data
    ) throws -> Payload {
        switch method {
        case .error:
            return .item(.turnDiagnostic(try decodeTurnDiagnostic(from: object)))
        case .turnCompleted:
            return .turnCompleted(try decodeTurn(from: object, data: data, lifecycle: .completed))
        case .turnStarted:
            let turn = try decodeTurn(from: object, data: data, lifecycle: .started)
            return .turnStarted(.init(rawValue: turn.id))
        case .itemStarted:
            return .item(try decodeItem(from: object, lifecycle: .started(
                Self.date(millisecondsSince1970: try object.requireInt64("startedAtMs"))
            )))
        case .itemCompleted:
            return .item(try decodeItem(from: object, lifecycle: .completed(
                Self.date(millisecondsSince1970: try object.requireInt64("completedAtMs"))
            )))
        case .itemAgentMessageDelta:
            return .item(.agentMessageDelta(
                itemID: try object.requireNonWhitespaceString("itemId"),
                delta: try object.requireString("delta")
            ))
        case .itemPlanDelta:
            return .item(.planDelta(
                itemID: try object.requireNonEmptyString("itemId"),
                delta: try object.requireString("delta")
            ))
        case .itemReasoningSummaryPartAdded:
            return .item(.reasoningSummaryPartAdded(
                itemID: try object.requireNonEmptyString("itemId"),
                index: try object.requireInt("summaryIndex")
            ))
        case .itemReasoningSummaryTextDelta:
            return .item(.reasoningSummaryDelta(
                itemID: try object.requireNonEmptyString("itemId"),
                index: try object.requireInt("summaryIndex"),
                delta: try object.requireString("delta")
            ))
        case .itemReasoningTextDelta:
            return .item(.reasoningTextDelta(
                itemID: try object.requireNonEmptyString("itemId"),
                index: try object.requireInt("contentIndex"),
                delta: try object.requireString("delta")
            ))
        case .itemCommandExecutionOutputDelta:
            return .item(.commandOutputDelta(
                itemID: try object.requireNonEmptyString("itemId"),
                delta: try object.requireString("delta")
            ))
        case .itemFileChangePatchUpdated:
            let changes = try object.requireArray("changes")
            try validateFileChanges(changes)
            return .item(.filePatchSnapshot(
                itemID: try object.requireNonEmptyString("itemId"),
                output: try changes.map {
                    try PayloadObject.object($0, path: "changes[]").requireString("diff")
                }.joined(separator: "\n")
            ))
        case .itemMCPToolCallProgress:
            return .item(.mcpProgress(
                itemID: try object.requireNonEmptyString("itemId"),
                message: try object.requireString("message")
            ))
        case .threadStatusChanged:
            return .threadStatus(try decodeThreadStatus(from: object.requireObject("status")))
        case .threadTokenUsageUpdated:
            return .tokenUsage(try decodeTokenUsage(from: object.requireObject("tokenUsage")))
        case .threadClosed:
            return .threadClosed
        case .serverRequestResolved:
            return .serverRequestResolved(try object.requireRequestID("requestId"))
        case .accountUpdated:
            return .account(.updated(try decodeAccountUpdate(from: object)))
        case .accountRateLimitsUpdated:
            return .account(.rateLimitsUpdated(try decodeRateLimitSnapshot(
                from: object.requireObject("rateLimits")
            )))
        case .accountLoginCompleted:
            return .account(.loginCompleted(.init(
                loginID: try object.optionalString("loginId").map {
                    CodexLoginHandle.ID(rawValue: $0)
                },
                success: try object.requireBool("success"),
                error: try object.optionalString("error")
            )))
        case .warning, .guardianWarning:
            return .connectionDiagnostic(.warning(.init(
                message: try object.requireString("message"),
                method: method.rawValue
            )))
        case .deprecationNotice:
            return .connectionDiagnostic(.deprecation(.init(
                summary: try object.requireString("summary"),
                details: try object.optionalString("details")
            )))
        case .configWarning:
            return .connectionDiagnostic(.warning(.init(
                message: try object.requireString("summary"),
                method: method.rawValue,
                details: try object.optionalString("details")
            )))
        case .modelRerouted,
             .modelVerification,
             .turnModerationMetadata,
             .modelSafetyBufferingUpdated,
             .windowsWorldWritableWarning,
             .windowsSandboxSetupCompleted:
            return .connectionDiagnostic(.warning(.init(
                message: method.rawValue,
                method: method.rawValue
            )))
        case .threadStarted,
             .threadArchived,
             .threadDeleted,
             .threadUnarchived,
             .threadNameUpdated,
             .turnDiffUpdated,
             .turnPlanUpdated:
            return .raw
        case .skillsChanged,
             .threadGoalUpdated,
             .threadGoalCleared,
             .threadSettingsUpdated,
             .hookStarted,
             .hookCompleted,
             .itemAutoApprovalReviewStarted,
             .itemAutoApprovalReviewCompleted,
             .rawResponseItemCompleted,
             .commandExecOutputDelta,
             .processOutputDelta,
             .processExited,
             .itemCommandExecutionTerminalInteraction,
             .itemFileChangeOutputDelta,
             .mcpServerOAuthLoginCompleted,
             .mcpServerStartupStatusUpdated,
             .appListUpdated,
             .remoteControlStatusChanged,
             .externalAgentConfigImportProgress,
             .externalAgentConfigImportCompleted,
             .fsChanged,
             .threadCompacted,
             .fuzzyFileSearchSessionUpdated,
             .fuzzyFileSearchSessionCompleted,
             .threadRealtimeStarted,
             .threadRealtimeItemAdded,
             .threadRealtimeTranscriptDelta,
             .threadRealtimeTranscriptDone,
             .threadRealtimeOutputAudioDelta,
             .threadRealtimeSDP,
             .threadRealtimeError,
             .threadRealtimeClosed:
            return .ignored
        }
    }

    private func validate(_ method: Method, object: PayloadObject) throws -> Context {
        switch method {
        case .error:
            _ = try object.requireObject("error")
            _ = try object.requireBool("willRetry")
            return try object.threadTurnContext()
        case .threadStarted:
            let thread = try object.requireObject("thread")
            try validateThread(thread)
            return .init(threadID: try thread.requiredThreadID(key: "id"))
        case .threadStatusChanged:
            _ = try decodeThreadStatus(from: object.requireObject("status"))
            return .init(threadID: try object.requiredThreadID())
        case .threadArchived, .threadDeleted, .threadUnarchived, .threadClosed:
            return .init(threadID: try object.requiredThreadID())
        case .threadNameUpdated:
            _ = try object.optionalString("threadName")
            return .init(threadID: try object.requiredThreadID())
        case .threadTokenUsageUpdated:
            _ = try decodeTokenUsage(from: object.requireObject("tokenUsage"))
            return try object.threadTurnContext()
        case .turnStarted:
            let turn = try object.requireObject("turn")
            try validateTurn(turn, lifecycle: .started)
            return .init(
                threadID: try object.requiredThreadID(),
                turnID: try turn.requiredTurnID(key: "id")
            )
        case .turnCompleted:
            let turn = try object.requireObject("turn")
            try validateTurn(turn, lifecycle: .completed)
            return .init(
                threadID: try object.requiredThreadID(),
                turnID: try turn.requiredTurnID(key: "id")
            )
        case .turnDiffUpdated:
            _ = try object.requireString("diff")
            return try object.threadTurnContext()
        case .turnPlanUpdated:
            try validateTurnPlan(object.requireArray("plan"))
            _ = try object.optionalString("explanation")
            return try object.threadTurnContext()
        case .itemStarted:
            _ = try object.requireInt64("startedAtMs")
            try validateThreadItem(object.requireObject("item"), lifecycle: .started)
            return try object.threadTurnContext()
        case .itemCompleted:
            _ = try object.requireInt64("completedAtMs")
            try validateThreadItem(object.requireObject("item"), lifecycle: .completed)
            return try object.threadTurnContext()
        case .itemAgentMessageDelta,
             .itemPlanDelta,
             .itemCommandExecutionOutputDelta,
             .itemFileChangeOutputDelta:
            _ = try object.requireNonEmptyString("itemId")
            _ = try object.requireString("delta")
            return try object.threadTurnContext()
        case .itemReasoningSummaryTextDelta:
            _ = try object.requireNonEmptyString("itemId")
            _ = try object.requireInt("summaryIndex")
            _ = try object.requireString("delta")
            return try object.threadTurnContext()
        case .itemReasoningSummaryPartAdded:
            _ = try object.requireNonEmptyString("itemId")
            _ = try object.requireInt("summaryIndex")
            return try object.threadTurnContext()
        case .itemReasoningTextDelta:
            _ = try object.requireNonEmptyString("itemId")
            _ = try object.requireInt("contentIndex")
            _ = try object.requireString("delta")
            return try object.threadTurnContext()
        case .itemFileChangePatchUpdated:
            _ = try object.requireNonEmptyString("itemId")
            try validateFileChanges(object.requireArray("changes"))
            return try object.threadTurnContext()
        case .itemMCPToolCallProgress:
            _ = try object.requireNonEmptyString("itemId")
            _ = try object.requireString("message")
            return try object.threadTurnContext()
        case .serverRequestResolved:
            _ = try object.requireRequestID("requestId")
            return .init(threadID: try object.requiredThreadID())
        case .accountUpdated:
            _ = try decodeAccountUpdate(from: object)
            return .init()
        case .accountRateLimitsUpdated:
            _ = try decodeRateLimitSnapshot(from: object.requireObject("rateLimits"))
            return .init()
        case .accountLoginCompleted:
            _ = try object.optionalString("loginId")
            _ = try object.requireBool("success")
            _ = try object.optionalString("error")
            return .init()
        case .warning:
            _ = try object.requireString("message")
            _ = try object.optionalString("threadId")
            return Self.context(from: object)
        case .guardianWarning:
            _ = try object.requireString("message")
            return .init(threadID: try object.requiredThreadID())
        case .deprecationNotice:
            _ = try object.requireString("summary")
            _ = try object.optionalString("details")
            return Self.context(from: object)
        case .configWarning:
            _ = try object.requireString("summary")
            _ = try object.optionalString("details")
            _ = try object.optionalString("path")
            if let range = try object.optionalObject("range") {
                for endpoint in ["start", "end"] {
                    let position = try range.requireObject(endpoint)
                    _ = try position.requireInt("line")
                    _ = try position.requireInt("column")
                }
            }
            return Self.context(from: object)
        case .modelRerouted:
            for key in ["fromModel", "reason", "toModel"] {
                _ = try object.requireString(key)
            }
            return try object.threadTurnContext()
        case .modelVerification:
            _ = try object.requireArray("verifications")
            return try object.threadTurnContext()
        case .turnModerationMetadata:
            _ = try object.requireValue("metadata")
            return try object.threadTurnContext()
        case .modelSafetyBufferingUpdated:
            _ = try object.requireString("model")
            _ = try object.requireArray("reasons")
            _ = try object.requireBool("showBufferingUi")
            _ = try object.requireArray("useCases")
            return try object.threadTurnContext()
        case .windowsWorldWritableWarning:
            _ = try object.requireInt("extraCount")
            _ = try object.requireBool("failedScan")
            _ = try object.requireStringArray("samplePaths")
            return .init()
        case .windowsSandboxSetupCompleted:
            _ = try object.requireEnum(
                "mode",
                allowed: ["elevated", "unelevated"]
            )
            _ = try object.requireBool("success")
            _ = try object.optionalString("error")
            return .init()
        case .skillsChanged:
            return .init()
        case .threadGoalUpdated:
            try validateThreadGoal(object.requireObject("goal"))
            _ = try object.optionalString("turnId")
            return .init(threadID: try object.requiredThreadID())
        case .threadGoalCleared:
            return .init(threadID: try object.requiredThreadID())
        case .threadSettingsUpdated:
            try validateThreadSettings(object.requireObject("threadSettings"))
            return .init(threadID: try object.requiredThreadID())
        case .hookStarted, .hookCompleted:
            try validateHookRun(object.requireObject("run"))
            _ = try object.optionalString("turnId")
            return .init(threadID: try object.requiredThreadID())
        case .itemAutoApprovalReviewStarted:
            try validateAutoApprovalReview(object, completed: false)
            return try object.threadTurnContext()
        case .itemAutoApprovalReviewCompleted:
            try validateAutoApprovalReview(object, completed: true)
            return try object.threadTurnContext()
        case .rawResponseItemCompleted:
            try validateResponseItem(object.requireObject("item"))
            return try object.threadTurnContext()
        case .commandExecOutputDelta:
            _ = try object.requireBool("capReached")
            _ = try object.requireString("deltaBase64")
            _ = try object.requireNonEmptyString("processId")
            _ = try object.requireEnum("stream", allowed: ["stdout", "stderr"])
            return .init()
        case .processOutputDelta:
            _ = try object.requireBool("capReached")
            _ = try object.requireString("deltaBase64")
            _ = try object.requireNonEmptyString("processHandle")
            _ = try object.requireEnum("stream", allowed: ["stdout", "stderr"])
            return .init()
        case .processExited:
            _ = try object.requireInt("exitCode")
            _ = try object.requireNonEmptyString("processHandle")
            _ = try object.requireString("stderr")
            _ = try object.requireBool("stderrCapReached")
            _ = try object.requireString("stdout")
            _ = try object.requireBool("stdoutCapReached")
            return .init()
        case .itemCommandExecutionTerminalInteraction:
            _ = try object.requireNonEmptyString("itemId")
            _ = try object.requireNonEmptyString("processId")
            _ = try object.requireString("stdin")
            return try object.threadTurnContext()
        case .mcpServerOAuthLoginCompleted:
            _ = try object.requireNonEmptyString("name")
            _ = try object.requireBool("success")
            _ = try object.optionalString("error")
            _ = try object.optionalString("threadId")
            return .init()
        case .mcpServerStartupStatusUpdated:
            _ = try object.requireNonEmptyString("name")
            _ = try object.requireEnum(
                "status",
                allowed: ["starting", "ready", "failed", "cancelled"]
            )
            _ = try object.optionalString("error")
            _ = try object.optionalEnum(
                "failureReason",
                allowed: ["reauthenticationRequired"]
            )
            _ = try object.optionalString("threadId")
            return Self.context(from: object)
        case .appListUpdated:
            try validateAppList(object.requireArray("data"))
            return .init()
        case .remoteControlStatusChanged:
            _ = try object.requireNonEmptyString("installationId")
            _ = try object.requireNonEmptyString("serverName")
            _ = try object.requireEnum(
                "status",
                allowed: ["disabled", "connecting", "connected", "errored"]
            )
            return .init()
        case .externalAgentConfigImportProgress, .externalAgentConfigImportCompleted:
            _ = try object.requireNonEmptyString("importId")
            try validateExternalImportResults(object.requireArray("itemTypeResults"))
            return .init()
        case .fsChanged:
            _ = try object.requireStringArray("changedPaths")
            _ = try object.requireNonEmptyString("watchId")
            return .init()
        case .threadCompacted:
            return try object.threadTurnContext()
        case .fuzzyFileSearchSessionUpdated:
            _ = try object.requireArray("files")
            _ = try object.requireString("query")
            _ = try object.requireNonEmptyString("sessionId")
            return .init()
        case .fuzzyFileSearchSessionCompleted:
            _ = try object.requireNonEmptyString("sessionId")
            return .init()
        case .threadRealtimeStarted:
            _ = try object.requireEnum("version", allowed: ["v1", "v2"])
            _ = try object.optionalString("realtimeSessionId")
            return .init(threadID: try object.requiredThreadID())
        case .threadRealtimeItemAdded:
            _ = try object.requireValue("item")
            return .init(threadID: try object.requiredThreadID())
        case .threadRealtimeTranscriptDelta:
            _ = try object.requireString("delta")
            _ = try object.requireString("role")
            return .init(threadID: try object.requiredThreadID())
        case .threadRealtimeTranscriptDone:
            _ = try object.requireString("role")
            _ = try object.requireString("text")
            return .init(threadID: try object.requiredThreadID())
        case .threadRealtimeOutputAudioDelta:
            _ = try object.requireString("audio")
            return .init(threadID: try object.requiredThreadID())
        case .threadRealtimeSDP:
            _ = try object.requireString("sdp")
            return .init(threadID: try object.requiredThreadID())
        case .threadRealtimeError:
            _ = try object.requireString("message")
            return .init(threadID: try object.requiredThreadID())
        case .threadRealtimeClosed:
            _ = try object.optionalString("reason")
            return .init(threadID: try object.requiredThreadID())
        }
    }

    private func validateTurnPlan(_ values: [AppServerJSONValue]) throws {
        for value in values {
            let step = try PayloadObject.object(value, path: "plan[]")
            _ = try step.requireString("step")
            _ = try step.requireEnum(
                "status",
                allowed: ["pending", "inProgress", "completed"]
            )
        }
    }

    private func validateFileChanges(_ values: [AppServerJSONValue]) throws {
        for value in values {
            let change = try PayloadObject.object(value, path: "changes[]")
            _ = try change.requireString("diff")
            _ = try change.requireString("path")
            let kind = try change.requireObject("kind")
            let type = try kind.requireEnum("type", allowed: ["add", "delete", "update"])
            if type == "update" {
                _ = try kind.optionalString("move_path")
            }
        }
    }

    private func validateThreadGoal(_ goal: PayloadObject) throws {
        _ = try goal.requireInt64("createdAt")
        _ = try goal.requireString("objective")
        _ = try goal.requireEnum(
            "status",
            allowed: ["active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"]
        )
        _ = try goal.requireNonEmptyString("threadId")
        _ = try goal.requireInt64("timeUsedSeconds")
        _ = try goal.optionalInt64("tokenBudget")
        _ = try goal.requireInt64("tokensUsed")
        _ = try goal.requireInt64("updatedAt")
    }

    private func validateThreadSettings(_ settings: PayloadObject) throws {
        let approvalPolicy = try settings.requireValue("approvalPolicy")
        switch approvalPolicy {
        case .string(let value):
            guard ["untrusted", "on-request", "never"].contains(value) else {
                throw NotificationContractError.illegalValue(
                    key: "threadSettings.approvalPolicy",
                    value: value
                )
            }
        case .object(let values):
            let granular = try PayloadObject(values: values).requireObject("granular")
            _ = try granular.requireBool("mcp_elicitations")
            _ = try granular.requireBool("rules")
            _ = try granular.requireBool("sandbox_approval")
        default:
            throw NotificationContractError.typeMismatch("threadSettings.approvalPolicy")
        }
        _ = try settings.requireEnum(
            "approvalsReviewer",
            allowed: ["user", "auto_review", "guardian_subagent"]
        )
        let collaboration = try settings.requireObject("collaborationMode")
        _ = try collaboration.requireEnum("mode", allowed: ["plan", "default"])
        _ = try collaboration.requireObject("settings").requireString("model")
        _ = try settings.requireString("cwd")
        _ = try settings.requireString("model")
        _ = try settings.requireString("modelProvider")
        let sandbox = try settings.requireObject("sandboxPolicy")
        _ = try sandbox.requireEnum(
            "type",
            allowed: ["dangerFullAccess", "readOnly", "externalSandbox", "workspaceWrite"]
        )
    }

    private func validateHookRun(_ run: PayloadObject) throws {
        _ = try run.requireInt64("displayOrder")
        for value in try run.requireArray("entries") {
            let entry = try PayloadObject.object(value, path: "run.entries[]")
            _ = try entry.requireEnum(
                "kind",
                allowed: ["warning", "stop", "feedback", "context", "error"]
            )
            _ = try entry.requireString("text")
        }
        _ = try run.requireEnum(
            "eventName",
            allowed: [
                "preToolUse", "permissionRequest", "postToolUse", "preCompact", "postCompact",
                "sessionStart", "userPromptSubmit", "subagentStart", "subagentStop", "stop",
            ]
        )
        _ = try run.requireEnum("executionMode", allowed: ["sync", "async"])
        _ = try run.requireEnum("handlerType", allowed: ["command", "prompt", "agent"])
        _ = try run.requireNonEmptyString("id")
        _ = try run.requireEnum("scope", allowed: ["thread", "turn"])
        _ = try run.requireString("sourcePath")
        _ = try run.requireInt64("startedAt")
        _ = try run.requireEnum(
            "status",
            allowed: ["running", "completed", "failed", "blocked", "stopped"]
        )
    }

    private func validateResponseItem(_ item: PayloadObject) throws {
        let type = try item.requireEnum(
            "type",
            allowed: [
                "message", "agent_message", "reasoning", "local_shell_call", "function_call",
                "tool_search_call", "function_call_output", "custom_tool_call",
                "custom_tool_call_output", "tool_search_output", "web_search_call",
                "image_generation_call", "compaction", "compaction_trigger",
                "context_compaction", "other",
            ]
        )
        switch type {
        case "message":
            _ = try item.requireArray("content")
            _ = try item.requireString("role")
        case "agent_message":
            _ = try item.requireString("author")
            _ = try item.requireArray("content")
            _ = try item.requireString("recipient")
        case "reasoning":
            _ = try item.requireArray("summary")
        case "local_shell_call":
            _ = try item.requireObject("action")
            _ = try item.requireEnum(
                "status",
                allowed: ["completed", "in_progress", "incomplete"]
            )
        case "function_call":
            for key in ["arguments", "call_id", "name"] {
                _ = try item.requireString(key)
            }
        case "tool_search_call":
            _ = try item.requireValue("arguments")
            _ = try item.requireString("execution")
        case "function_call_output":
            _ = try item.requireString("call_id")
            _ = try item.requireValue("output")
        case "custom_tool_call":
            for key in ["call_id", "input", "name"] {
                _ = try item.requireString(key)
            }
        case "custom_tool_call_output":
            _ = try item.requireString("call_id")
            _ = try item.requireValue("output")
        case "tool_search_output":
            _ = try item.requireString("execution")
            _ = try item.requireString("status")
            _ = try item.requireArray("tools")
        case "web_search_call", "compaction_trigger", "context_compaction", "other":
            break
        case "image_generation_call":
            _ = try item.requireString("result")
            _ = try item.requireString("status")
        case "compaction":
            _ = try item.requireString("encrypted_content")
        default:
            preconditionFailure("Response item discriminator was validated above.")
        }
    }

    private func validateAppList(_ values: [AppServerJSONValue]) throws {
        for value in values {
            let app = try PayloadObject.object(value, path: "data[]")
            _ = try app.requireNonEmptyString("id")
            _ = try app.requireString("name")
        }
    }

    private func validateExternalImportResults(_ values: [AppServerJSONValue]) throws {
        let itemTypes: Set<String> = [
            "AGENTS_MD", "CONFIG", "SKILLS", "PLUGINS", "MCP_SERVER_CONFIG", "SUBAGENTS",
            "HOOKS", "COMMANDS", "SESSIONS",
        ]
        for value in values {
            let result = try PayloadObject.object(value, path: "itemTypeResults[]")
            _ = try result.requireEnum("itemType", allowed: itemTypes)
            for failureValue in try result.requireArray("failures") {
                let failure = try PayloadObject.object(
                    failureValue,
                    path: "itemTypeResults[].failures[]"
                )
                _ = try failure.requireString("failureStage")
                _ = try failure.requireEnum("itemType", allowed: itemTypes)
                _ = try failure.requireString("message")
            }
            for successValue in try result.requireArray("successes") {
                let success = try PayloadObject.object(
                    successValue,
                    path: "itemTypeResults[].successes[]"
                )
                _ = try success.requireEnum("itemType", allowed: itemTypes)
            }
        }
    }

    private func decodeTurn(
        from object: PayloadObject,
        data: Data,
        lifecycle: TurnLifecycle
    ) throws -> AppServerAPI.Turn.Payload {
        let turnObject = try object.requireObject("turn")
        try validateTurn(turnObject, lifecycle: lifecycle)
        let turnData = try JSONEncoder().encode(try object.requireValue("turn"))
        return try decoder.decode(AppServerAPI.Turn.Payload.self, from: turnData)
    }

    private func decodeTurnDiagnostic(from object: PayloadObject) throws -> CodexTurnDiagnostic {
        let errorData = try JSONEncoder().encode(try object.requireValue("error"))
        let error = try decoder.decode(AppServerAPI.Turn.Error.self, from: errorData)
        return .init(
            error: CodexAppServer.turnError(from: error),
            willRetry: try object.requireBool("willRetry")
        )
    }

    private enum TurnLifecycle {
        case started
        case completed
    }

    private func validateTurn(_ turn: PayloadObject, lifecycle: TurnLifecycle) throws {
        _ = try turn.requireNonEmptyString("id")
        let status = try turn.requireNonEmptyString("status")
        let items = try turn.requireArray("items")
        for item in items {
            guard case .object(let values) = item else {
                throw NotificationContractError.expectedObject("turn.items[]")
            }
            try validateThreadItem(.init(values: values), lifecycle: nil)
        }
        if case .started = lifecycle, CodexTurnStatus(rawValue: status) != .inProgress {
            throw NotificationContractError.illegalValue(
                key: "turn.status",
                value: status
            )
        }
    }

    private func decodeItem(
        from object: PayloadObject,
        lifecycle: ItemLifecycle
    ) throws -> CodexItemReducer.Mutation {
        let itemObject = try object.requireObject("item")
        let validationLifecycle: TurnLifecycle? = switch lifecycle {
        case .started: .started
        case .completed: .completed
        }
        try validateThreadItem(itemObject, lifecycle: validationLifecycle)
        let itemData = try JSONEncoder().encode(try object.requireValue("item"))
        let rawItem = try decoder.decode(RawThreadItem.self, from: itemData)
        let item: CodexThreadItem?
        switch lifecycle {
        case .started(let date):
            item = rawItem.makeThreadItem(startedAt: date, completedAt: nil)
        case .completed(let date):
            item = rawItem.makeThreadItem(startedAt: nil, completedAt: date)
        }
        guard let item else {
            throw NotificationContractError.missingRequired("item.id")
        }
        return switch lifecycle {
        case .started: .started(item)
        case .completed: .completed(item)
        }
    }

    private func validateThreadItem(
        _ item: PayloadObject,
        lifecycle: TurnLifecycle?
    ) throws {
        _ = try item.requireNonEmptyString("id")
        let type = try item.requireNonEmptyString("type")
        let requiredFields: [(String, PayloadObject.ValueKind)]
        let statusValues: Set<String>?
        switch type {
        case "userMessage":
            requiredFields = [("content", .array)]
            statusValues = nil
        case "hookPrompt":
            requiredFields = [("fragments", .array)]
            statusValues = nil
        case "agentMessage", "plan":
            requiredFields = [("text", .string)]
            statusValues = nil
        case "reasoning", "contextCompaction":
            requiredFields = []
            statusValues = nil
        case "commandExecution":
            requiredFields = [
                ("command", .string),
                ("commandActions", .array),
                ("cwd", .string),
                ("status", .string),
            ]
            statusValues = ["inProgress", "completed", "failed", "declined"]
        case "fileChange":
            requiredFields = [("changes", .any), ("status", .string)]
            statusValues = ["inProgress", "completed", "failed", "declined"]
        case "mcpToolCall":
            requiredFields = [
                ("arguments", .any),
                ("server", .string),
                ("status", .string),
                ("tool", .string),
            ]
            statusValues = ["inProgress", "completed", "failed"]
        case "dynamicToolCall":
            requiredFields = [
                ("arguments", .any),
                ("status", .string),
                ("tool", .string),
            ]
            statusValues = ["inProgress", "completed", "failed"]
        case "collabAgentToolCall":
            requiredFields = [
                ("agentsStates", .object),
                ("receiverThreadIds", .array),
                ("senderThreadId", .string),
                ("status", .string),
                ("tool", .string),
            ]
            statusValues = ["inProgress", "completed", "failed"]
        case "subAgentActivity":
            requiredFields = [
                ("agentPath", .string),
                ("agentThreadId", .string),
                ("kind", .string),
            ]
            statusValues = nil
        case "webSearch":
            requiredFields = [("query", .string)]
            statusValues = nil
        case "imageView":
            requiredFields = [("path", .string)]
            statusValues = nil
        case "sleep":
            requiredFields = [("durationMs", .int)]
            statusValues = nil
        case "imageGeneration":
            requiredFields = [("result", .string), ("status", .string)]
            statusValues = nil
        case "enteredReviewMode", "exitedReviewMode":
            requiredFields = [("review", .string)]
            statusValues = nil
        default:
            return
        }
        for (key, kind) in requiredFields {
            try item.require(key, kind: kind)
        }
        if type == "fileChange" {
            try validateFileChanges(item.requireArray("changes"))
        }
        guard let statusValues else {
            return
        }
        let status = try item.requireEnum("status", allowed: statusValues)
        switch lifecycle {
        case .started where status != "inProgress":
            throw NotificationContractError.illegalValue(key: "item.status", value: status)
        case .completed where status == "inProgress":
            throw NotificationContractError.illegalValue(key: "item.status", value: status)
        case nil, .started, .completed:
            break
        }
    }

    private func validateThread(_ thread: PayloadObject) throws {
        _ = try thread.requireNonEmptyString("id")
        for key in ["cliVersion", "cwd", "modelProvider", "preview", "sessionId"] {
            _ = try thread.requireString(key)
        }
        _ = try thread.requireInt64("createdAt")
        _ = try thread.requireInt64("updatedAt")
        _ = try thread.requireBool("ephemeral")
        _ = try thread.requireValue("source")
        _ = try decodeThreadStatus(from: thread.requireObject("status"))
        let turns = try thread.requireArray("turns")
        for turn in turns {
            guard case .object(let values) = turn else {
                throw NotificationContractError.expectedObject("thread.turns[]")
            }
            try validateTurn(.init(values: values), lifecycle: .completed)
        }
    }

    private func decodeThreadStatus(from status: PayloadObject) throws -> CodexThreadStatus {
        let type = try status.requireNonEmptyString("type")
        let activeFlags: [String]?
        if type == "active" {
            activeFlags = try status.requireStringArray("activeFlags")
        } else {
            activeFlags = nil
        }
        return .init(type: type, activeFlags: activeFlags)
    }

    private func decodeTokenUsage(from tokenUsage: PayloadObject) throws -> CodexTokenUsage {
        let last = try tokenUsage.requireObject("last")
        let total = try tokenUsage.requireObject("total")
        try validateTokenUsageBreakdown(last)
        try validateTokenUsageBreakdown(total)
        return .init(
            inputTokens: try total.requireInt("inputTokens"),
            outputTokens: try total.requireInt("outputTokens"),
            totalTokens: try total.requireInt("totalTokens"),
            cachedInputTokens: try total.requireInt("cachedInputTokens"),
            reasoningOutputTokens: try total.requireInt("reasoningOutputTokens"),
            modelContextWindow: try tokenUsage.optionalInt("modelContextWindow")
        )
    }

    private func validateTokenUsageBreakdown(_ usage: PayloadObject) throws {
        for key in [
            "cachedInputTokens",
            "inputTokens",
            "outputTokens",
            "reasoningOutputTokens",
            "totalTokens",
        ] {
            _ = try usage.requireInt(key)
        }
    }

    private func decodeAccountUpdate(from object: PayloadObject) throws -> AccountUpdate {
        let authMode = try object.optionalEnum(
            "authMode",
            allowed: Set(AccountUpdate.AuthMode.allRawValues)
        ).flatMap(AccountUpdate.AuthMode.init(rawValue:))
        let planType = try object.optionalEnum(
            "planType",
            allowed: Set(AccountUpdate.PlanType.allRawValues)
        ).flatMap(AccountUpdate.PlanType.init(rawValue:))
        return .init(authMode: authMode, planType: planType)
    }

    private func decodeRateLimitSnapshot(
        from object: PayloadObject
    ) throws -> AppServerAPI.Account.RateLimits.Snapshot {
        _ = try object.optionalString("limitId")
        _ = try object.optionalString("limitName")
        if let primary = try object.optionalObject("primary") {
            try validateRateLimitWindow(primary)
        }
        if let secondary = try object.optionalObject("secondary") {
            try validateRateLimitWindow(secondary)
        }
        if let credits = try object.optionalObject("credits") {
            _ = try credits.requireBool("hasCredits")
            _ = try credits.requireBool("unlimited")
            _ = try credits.optionalString("balance")
        }
        if let limit = try object.optionalObject("individualLimit") {
            _ = try limit.requireString("limit")
            _ = try limit.requireInt("remainingPercent")
            _ = try limit.requireInt64("resetsAt")
            _ = try limit.requireString("used")
        }
        _ = try object.optionalEnum(
            "planType",
            allowed: Set(AccountUpdate.PlanType.allRawValues)
        )
        _ = try object.optionalEnum(
            "rateLimitReachedType",
            allowed: [
                "rate_limit_reached",
                "workspace_owner_credits_depleted",
                "workspace_member_credits_depleted",
                "workspace_owner_usage_limit_reached",
                "workspace_member_usage_limit_reached",
            ]
        )
        let data = try JSONEncoder().encode(AppServerJSONValue.object(object.values))
        return try decoder.decode(AppServerAPI.Account.RateLimits.Snapshot.self, from: data)
    }

    private func validateRateLimitWindow(_ window: PayloadObject) throws {
        _ = try window.requireInt("usedPercent")
        _ = try window.optionalInt("windowDurationMins")
        _ = try window.optionalInt64("resetsAt")
    }

    private func validateAutoApprovalReview(
        _ object: PayloadObject,
        completed: Bool
    ) throws {
        try validateAutoApprovalAction(object.requireObject("action"))
        let review = try object.requireObject("review")
        _ = try review.requireEnum(
            "status",
            allowed: ["inProgress", "approved", "denied", "timedOut", "aborted"]
        )
        _ = try object.requireNonEmptyString("reviewId")
        _ = try object.requireInt64("startedAtMs")
        if completed {
            _ = try object.requireInt64("completedAtMs")
            _ = try object.requireEnum("decisionSource", allowed: ["agent"])
        }
    }

    private func validateAutoApprovalAction(_ action: PayloadObject) throws {
        let type = try action.requireEnum(
            "type",
            allowed: [
                "command", "execve", "applyPatch", "networkAccess", "mcpToolCall",
                "requestPermissions",
            ]
        )
        switch type {
        case "command":
            _ = try action.requireString("command")
            _ = try action.requireString("cwd")
            _ = try action.requireEnum("source", allowed: ["shell", "unifiedExec"])
        case "execve":
            _ = try action.requireStringArray("argv")
            _ = try action.requireString("cwd")
            _ = try action.requireString("program")
            _ = try action.requireEnum("source", allowed: ["shell", "unifiedExec"])
        case "applyPatch":
            _ = try action.requireString("cwd")
            _ = try action.requireStringArray("files")
        case "networkAccess":
            _ = try action.requireString("host")
            _ = try action.requireInt("port")
            _ = try action.requireEnum(
                "protocol",
                allowed: ["http", "https", "socks5Tcp", "socks5Udp"]
            )
            _ = try action.requireString("target")
        case "mcpToolCall":
            _ = try action.requireString("server")
            _ = try action.requireString("toolName")
        case "requestPermissions":
            _ = try action.requireObject("permissions")
        default:
            preconditionFailure("Auto-approval action discriminator was validated above.")
        }
    }

    private static func context(from object: PayloadObject) -> Context {
        let threadID = object.string("threadId")
            .flatMap(Self.nonEmpty)
            .map { CodexThreadID(rawValue: $0) }
        let turnID = object.string("turnId")
            .flatMap(Self.nonEmpty)
            .map { CodexTurnID(rawValue: $0) }
        return .init(threadID: threadID, turnID: turnID)
    }

    private static func bestEffortContext(from data: Data) -> Context {
        guard let value = try? JSONDecoder().decode(AppServerJSONValue.self, from: data),
              case .object(let values) = value
        else {
            return .init()
        }
        return context(from: .init(values: values))
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func date(millisecondsSince1970 milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

private extension AppServerNotificationDecoder.AccountUpdate.AuthMode {
    static var allRawValues: [String] {
        [
            apiKey.rawValue,
            chatGPT.rawValue,
            chatGPTAuthTokens.rawValue,
            headers.rawValue,
            agentIdentity.rawValue,
            personalAccessToken.rawValue,
            bedrockAPIKey.rawValue,
        ]
    }
}

private extension AppServerNotificationDecoder.AccountUpdate.PlanType {
    static var allRawValues: [String] {
        [
            free.rawValue,
            go.rawValue,
            plus.rawValue,
            pro.rawValue,
            prolite.rawValue,
            team.rawValue,
            selfServeBusinessUsageBased.rawValue,
            business.rawValue,
            enterpriseCBPUsageBased.rawValue,
            enterprise.rawValue,
            edu.rawValue,
            unknown.rawValue,
        ]
    }
}

private struct PayloadObject {
    enum ValueKind {
        case any
        case string
        case int
        case bool
        case array
        case object
    }

    var values: [String: AppServerJSONValue]

    init(values: [String: AppServerJSONValue]) {
        self.values = values
    }

    init(data: Data, decoder: JSONDecoder) throws {
        let value = try decoder.decode(AppServerJSONValue.self, from: data)
        guard case .object(let values) = value else {
            throw NotificationContractError.expectedObject("params")
        }
        self.values = values
    }

    static func object(_ value: AppServerJSONValue, path: String) throws -> PayloadObject {
        guard case .object(let values) = value else {
            throw NotificationContractError.expectedObject(path)
        }
        return .init(values: values)
    }

    func requireValue(_ key: String) throws -> AppServerJSONValue {
        guard let value = values[key] else {
            throw NotificationContractError.missingRequired(key)
        }
        return value
    }

    func require(_ key: String, kind: ValueKind) throws {
        let value = try requireValue(key)
        let matches = switch (kind, value) {
        case (.any, _),
             (.string, .string),
             (.int, .int),
             (.bool, .bool),
             (.array, .array),
             (.object, .object):
            true
        default:
            false
        }
        guard matches else {
            throw NotificationContractError.typeMismatch(key)
        }
    }

    func requireString(_ key: String) throws -> String {
        guard case .string(let value) = try requireValue(key) else {
            throw NotificationContractError.typeMismatch(key)
        }
        return value
    }

    func requireNonEmptyString(_ key: String) throws -> String {
        let value = try requireString(key)
        guard value.isEmpty == false else {
            throw NotificationContractError.missingRequired(key)
        }
        return value
    }

    func requireNonWhitespaceString(_ key: String) throws -> String {
        let value = try requireNonEmptyString(key)
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw NotificationContractError.missingRequired(key)
        }
        return value
    }

    func requireInt(_ key: String) throws -> Int {
        guard case .int(let value) = try requireValue(key) else {
            throw NotificationContractError.typeMismatch(key)
        }
        return value
    }

    func requireInt64(_ key: String) throws -> Int64 {
        let value = try requireInt(key)
        guard let result = Int64(exactly: value) else {
            throw NotificationContractError.typeMismatch(key)
        }
        return result
    }

    func requireBool(_ key: String) throws -> Bool {
        guard case .bool(let value) = try requireValue(key) else {
            throw NotificationContractError.typeMismatch(key)
        }
        return value
    }

    func requireArray(_ key: String) throws -> [AppServerJSONValue] {
        guard case .array(let value) = try requireValue(key) else {
            throw NotificationContractError.typeMismatch(key)
        }
        return value
    }

    func requireStringArray(_ key: String) throws -> [String] {
        try requireArray(key).map { value in
            guard case .string(let string) = value else {
                throw NotificationContractError.typeMismatch("\(key)[]")
            }
            return string
        }
    }

    func requireObject(_ key: String) throws -> PayloadObject {
        guard case .object(let value) = try requireValue(key) else {
            throw NotificationContractError.typeMismatch(key)
        }
        return .init(values: value)
    }

    func requireEnum(_ key: String, allowed: Set<String>) throws -> String {
        let value = try requireString(key)
        guard allowed.contains(value) else {
            throw NotificationContractError.illegalValue(key: key, value: value)
        }
        return value
    }

    func requireRequestID(_ key: String) throws -> CodexServerRequestID {
        let value = try requireValue(key)
        switch value {
        case .int(let value):
            return .integer(Int64(value))
        case .string(let value):
            return .string(value)
        default:
            throw NotificationContractError.typeMismatch(key)
        }
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key] else {
            return nil
        }
        switch value {
        case .null:
            return nil
        case .string(let string):
            return string
        default:
            throw NotificationContractError.typeMismatch(key)
        }
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = values[key] else {
            return nil
        }
        switch value {
        case .null:
            return nil
        case .int(let int):
            return int
        default:
            throw NotificationContractError.typeMismatch(key)
        }
    }

    func optionalInt64(_ key: String) throws -> Int64? {
        guard let value = try optionalInt(key) else {
            return nil
        }
        guard let result = Int64(exactly: value) else {
            throw NotificationContractError.typeMismatch(key)
        }
        return result
    }

    func optionalObject(_ key: String) throws -> PayloadObject? {
        guard let value = values[key] else {
            return nil
        }
        switch value {
        case .null:
            return nil
        case .object(let object):
            return .init(values: object)
        default:
            throw NotificationContractError.typeMismatch(key)
        }
    }

    func optionalEnum(_ key: String, allowed: Set<String>) throws -> String? {
        guard let value = try optionalString(key) else {
            return nil
        }
        guard allowed.contains(value) else {
            throw NotificationContractError.illegalValue(key: key, value: value)
        }
        return value
    }

    func string(_ key: String) -> String? {
        guard case .string(let value) = values[key] else {
            return nil
        }
        return value
    }

    func requiredThreadID(key: String = "threadId") throws -> CodexThreadID {
        .init(rawValue: try requireNonEmptyString(key))
    }

    func requiredTurnID(key: String = "turnId") throws -> CodexTurnID {
        .init(rawValue: try requireNonEmptyString(key))
    }

    func threadTurnContext() throws -> AppServerNotificationDecoder.Context {
        .init(threadID: try requiredThreadID(), turnID: try requiredTurnID())
    }
}

private enum NotificationContractError: LocalizedError {
    case missingRequired(String)
    case typeMismatch(String)
    case expectedObject(String)
    case illegalValue(key: String, value: String)

    var errorDescription: String? {
        switch self {
        case .missingRequired(let key):
            "Current-v2 notification is missing required field \(key)."
        case .typeMismatch(let key):
            "Current-v2 notification field \(key) has the wrong type."
        case .expectedObject(let path):
            "Current-v2 notification value \(path) must be an object."
        case .illegalValue(let key, let value):
            "Current-v2 notification field \(key) has illegal value \(value)."
        }
    }
}
