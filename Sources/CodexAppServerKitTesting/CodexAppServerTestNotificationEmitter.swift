import CodexAppServerKit
import Foundation

public enum CodexAppServerTestError: Error, Equatable, LocalizedError, Sendable {
    case invalidFixture(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFixture(let message):
            "Invalid Codex app-server test fixture: \(message)"
        }
    }
}

public struct CodexAppServerTestItem: Equatable, Sendable {
    public enum CommandSource: String, Equatable, Sendable {
        case agent
        case userShell = "user_shell"
        case unifiedExecStartup = "unified_exec_startup"
        case unifiedExecInteraction = "unified_exec_interaction"
    }

    public enum CommandStatus: String, Equatable, Sendable {
        case inProgress
        case completed
        case failed
        case declined
    }

    public enum PatchStatus: String, Equatable, Sendable {
        case inProgress
        case completed
        case failed
        case declined
    }

    public enum MCPStatus: String, Equatable, Sendable {
        case inProgress
        case completed
        case failed
    }

    public let domainProjection: CodexThreadItem
    package let wireValue: CodexJSONValue

    private init(domainProjection: CodexThreadItem, fields: [String: CodexJSONValue]) {
        self.domainProjection = domainProjection
        self.wireValue = .object(fields)
    }

    public static func userMessage(id: String, text: String) throws -> Self {
        try validateID(id)
        var fields = baseFields(id: id, type: "userMessage")
        fields["content"] = .array([
            .object([
                "type": .string("text"),
                "text": .string(text),
                "textElements": .array([]),
            ])
        ])
        return Self(
            domainProjection: .init(
                id: id,
                kind: .userMessage,
                content: .message(.init(id: id, role: .user, text: text))
            ),
            fields: fields
        )
    }

    public static func agentMessage(
        id: String,
        text: String,
        phase: CodexMessagePhase? = nil
    ) throws -> Self {
        try validateID(id)
        var fields = baseFields(id: id, type: "agentMessage")
        fields["text"] = .string(text)
        if let phase {
            fields["phase"] = .string(phase.rawValue)
        }
        return Self(
            domainProjection: .init(
                id: id,
                kind: .agentMessage,
                content: .message(.init(id: id, role: .assistant, phase: phase, text: text))
            ),
            fields: fields
        )
    }

    public static func plan(id: String, text: String) throws -> Self {
        try validateID(id)
        var fields = baseFields(id: id, type: "plan")
        fields["text"] = .string(text)
        return Self(
            domainProjection: .init(id: id, kind: .plan, content: .plan(text)),
            fields: fields
        )
    }

    public static func reasoning(
        id: String,
        summary: [String] = [],
        content: [String] = []
    ) throws -> Self {
        try validateID(id)
        var fields = baseFields(id: id, type: "reasoning")
        fields["summary"] = .array(summary.map(CodexJSONValue.string))
        fields["content"] = .array(content.map(CodexJSONValue.string))
        return Self(
            domainProjection: .init(
                id: id,
                kind: .reasoning,
                content: .reasoning(.init(summary: summary, content: content))
            ),
            fields: fields
        )
    }

    public static func commandExecution(
        id: String,
        command: String,
        cwd: URL,
        processID: String? = nil,
        source: CommandSource = .agent,
        status: CommandStatus,
        aggregatedOutput: String? = nil,
        exitCode: Int32? = nil,
        duration: Duration? = nil
    ) throws -> Self {
        try validateID(id)
        try validateFileURL(cwd, field: "cwd")
        guard command.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("command must not be empty")
        }
        var fields = baseFields(id: id, type: "commandExecution")
        fields["command"] = .string(command)
        fields["cwd"] = .string(cwd.path)
        fields["commandActions"] = .array([])
        fields["source"] = .string(source.rawValue)
        fields["status"] = .string(status.rawValue)
        if let processID { fields["processId"] = .string(processID) }
        if let aggregatedOutput { fields["aggregatedOutput"] = .string(aggregatedOutput) }
        if let exitCode { fields["exitCode"] = .int(Int(exitCode)) }
        if let milliseconds = duration?.millisecondsForTesting {
            fields["durationMs"] = .int(milliseconds)
        }
        return Self(
            domainProjection: .init(
                id: id,
                kind: .commandExecution,
                content: .command(.init(
                    command: command,
                    cwd: cwd.path,
                    output: aggregatedOutput,
                    exitCode: exitCode.map(Int.init),
                    status: status.turnStatus,
                    duration: duration,
                    processID: processID,
                    source: .init(rawValue: source.rawValue)
                ))
            ),
            fields: fields
        )
    }

    public static func fileChange(
        id: String,
        changes: [CodexFileUpdateChange],
        status: PatchStatus
    ) throws -> Self {
        try validateID(id)
        guard changes.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("file changes must not be empty")
        }
        var fields = baseFields(id: id, type: "fileChange")
        fields["status"] = .string(status.rawValue)
        fields["changes"] = .array(changes.map(\.wireValueForTesting))
        return Self(
            domainProjection: .init(
                id: id,
                kind: .fileChange,
                content: .fileChange(.init(
                    path: changes.first?.path,
                    output: changes.map(\.diff).joined(separator: "\n"),
                    status: status.turnStatus
                ))
            ),
            fields: fields
        )
    }

    public static func mcpToolCall(
        id: String,
        server: String,
        tool: String,
        status: MCPStatus,
        arguments: CodexJSONValue = .object([:]),
        resultContent: [CodexJSONValue]? = nil,
        structuredContent: CodexJSONValue? = nil,
        resultMetadata: CodexJSONValue? = nil,
        errorMessage: String? = nil,
        duration: Duration? = nil
    ) throws -> Self {
        try validateID(id)
        guard server.isEmpty == false, tool.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("MCP server and tool must not be empty")
        }
        var fields = baseFields(id: id, type: "mcpToolCall")
        fields["server"] = .string(server)
        fields["tool"] = .string(tool)
        fields["status"] = .string(status.rawValue)
        fields["arguments"] = arguments
        let result: CodexJSONValue?
        if resultContent != nil || structuredContent != nil || resultMetadata != nil {
            result = .object([
                "content": .array(resultContent ?? []),
                "structuredContent": structuredContent ?? .null,
                "_meta": resultMetadata ?? .null,
            ])
            fields["result"] = result
        } else {
            result = nil
        }
        if let errorMessage {
            fields["error"] = .object(["message": .string(errorMessage)])
        }
        if let milliseconds = duration?.millisecondsForTesting {
            fields["durationMs"] = .int(milliseconds)
        }
        return Self(
            domainProjection: .init(
                id: id,
                kind: .mcpToolCall,
                content: .toolCall(.init(
                    server: server,
                    name: tool,
                    arguments: arguments.jsonStringForTesting,
                    result: result?.displayTextForTesting,
                    error: errorMessage,
                    status: status.turnStatus
                ))
            ),
            fields: fields
        )
    }

    public static func enteredReviewMode(id: String, review: String) throws -> Self {
        try reviewMarker(id: id, review: review, kind: .enteredReviewMode)
    }

    public static func exitedReviewMode(id: String, review: String) throws -> Self {
        try reviewMarker(id: id, review: review, kind: .exitedReviewMode)
    }

    public static func contextCompaction(id: String) throws -> Self {
        try validateID(id)
        return Self(
            domainProjection: .init(id: id, kind: .contextCompaction, content: .contextCompaction(nil)),
            fields: baseFields(id: id, type: "contextCompaction")
        )
    }

    private static func reviewMarker(
        id: String,
        review: String,
        kind: CodexThreadItem.Kind
    ) throws -> Self {
        try validateID(id)
        var fields = baseFields(id: id, type: kind.rawValue)
        fields["review"] = .string(review)
        return Self(
            domainProjection: .init(id: id, kind: kind, content: .log(review)),
            fields: fields
        )
    }

    private static func baseFields(id: String, type: String) -> [String: CodexJSONValue] {
        ["id": .string(id), "type": .string(type)]
    }

    private static func validateID(_ id: String) throws {
        guard id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("item id must not be empty")
        }
    }

    private static func validateFileURL(_ url: URL, field: String) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw CodexAppServerTestError.invalidFixture("\(field) must be an absolute file URL")
        }
    }
}

public enum CodexAppServerTestAuthMode: Equatable, Sendable {
    case apiKey
    case chatGPT
    case chatGPTAuthTokens
    case headers
    case agentIdentity
    case personalAccessToken
    case bedrockAPIKey

    package var wireValue: String {
        switch self {
        case .apiKey: "apikey"
        case .chatGPT: "chatgpt"
        case .chatGPTAuthTokens: "chatGPTAuthTokens"
        case .headers: "headers"
        case .agentIdentity: "agentIdentity"
        case .personalAccessToken: "personalAccessToken"
        case .bedrockAPIKey: "bedrockApiKey"
        }
    }
}

public enum CodexAppServerTestPlanType: Equatable, Sendable {
    case free
    case go
    case plus
    case pro
    case proLite
    case team
    case selfServeBusinessUsageBased
    case business
    case enterpriseCBPUsageBased
    case enterprise
    case edu
    case unknown

    package var wireValue: String {
        switch self {
        case .free: "free"
        case .go: "go"
        case .plus: "plus"
        case .pro: "pro"
        case .proLite: "prolite"
        case .team: "team"
        case .selfServeBusinessUsageBased: "self_serve_business_usage_based"
        case .business: "business"
        case .enterpriseCBPUsageBased: "enterprise_cbp_usage_based"
        case .enterprise: "enterprise"
        case .edu: "edu"
        case .unknown: "unknown"
        }
    }
}

public struct CodexAppServerTestAccountUpdate: Equatable, Sendable {
    public var authMode: CodexAppServerTestAuthMode?
    public var planType: CodexAppServerTestPlanType?

    public init(
        authMode: CodexAppServerTestAuthMode?,
        planType: CodexAppServerTestPlanType?
    ) {
        self.authMode = authMode
        self.planType = planType
    }
}

public struct CodexAppServerTestRateLimitSnapshot: Equatable, Sendable {
    public enum ReachedType: Equatable, Sendable {
        case rateLimitReached
        case workspaceOwnerCreditsDepleted
        case workspaceMemberCreditsDepleted
        case workspaceOwnerUsageLimitReached
        case workspaceMemberUsageLimitReached

        fileprivate var wireValue: String {
            switch self {
            case .rateLimitReached: "rate_limit_reached"
            case .workspaceOwnerCreditsDepleted: "workspace_owner_credits_depleted"
            case .workspaceMemberCreditsDepleted: "workspace_member_credits_depleted"
            case .workspaceOwnerUsageLimitReached: "workspace_owner_usage_limit_reached"
            case .workspaceMemberUsageLimitReached: "workspace_member_usage_limit_reached"
            }
        }
    }

    public struct Window: Equatable, Sendable {
        public var usedPercent: Int32
        public var windowDurationMinutes: Int64?
        public var resetsAtUnixSeconds: Int64?

        public init(
            usedPercent: Int32,
            windowDurationMinutes: Int64?,
            resetsAtUnixSeconds: Int64?
        ) {
            self.usedPercent = usedPercent
            self.windowDurationMinutes = windowDurationMinutes
            self.resetsAtUnixSeconds = resetsAtUnixSeconds
        }

        fileprivate var wireValue: CodexJSONValue {
            .object([
                "usedPercent": .int(Int(usedPercent)),
                "windowDurationMins": windowDurationMinutes.map { .int(Int($0)) } ?? .null,
                "resetsAt": resetsAtUnixSeconds.map { .int(Int($0)) } ?? .null,
            ])
        }
    }

    public struct Credits: Equatable, Sendable {
        public var hasCredits: Bool
        public var unlimited: Bool
        public var balance: String?

        public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
            self.hasCredits = hasCredits
            self.unlimited = unlimited
            self.balance = balance
        }

        fileprivate var wireValue: CodexJSONValue {
            .object([
                "hasCredits": .bool(hasCredits),
                "unlimited": .bool(unlimited),
                "balance": balance.map(CodexJSONValue.string) ?? .null,
            ])
        }
    }

    public struct SpendControl: Equatable, Sendable {
        public var limit: String
        public var used: String
        public var remainingPercent: Int32
        public var resetsAtUnixSeconds: Int64

        public init(
            limit: String,
            used: String,
            remainingPercent: Int32,
            resetsAtUnixSeconds: Int64
        ) throws {
            guard limit.isEmpty == false, used.isEmpty == false else {
                throw CodexAppServerTestError.invalidFixture(
                    "rate-limit spend-control values must not be empty"
                )
            }
            self.limit = limit
            self.used = used
            self.remainingPercent = remainingPercent
            self.resetsAtUnixSeconds = resetsAtUnixSeconds
        }

        fileprivate var wireValue: CodexJSONValue {
            .object([
                "limit": .string(limit),
                "used": .string(used),
                "remainingPercent": .int(Int(remainingPercent)),
                "resetsAt": .int(Int(resetsAtUnixSeconds)),
            ])
        }
    }

    public var limitID: String?
    public var limitName: String?
    public var primary: Window?
    public var secondary: Window?
    public var credits: Credits?
    public var individualLimit: SpendControl?
    public var planType: CodexAppServerTestPlanType?
    public var reachedType: ReachedType?

    public init(
        limitID: String?,
        limitName: String?,
        primary: Window?,
        secondary: Window?,
        credits: Credits?,
        individualLimit: SpendControl?,
        planType: CodexAppServerTestPlanType?,
        reachedType: ReachedType?
    ) throws {
        if let limitID, limitID.isEmpty {
            throw CodexAppServerTestError.invalidFixture("rate-limit id must not be empty")
        }
        self.limitID = limitID
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.individualLimit = individualLimit
        self.planType = planType
        self.reachedType = reachedType
    }

    package var wireValue: CodexJSONValue {
        .object([
            "limitId": limitID.map(CodexJSONValue.string) ?? .null,
            "limitName": limitName.map(CodexJSONValue.string) ?? .null,
            "primary": primary?.wireValue ?? .null,
            "secondary": secondary?.wireValue ?? .null,
            "credits": credits?.wireValue ?? .null,
            "individualLimit": individualLimit?.wireValue ?? .null,
            "planType": planType.map { .string($0.wireValue) } ?? .null,
            "rateLimitReachedType": reachedType.map { .string($0.wireValue) } ?? .null,
        ])
    }
}

public struct CodexAppServerTestRateLimitsUpdate: Equatable, Sendable {
    public var snapshot: CodexAppServerTestRateLimitSnapshot

    public init(snapshot: CodexAppServerTestRateLimitSnapshot) {
        self.snapshot = snapshot
    }
}

public enum CodexAppServerTestLoginCompletion: Equatable, Sendable {
    case succeeded
    case failed(message: String?)
}

public actor CodexAppServerTestNotificationEmitter {
    private var nextFixtureTimestampMilliseconds = 4_102_444_800_000
    private let transport: CodexAppServerTestTransport

    public init(transport: CodexAppServerTestTransport) {
        self.transport = transport
    }

    public func emitItemStarted(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        item: CodexAppServerTestItem
    ) async throws {
        try await emitItem(
            method: "item/started",
            timestampKey: "startedAtMs",
            threadID: threadID,
            turnID: turnID,
            item: item
        )
    }

    public func emitItemCompleted(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        item: CodexAppServerTestItem
    ) async throws {
        try await emitItem(
            method: "item/completed",
            timestampKey: "completedAtMs",
            threadID: threadID,
            turnID: turnID,
            item: item
        )
    }

    public func emitAgentMessageDelta(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        itemID: String,
        delta: String
    ) async throws {
        try await emitDelta(
            method: "item/agentMessage/delta",
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            delta: delta,
            additionalFields: ["phase": .string("final_answer")]
        )
    }

    public func emitPlanDelta(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        itemID: String,
        delta: String
    ) async throws {
        try await emitDelta(
            method: "item/plan/delta",
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            delta: delta
        )
    }

    public func emitReasoningSummaryTextDelta(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        itemID: String,
        summaryIndex: Int64,
        delta: String
    ) async throws {
        try await emitDelta(
            method: "item/reasoning/summaryTextDelta",
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            delta: delta,
            additionalFields: ["summaryIndex": .int(Int(summaryIndex))]
        )
    }

    public func emitReasoningSummaryPartAdded(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        itemID: String,
        summaryIndex: Int64
    ) async throws {
        try validateContext(threadID: threadID, turnID: turnID, itemID: itemID)
        guard summaryIndex >= 0 else {
            throw CodexAppServerTestError.invalidFixture("reasoning summary index must not be negative")
        }
        try await transport.emitServerNotification(
            method: "item/reasoning/summaryPartAdded",
            params: CodexJSONValue.object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "itemId": .string(itemID),
                "summaryIndex": .int(Int(summaryIndex)),
            ])
        )
    }

    public func emitReasoningTextDelta(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        itemID: String,
        contentIndex: Int64,
        delta: String
    ) async throws {
        try await emitDelta(
            method: "item/reasoning/textDelta",
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            delta: delta,
            additionalFields: ["contentIndex": .int(Int(contentIndex))]
        )
    }

    public func emitCommandExecutionOutputDelta(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        itemID: String,
        delta: String
    ) async throws {
        try await emitDelta(
            method: "item/commandExecution/outputDelta",
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            delta: delta
        )
    }

    public func emitMCPToolCallProgress(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        itemID: String,
        message: String
    ) async throws {
        try validateContext(threadID: threadID, turnID: turnID, itemID: itemID)
        guard message.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("MCP progress message must not be empty")
        }
        try await transport.emitServerNotification(
            method: "item/mcpToolCall/progress",
            params: CodexJSONValue.object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "itemId": .string(itemID),
                "message": .string(message),
            ])
        )
    }

    public func emitFileChangePatchUpdated(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        itemID: String,
        changes: [CodexFileUpdateChange]
    ) async throws {
        try validateContext(threadID: threadID, turnID: turnID, itemID: itemID)
        guard changes.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("file changes must not be empty")
        }
        try await transport.emitServerNotification(
            method: "item/fileChange/patchUpdated",
            params: CodexJSONValue.object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "itemId": .string(itemID),
                "changes": .array(changes.map(\.wireValueForTesting)),
            ])
        )
    }

    public func emitTurnCompleted(
        threadID: CodexThreadID,
        turn: CodexAppServerTestTurn
    ) async throws {
        guard threadID.rawValue.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("thread id must not be empty")
        }
        switch turn.snapshot.state {
        case .completed, .interrupted, .failed:
            break
        case .inProgress, .unknown:
            throw CodexAppServerTestError.invalidFixture(
                "turn/completed requires a completed, interrupted, or failed turn"
            )
        }
        try await transport.emitServerNotification(
            method: "turn/completed",
            params: CodexJSONValue.object([
                "threadId": .string(threadID.rawValue),
                "turn": turn.wireValue,
            ])
        )
    }

    public func emitThreadStatusChanged(
        threadID: CodexThreadID,
        status: CodexThreadStatus
    ) async throws {
        guard threadID.rawValue.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("thread id must not be empty")
        }
        var statusFields: [String: CodexJSONValue] = [
            "type": .string(status.rawValue),
        ]
        if case .active(let flags) = status {
            statusFields["activeFlags"] = .array(flags.map { .string($0.rawValue) })
        }
        try await transport.emitServerNotification(
            method: "thread/status/changed",
            params: CodexJSONValue.object([
                "threadId": .string(threadID.rawValue),
                "status": .object(statusFields),
            ])
        )
    }

    public func emitError(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        error: CodexTurnError,
        willRetry: Bool
    ) async throws {
        try validateContext(threadID: threadID, turnID: turnID, itemID: "error")
        guard error.message.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("turn error message must not be empty")
        }
        try await transport.emitServerNotification(
            method: "error",
            params: CodexJSONValue.object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID.rawValue),
                "error": error.wireValueForTesting,
                "willRetry": .bool(willRetry),
            ])
        )
    }

    public func emitAccountChanged(
        _ update: CodexAppServerTestAccountUpdate
    ) async throws {
        try await transport.emitServerNotification(
            method: "account/updated",
            params: CodexJSONValue.object([
                "authMode": update.authMode.map { .string($0.wireValue) } ?? .null,
                "planType": update.planType.map { .string($0.wireValue) } ?? .null,
            ])
        )
    }

    public func emitRateLimitsUpdated(
        _ update: CodexAppServerTestRateLimitsUpdate
    ) async throws {
        try await transport.emitServerNotification(
            method: "account/rateLimits/updated",
            params: CodexJSONValue.object([
                "rateLimits": update.snapshot.wireValue,
            ])
        )
    }

    public func emitLoginCompleted(
        loginID: CodexLoginHandle.ID,
        completion: CodexAppServerTestLoginCompletion
    ) async throws {
        guard loginID.rawValue.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("login id must not be empty")
        }
        let success: Bool
        let error: CodexJSONValue
        switch completion {
        case .succeeded:
            success = true
            error = .null
        case .failed(let message):
            success = false
            error = message.map(CodexJSONValue.string) ?? .null
        }
        try await transport.emitServerNotification(
            method: "account/login/completed",
            params: CodexJSONValue.object([
                "loginId": .string(loginID.rawValue),
                "success": .bool(success),
                "error": error,
            ])
        )
    }

    private func emitItem(
        method: String,
        timestampKey: String,
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        item: CodexAppServerTestItem
    ) async throws {
        try validateContext(threadID: threadID, turnID: turnID, itemID: item.domainProjection.id)
        let timestampMilliseconds = nextFixtureTimestampMilliseconds
        nextFixtureTimestampMilliseconds += 1
        let fields: [String: CodexJSONValue] = [
            "threadId": .string(threadID.rawValue),
            "turnId": .string(turnID.rawValue),
            timestampKey: .int(timestampMilliseconds),
            "item": item.wireValue,
        ]
        try await transport.emitServerNotification(
            method: method,
            params: CodexJSONValue.object(fields)
        )
    }

    private func emitDelta(
        method: String,
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        itemID: String,
        delta: String,
        additionalFields: [String: CodexJSONValue] = [:]
    ) async throws {
        try validateContext(threadID: threadID, turnID: turnID, itemID: itemID)
        guard delta.isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("delta must not be empty")
        }
        var fields = additionalFields
        fields["threadId"] = .string(threadID.rawValue)
        fields["turnId"] = .string(turnID.rawValue)
        fields["itemId"] = .string(itemID)
        fields["delta"] = .string(delta)
        try await transport.emitServerNotification(
            method: method,
            params: CodexJSONValue.object(fields)
        )
    }

    private func validateContext(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        itemID: String
    ) throws {
        guard threadID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              turnID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture(
                "thread, turn, and item ids must not be empty or whitespace"
            )
        }
    }
}

private extension CodexAppServerTestItem.CommandStatus {
    var turnStatus: CodexTurnStatus {
        switch self {
        case .inProgress: .inProgress
        case .completed: .completed
        case .failed, .declined: .failed
        }
    }
}

private extension CodexAppServerTestItem.MCPStatus {
    var turnStatus: CodexTurnStatus {
        switch self {
        case .inProgress: .inProgress
        case .completed: .completed
        case .failed: .failed
        }
    }
}

private extension CodexAppServerTestItem.PatchStatus {
    var turnStatus: CodexTurnStatus {
        switch self {
        case .inProgress: .inProgress
        case .completed: .completed
        case .failed, .declined: .failed
        }
    }
}

private extension CodexFileUpdateChange {
    var wireValueForTesting: CodexJSONValue {
        var kindFields: [String: CodexJSONValue]
        switch kind {
        case .add:
            kindFields = ["type": .string("add")]
        case .delete:
            kindFields = ["type": .string("delete")]
        case .update(let movePath):
            kindFields = ["type": .string("update")]
            if let movePath {
                kindFields["move_path"] = .string(movePath)
            }
        }
        return .object([
            "path": .string(path),
            "kind": .object(kindFields),
            "diff": .string(diff),
        ])
    }
}

private extension Duration {
    var millisecondsForTesting: Int? {
        let components = self.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        guard milliseconds >= 0, milliseconds <= Int.max else {
            return nil
        }
        return Int(milliseconds)
    }
}

private extension CodexJSONValue {
    var displayTextForTesting: String? {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .object(let value):
            value["displayText"]?.displayTextForTesting
                ?? value["text"]?.displayTextForTesting
                ?? value["message"]?.displayTextForTesting
                ?? jsonStringForTesting
        case .array:
            jsonStringForTesting
        case .null:
            nil
        }
    }

    var jsonStringForTesting: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
