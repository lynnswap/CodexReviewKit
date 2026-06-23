import Foundation

public struct CodexPrompt: ExpressibleByStringLiteral, Equatable, Sendable {
    public var parts: [Part]

    public init(parts: [Part]) {
        self.parts = parts
    }

    public init(stringLiteral value: String) {
        self.parts = [.text(value)]
    }

    public init(_ text: String) {
        self.parts = [.text(text)]
    }

    public enum Part: Equatable, Sendable {
        case text(String)
        case imageURL(URL)
        case localImage(URL)
        case skill(name: String, path: URL)
        case mention(name: String, path: URL)
    }
}

public struct CodexInstructions: Equatable, Sendable {
    public var base: String?
    public var developer: String?

    public init(base: String? = nil, developer: String? = nil) {
        self.base = base
        self.developer = developer
    }

    public static func base(_ text: String) -> Self {
        .init(base: text)
    }

    public static func developer(_ text: String) -> Self {
        .init(developer: text)
    }
}

public enum CodexSandbox: String, Codable, Equatable, Sendable {
    case readOnly
    case workspaceWrite
    case fullAccess

    package var threadSandboxValue: String {
        switch self {
        case .readOnly:
            "read-only"
        case .workspaceWrite:
            "workspace-write"
        case .fullAccess:
            "danger-full-access"
        }
    }

    package var turnSandboxPolicy: AppServerAPI.Turn.SandboxPolicy {
        switch self {
        case .readOnly:
            .readOnly(networkAccess: false)
        case .workspaceWrite:
            .workspaceWrite(
                writableRoots: [],
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        case .fullAccess:
            .dangerFullAccess
        }
    }
}

public enum CodexApprovalMode: String, Codable, Equatable, Sendable {
    case autoReview
    case denyAll

    package var approvalPolicy: String {
        switch self {
        case .autoReview:
            "on-request"
        case .denyAll:
            "never"
        }
    }

    package var approvalsReviewer: String? {
        switch self {
        case .autoReview:
            "auto_review"
        case .denyAll:
            nil
        }
    }
}

public struct CodexThread: Identifiable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    public struct Options: Equatable, Sendable {
        public var model: String?
        public var modelProvider: String?
        public var approvalMode: CodexApprovalMode?
        public var sandbox: CodexSandbox?
        public var serviceTier: String?
        public var ephemeral: Bool?

        public init(
            model: String? = nil,
            modelProvider: String? = nil,
            approvalMode: CodexApprovalMode? = nil,
            sandbox: CodexSandbox? = nil,
            serviceTier: String? = nil,
            ephemeral: Bool? = nil
        ) {
            self.model = model
            self.modelProvider = modelProvider
            self.approvalMode = approvalMode
            self.sandbox = sandbox
            self.serviceTier = serviceTier
            self.ephemeral = ephemeral
        }
    }

    public typealias ResumeOptions = Options

    public let id: ID
    public let workspace: URL?
    public let model: String?

    package let client: AppServerClient
    package let router: CodexAppServerNotificationRouter

    package init(
        id: ID,
        workspace: URL? = nil,
        model: String? = nil,
        client: AppServerClient,
        router: CodexAppServerNotificationRouter
    ) {
        self.id = id
        self.workspace = workspace
        self.model = model
        self.client = client
        self.router = router
    }
}

public struct CodexTurn: Identifiable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    public struct Options: Equatable, Sendable {
        public var model: String?
        public var approvalMode: CodexApprovalMode?
        public var sandbox: CodexSandbox?
        public var cwd: URL?
        public var effort: String?
        public var serviceTier: String?
        public var summary: String?

        public init(
            model: String? = nil,
            approvalMode: CodexApprovalMode? = nil,
            sandbox: CodexSandbox? = nil,
            cwd: URL? = nil,
            effort: String? = nil,
            serviceTier: String? = nil,
            summary: String? = nil
        ) {
            self.model = model
            self.approvalMode = approvalMode
            self.sandbox = sandbox
            self.cwd = cwd
            self.effort = effort
            self.serviceTier = serviceTier
            self.summary = summary
        }
    }

    public let id: ID
    public let threadID: CodexThread.ID

    package let client: AppServerClient
    package let router: CodexAppServerNotificationRouter

    package init(
        id: ID,
        threadID: CodexThread.ID,
        client: AppServerClient,
        router: CodexAppServerNotificationRouter
    ) {
        self.id = id
        self.threadID = threadID
        self.client = client
        self.router = router
    }
}

public struct CodexThreadSnapshot: Identifiable, Equatable, Sendable {
    public var id: CodexThread.ID
    public var workspace: URL?
    public var name: String?
    public var preview: String?
    public var turns: [CodexTurnSnapshot]

    public init(
        id: CodexThread.ID,
        workspace: URL? = nil,
        name: String? = nil,
        preview: String? = nil,
        turns: [CodexTurnSnapshot] = []
    ) {
        self.id = id
        self.workspace = workspace
        self.name = name
        self.preview = preview
        self.turns = turns
    }
}

public struct CodexTurnSnapshot: Identifiable, Equatable, Sendable {
    public var id: CodexTurn.ID
    public var status: CodexTurnStatus?
    public var errorMessage: String?

    public init(
        id: CodexTurn.ID,
        status: CodexTurnStatus? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.status = status
        self.errorMessage = errorMessage
    }
}

public struct CodexThreadQuery: Equatable, Sendable {
    public var archived: Bool?
    public var cursor: String?
    public var workspace: URL?
    public var limit: Int?
    public var searchTerm: String?

    public init(
        archived: Bool? = nil,
        cursor: String? = nil,
        workspace: URL? = nil,
        limit: Int? = nil,
        searchTerm: String? = nil
    ) {
        self.archived = archived
        self.cursor = cursor
        self.workspace = workspace
        self.limit = limit
        self.searchTerm = searchTerm
    }
}

public struct CodexThreadPage: Equatable, Sendable {
    public var threads: [CodexThreadSnapshot]
    public var nextCursor: String?
    public var backwardsCursor: String?

    public init(
        threads: [CodexThreadSnapshot],
        nextCursor: String? = nil,
        backwardsCursor: String? = nil
    ) {
        self.threads = threads
        self.nextCursor = nextCursor
        self.backwardsCursor = backwardsCursor
    }
}

public struct CodexTranscript: Equatable, Sendable {
    public var items: [CodexThreadItem]

    public init(items: [CodexThreadItem] = []) {
        self.items = items
    }

    public var messages: [CodexMessage] {
        items.compactMap(\.message)
    }

    public var finalAnswer: String? {
        var fallback: String?
        for message in messages.reversed() where message.role == .assistant {
            if message.phase == .finalAnswer {
                return message.text
            }
            if message.phase == nil, fallback == nil {
                fallback = message.text
            }
        }
        return fallback
    }
}

public struct CodexThreadItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case userMessage
        case agentMessage
        case plan
        case reasoning
        case commandExecution
        case fileChange
        case mcpToolCall
        case dynamicToolCall
        case collabAgentToolCall
        case subAgentActivity
        case webSearch
        case imageView
        case sleep
        case imageGeneration
        case contextCompaction
        case diagnostic
        case error
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "userMessage":
                self = .userMessage
            case "agentMessage":
                self = .agentMessage
            case "plan":
                self = .plan
            case "reasoning":
                self = .reasoning
            case "commandExecution":
                self = .commandExecution
            case "fileChange":
                self = .fileChange
            case "mcpToolCall":
                self = .mcpToolCall
            case "dynamicToolCall":
                self = .dynamicToolCall
            case "collabAgentToolCall":
                self = .collabAgentToolCall
            case "subAgentActivity":
                self = .subAgentActivity
            case "webSearch":
                self = .webSearch
            case "imageView":
                self = .imageView
            case "sleep":
                self = .sleep
            case "imageGeneration":
                self = .imageGeneration
            case "contextCompaction":
                self = .contextCompaction
            case "diagnostic":
                self = .diagnostic
            case "error":
                self = .error
            case let rawValue:
                self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .userMessage:
                "userMessage"
            case .agentMessage:
                "agentMessage"
            case .plan:
                "plan"
            case .reasoning:
                "reasoning"
            case .commandExecution:
                "commandExecution"
            case .fileChange:
                "fileChange"
            case .mcpToolCall:
                "mcpToolCall"
            case .dynamicToolCall:
                "dynamicToolCall"
            case .collabAgentToolCall:
                "collabAgentToolCall"
            case .subAgentActivity:
                "subAgentActivity"
            case .webSearch:
                "webSearch"
            case .imageView:
                "imageView"
            case .sleep:
                "sleep"
            case .imageGeneration:
                "imageGeneration"
            case .contextCompaction:
                "contextCompaction"
            case .diagnostic:
                "diagnostic"
            case .error:
                "error"
            case .unknown(let rawValue):
                rawValue
            }
        }
    }

    public enum Content: Equatable, Sendable {
        case message(CodexMessage)
        case plan(String)
        case reasoning(String)
        case command(CodexCommand)
        case fileChange(CodexFileChange)
        case toolCall(CodexToolCall)
        case contextCompaction(String?)
        case diagnostic(String)
        case log(String)
        case unknown(CodexRawItem)
    }

    public var id: String
    public var kind: Kind
    public var content: Content

    public init(
        id: String,
        kind: Kind,
        content: Content
    ) {
        self.id = id
        self.kind = kind
        self.content = content
    }

    public var text: String? {
        switch content {
        case .message(let message):
            message.text
        case .plan(let text), .reasoning(let text), .diagnostic(let text), .log(let text):
            text
        case .command(let command):
            command.output ?? command.command
        case .fileChange(let fileChange):
            fileChange.output ?? fileChange.path
        case .toolCall(let toolCall):
            toolCall.result ?? toolCall.error ?? toolCall.name
        case .contextCompaction(let text):
            text
        case .unknown(let raw):
            raw.text
        }
    }

    public var message: CodexMessage? {
        if case .message(let message) = content {
            return message
        }
        return nil
    }
}

public struct CodexMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case user
        case assistant
        case system
        case tool
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "user":
                self = .user
            case "assistant", "agent":
                self = .assistant
            case "system":
                self = .system
            case "tool":
                self = .tool
            case let rawValue:
                self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .user:
                "user"
            case .assistant:
                "assistant"
            case .system:
                "system"
            case .tool:
                "tool"
            case .unknown(let rawValue):
                rawValue
            }
        }
    }

    public var id: String
    public var role: Role
    public var phase: CodexMessagePhase?
    public var text: String

    public init(
        id: String,
        role: Role,
        phase: CodexMessagePhase? = nil,
        text: String
    ) {
        self.id = id
        self.role = role
        self.phase = phase
        self.text = text
    }
}

public enum CodexMessagePhase: Equatable, Sendable {
    case commentary
    case finalAnswer
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "commentary":
            self = .commentary
        case "final_answer", "finalAnswer":
            self = .finalAnswer
        case let rawValue:
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .commentary:
            "commentary"
        case .finalAnswer:
            "final_answer"
        case .unknown(let rawValue):
            rawValue
        }
    }
}

public struct CodexCommand: Equatable, Sendable {
    public var command: String
    public var cwd: String?
    public var output: String?
    public var exitCode: Int?
    public var status: CodexTurnStatus?

    public init(
        command: String,
        cwd: String? = nil,
        output: String? = nil,
        exitCode: Int? = nil,
        status: CodexTurnStatus? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.output = output
        self.exitCode = exitCode
        self.status = status
    }
}

public struct CodexFileChange: Equatable, Sendable {
    public var path: String?
    public var output: String?
    public var status: CodexTurnStatus?

    public init(path: String? = nil, output: String? = nil, status: CodexTurnStatus? = nil) {
        self.path = path
        self.output = output
        self.status = status
    }
}

public struct CodexToolCall: Equatable, Sendable {
    public var namespace: String?
    public var server: String?
    public var name: String?
    public var arguments: String?
    public var result: String?
    public var error: String?
    public var status: CodexTurnStatus?

    public init(
        namespace: String? = nil,
        server: String? = nil,
        name: String? = nil,
        arguments: String? = nil,
        result: String? = nil,
        error: String? = nil,
        status: CodexTurnStatus? = nil
    ) {
        self.namespace = namespace
        self.server = server
        self.name = name
        self.arguments = arguments
        self.result = result
        self.error = error
        self.status = status
    }
}

public struct CodexRawItem: Equatable, Sendable {
    public var rawType: String
    public var text: String?
    public var payload: Data?

    public init(rawType: String, text: String? = nil, payload: Data? = nil) {
        self.rawType = rawType
        self.text = text
        self.payload = payload
    }
}

public enum CodexTurnStatus: Equatable, Sendable {
    case running
    case completed
    case failed
    case interrupted
    case cancelled
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "running", "inProgress", "started":
            self = .running
        case "completed", "succeeded", "success":
            self = .completed
        case "failed", "failure", "error":
            self = .failed
        case "interrupted":
            self = .interrupted
        case "cancelled", "canceled", "aborted":
            self = .cancelled
        case let rawValue:
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .running:
            "running"
        case .completed:
            "completed"
        case .failed:
            "failed"
        case .interrupted:
            "interrupted"
        case .cancelled:
            "cancelled"
        case .unknown(let rawValue):
            rawValue
        }
    }

    public var isFailure: Bool {
        switch self {
        case .failed, .interrupted, .cancelled:
            true
        case .running, .completed, .unknown:
            false
        }
    }
}

public struct CodexTurnResult: Identifiable, Equatable, Sendable {
    public var id: CodexTurn.ID
    public var status: CodexTurnStatus?
    public var errorMessage: String?
    public var finalAnswer: String?
    public var transcript: CodexTranscript
    public var usage: CodexTokenUsage?

    public init(
        id: CodexTurn.ID,
        status: CodexTurnStatus? = nil,
        errorMessage: String? = nil,
        finalAnswer: String? = nil,
        transcript: CodexTranscript = .init(),
        usage: CodexTokenUsage? = nil
    ) {
        self.id = id
        self.status = status
        self.errorMessage = errorMessage
        self.finalAnswer = finalAnswer
        self.transcript = transcript
        self.usage = usage
    }
}

public struct CodexTokenUsage: Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var cachedInputTokens: Int?
    public var reasoningOutputTokens: Int?
    public var modelContextWindow: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        reasoningOutputTokens: Int? = nil,
        modelContextWindow: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.modelContextWindow = modelContextWindow
    }
}

public struct CodexMessageDelta: Equatable, Sendable {
    public var text: String
    public var itemID: String?
    public var phase: CodexMessagePhase?

    public init(text: String, itemID: String? = nil, phase: CodexMessagePhase? = nil) {
        self.text = text
        self.itemID = itemID
        self.phase = phase
    }
}

public enum CodexTurnEvent: Equatable, Sendable {
    case started(CodexTurn.ID)
    case itemStarted(CodexThreadItem)
    case itemUpdated(CodexThreadItem)
    case itemCompleted(CodexThreadItem)
    case messageDelta(CodexMessageDelta)
    case tokenUsageUpdated(CodexTokenUsage)
    case completed(CodexTurnResult)
    case failed(String)
    case unknown(CodexRawNotification)
}

public enum CodexThreadEvent: Equatable, Sendable {
    case turnStarted(CodexTurn.ID)
    case turnCompleted(CodexTurnResult)
    case turnFailed(turnID: CodexTurn.ID?, message: String)
    case itemStarted(CodexThreadItem, turnID: CodexTurn.ID?)
    case itemUpdated(CodexThreadItem, turnID: CodexTurn.ID?)
    case itemCompleted(CodexThreadItem, turnID: CodexTurn.ID?)
    case message(CodexMessage, turnID: CodexTurn.ID?)
    case messageDelta(CodexMessageDelta, turnID: CodexTurn.ID?)
    case tokenUsageUpdated(CodexTokenUsage, turnID: CodexTurn.ID?)
    case statusChanged(CodexThreadStatus)
    case closed
    case unknown(CodexRawNotification)
}

public struct CodexThreadLogEntry: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case started
        case updated
        case completed
        case delta
    }

    public var id: String
    public var turnID: CodexTurn.ID?
    public var phase: Phase
    public var item: CodexThreadItem?
    public var messageDelta: CodexMessageDelta?

    public init(
        id: String,
        turnID: CodexTurn.ID? = nil,
        phase: Phase,
        item: CodexThreadItem? = nil,
        messageDelta: CodexMessageDelta? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.phase = phase
        self.item = item
        self.messageDelta = messageDelta
    }
}

public enum CodexThreadStatus: Equatable, Sendable {
    case running
    case closed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "running", "loaded":
            self = .running
        case "closed", "notLoaded":
            self = .closed
        case let rawValue:
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .running:
            "running"
        case .closed:
            "closed"
        case .unknown(let rawValue):
            rawValue
        }
    }
}

public struct CodexTurnProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case running
        case completed
        case failed(CodexAppServerError)
    }

    public var phase: Phase
    public var transcript: CodexTranscript
    public var result: CodexTurnResult?

    public init(
        phase: Phase,
        transcript: CodexTranscript = .init(),
        result: CodexTurnResult? = nil
    ) {
        self.phase = phase
        self.transcript = transcript
        self.result = result
    }
}

public struct CodexRawNotification: Equatable, Sendable {
    public var method: String
    public var params: Data
    public var threadID: CodexThread.ID?
    public var turnID: CodexTurn.ID?

    public init(
        method: String,
        params: Data,
        threadID: CodexThread.ID? = nil,
        turnID: CodexTurn.ID? = nil
    ) {
        self.method = method
        self.params = params
        self.threadID = threadID
        self.turnID = turnID
    }
}

public struct CodexConfiguration: Equatable, Sendable {
    public var model: String?
    public var reviewModel: String?
    public var reasoningEffort: String?
    public var serviceTier: String?

    public init(
        model: String? = nil,
        reviewModel: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil
    ) {
        self.model = model
        self.reviewModel = reviewModel
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
    }
}

public struct CodexRateLimits: Equatable, Sendable {
    public var planType: String?
    public var windows: [CodexRateLimitWindow]

    public init(planType: String? = nil, windows: [CodexRateLimitWindow] = []) {
        self.planType = planType
        self.windows = windows
    }
}

public struct CodexRateLimitWindow: Equatable, Sendable {
    public var windowDurationMinutes: Int
    public var usedPercent: Int
    public var resetsAt: Date?

    public init(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date? = nil) {
        self.windowDurationMinutes = windowDurationMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct CodexModel: Codable, Identifiable, Equatable, Sendable {
    public struct ReasoningOption: Codable, Equatable, Sendable {
        public var reasoningEffort: String
        public var description: String

        public init(reasoningEffort: String, description: String) {
            self.reasoningEffort = reasoningEffort
            self.description = description
        }
    }

    private struct ServiceTier: Decodable {
        let id: String
    }

    public var id: String
    public var model: String
    public var displayName: String
    public var hidden: Bool
    public var supportedReasoningEfforts: [ReasoningOption]
    public var defaultReasoningEffort: String?
    public var supportedServiceTiers: [String]
    public var isDefault: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case displayName
        case hidden
        case supportedReasoningEfforts
        case defaultReasoningEffort
        case supportedServiceTiers = "additionalSpeedTiers"
        case serviceTiers
        case isDefault
    }

    public init(
        id: String,
        model: String,
        displayName: String,
        hidden: Bool = false,
        supportedReasoningEfforts: [ReasoningOption] = [],
        defaultReasoningEffort: String? = nil,
        supportedServiceTiers: [String] = [],
        isDefault: Bool = false
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.hidden = hidden
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedServiceTiers = supportedServiceTiers
        self.isDefault = isDefault
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.model = try container.decode(String.self, forKey: .model)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        self.supportedReasoningEfforts =
            try container.decodeIfPresent(
                [ReasoningOption].self,
                forKey: .supportedReasoningEfforts
            ) ?? []
        self.defaultReasoningEffort = try container.decodeIfPresent(
            String.self, forKey: .defaultReasoningEffort)
        let additionalSpeedTiers =
            try container.decodeIfPresent([String].self, forKey: .supportedServiceTiers) ?? []
        let serviceTierIDs =
            try container.decodeIfPresent([ServiceTier].self, forKey: .serviceTiers)?.map(\.id)
            ?? []
        self.supportedServiceTiers = Array(Set(additionalSpeedTiers + serviceTierIDs)).sorted()
        self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(model, forKey: .model)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
        try container.encodeIfPresent(defaultReasoningEffort, forKey: .defaultReasoningEffort)
        try container.encode(supportedServiceTiers, forKey: .supportedServiceTiers)
        try container.encode(isDefault, forKey: .isDefault)
    }
}

public struct CodexAccount: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case chatGPT = "chatgpt"
        case apiKey
        case amazonBedrock
    }

    public var id: String
    public var kind: Kind
    public var label: String
    public var planType: String?

    public init(id: String, kind: Kind, label: String, planType: String? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.planType = planType
    }
}

public enum CodexLoginHandle: Equatable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    case apiKey
    case chatGPT(id: ID, authenticationURL: URL)
    case chatGPTDeviceCode(id: ID, verificationURL: URL, userCode: String)

    public var id: ID? {
        switch self {
        case .apiKey:
            nil
        case .chatGPT(let id, _), .chatGPTDeviceCode(let id, _, _):
            id
        }
    }
}

public enum CodexAppServerError: Error, Equatable, LocalizedError, Sendable {
    case transportClosed
    case jsonRPC(code: Int, message: String)
    case serverBusy(String)
    case retryLimitExceeded
    case malformedNotification(String)
    case turnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .transportClosed:
            "The Codex app-server connection is closed."
        case .jsonRPC(_, let message):
            message
        case .serverBusy(let message):
            message
        case .retryLimitExceeded:
            "The Codex app-server remained busy after all retry attempts."
        case .malformedNotification(let message):
            message
        case .turnFailed(let message):
            message
        }
    }
}
