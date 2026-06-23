import Foundation

public struct CodexPrompt: ExpressibleByStringLiteral, Equatable, Sendable {
    public var parts: [Part]

    public init(parts: [Part]) {
        self.parts = parts
    }

    public init(@CodexPromptBuilder _ content: () throws -> CodexPrompt) rethrows {
        self = try content()
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

@resultBuilder
public enum CodexPromptBuilder {
    public static func buildBlock(_ components: CodexPrompt...) -> CodexPrompt {
        .init(parts: components.flatMap(\.parts))
    }

    public static func buildExpression(_ expression: CodexPrompt) -> CodexPrompt {
        expression
    }

    public static func buildExpression(_ expression: CodexPrompt.Part) -> CodexPrompt {
        .init(parts: [expression])
    }

    public static func buildExpression(_ expression: String) -> CodexPrompt {
        .init(expression)
    }

    public static func buildOptional(_ component: CodexPrompt?) -> CodexPrompt {
        component ?? .init(parts: [])
    }

    public static func buildEither(first component: CodexPrompt) -> CodexPrompt {
        component
    }

    public static func buildEither(second component: CodexPrompt) -> CodexPrompt {
        component
    }

    public static func buildArray(_ components: [CodexPrompt]) -> CodexPrompt {
        .init(parts: components.flatMap(\.parts))
    }

    public static func buildLimitedAvailability(_ component: CodexPrompt) -> CodexPrompt {
        component
    }
}

public struct CodexInstructions: Equatable, Sendable {
    public var base: String?
    public var developer: String?

    public init(base: String? = nil, developer: String? = nil) {
        self.base = base
        self.developer = developer
    }

    public init(_ developer: String) {
        self.init(developer: developer)
    }

    public init(@CodexInstructionsBuilder _ developer: () throws -> String) rethrows {
        self.init(developer: try developer())
    }

    public static func base(_ text: String) -> Self {
        .init(base: text)
    }

    public static func developer(_ text: String) -> Self {
        .init(developer: text)
    }
}

@resultBuilder
public enum CodexInstructionsBuilder {
    public static func buildBlock(_ components: String...) -> String {
        components.filter { $0.isEmpty == false }.joined(separator: "\n")
    }

    public static func buildExpression(_ expression: String) -> String {
        expression
    }

    public static func buildOptional(_ component: String?) -> String {
        component ?? ""
    }

    public static func buildEither(first component: String) -> String {
        component
    }

    public static func buildEither(second component: String) -> String {
        component
    }

    public static func buildArray(_ components: [String]) -> String {
        components.filter { $0.isEmpty == false }.joined(separator: "\n")
    }

    public static func buildLimitedAvailability(_ component: String) -> String {
        component
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

public struct CodexGenerationOptions: Equatable, Sendable {
    public var model: String?
    public var approvalMode: CodexApprovalMode?
    public var sandbox: CodexSandbox?
    public var cwd: URL?
    public var effort: String?
    public var serviceTier: String?
    public var summary: String?
    public var transcriptErrorHandlingPolicy: CodexTranscriptErrorHandlingPolicy

    public init(
        model: String? = nil,
        approvalMode: CodexApprovalMode? = nil,
        sandbox: CodexSandbox? = nil,
        cwd: URL? = nil,
        effort: String? = nil,
        serviceTier: String? = nil,
        summary: String? = nil,
        transcriptErrorHandlingPolicy: CodexTranscriptErrorHandlingPolicy = .preserveTranscript
    ) {
        self.model = model
        self.approvalMode = approvalMode
        self.sandbox = sandbox
        self.cwd = cwd
        self.effort = effort
        self.serviceTier = serviceTier
        self.summary = summary
        self.transcriptErrorHandlingPolicy = transcriptErrorHandlingPolicy
    }
}

public struct CodexTranscriptErrorHandlingPolicy: Equatable, Sendable {
    private enum Kind: Equatable, Sendable {
        case preserveTranscript
        case revertTranscript
    }

    private var kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    public static let preserveTranscript = Self(kind: .preserveTranscript)
    public static let revertTranscript = Self(kind: .revertTranscript)

    package var shouldRevertTranscript: Bool {
        kind == .revertTranscript
    }
}

public struct CodexThreadID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

public struct CodexThread: Identifiable, Sendable {
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

    public let id: CodexThreadID
    public let workspace: URL?
    public let model: String?

    package let client: AppServerClient
    package let router: CodexAppServerNotificationRouter

    package init(
        id: CodexThreadID,
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

/// The target that `codex app-server` should review.
public enum CodexReviewTarget: Codable, Hashable, Sendable {
    /// Review the current uncommitted working tree changes.
    case uncommittedChanges

    /// Review changes relative to a base branch.
    case baseBranch(String)

    /// Review a specific commit.
    ///
    /// `title` is optional metadata that the app-server may use for display.
    case commit(sha: String, title: String? = nil)

    /// Review using custom app-server instructions.
    case custom(instructions: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case branch
        case sha
        case title
        case instructions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "uncommittedChanges":
            self = .uncommittedChanges
        case "baseBranch":
            self = .baseBranch(try container.decode(String.self, forKey: .branch))
        case "commit":
            self = .commit(
                sha: try container.decode(String.self, forKey: .sha),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )
        case "custom":
            self = .custom(instructions: try container.decode(String.self, forKey: .instructions))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown review target type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .uncommittedChanges:
            try container.encode("uncommittedChanges", forKey: .type)
        case .baseBranch(let branch):
            try container.encode("baseBranch", forKey: .type)
            try container.encode(branch, forKey: .branch)
        case .commit(let sha, let title):
            try container.encode("commit", forKey: .type)
            try container.encode(sha, forKey: .sha)
            try container.encodeIfPresent(title, forKey: .title)
        case .custom(let instructions):
            try container.encode("custom", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
        }
    }
}

/// How `review/start` should deliver review work.
public enum CodexReviewDelivery: String, Codable, Equatable, Sendable {
    /// Run the review in the current thread.
    case inline

    /// Let the app-server create a detached review thread when supported.
    case detached
}

/// A review run started by `codex app-server`.
public struct CodexReviewSession: Identifiable, Sendable {
    /// The response turn identifier, used as the stable session identity.
    public var id: CodexTurnID {
        turnID
    }

    /// The thread where `startReview(target:delivery:transcriptErrorHandlingPolicy:)` was called.
    public let threadID: CodexThreadID

    /// The app-server turn that is producing the review response.
    public let turnID: CodexTurnID

    /// The thread that emits review events and logs.
    ///
    /// This equals `threadID` for inline reviews and may differ for detached
    /// reviews.
    public let reviewThreadID: CodexThreadID

    /// The live response stream for the review turn.
    public let response: CodexResponseStream

    private let eventThread: CodexThread

    package init(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        reviewThreadID: CodexThreadID,
        response: CodexResponseStream,
        eventThread: CodexThread
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.reviewThreadID = reviewThreadID
        self.response = response
        self.eventThread = eventThread
    }

    /// Thread-scoped events for the review thread.
    public var events: CodexThreadEventSequence {
        eventThread.events
    }

    /// Agent messages emitted by the review thread.
    public var messages: CodexThreadMessageSequence {
        eventThread.messages
    }

    /// Incremental transcript snapshots for the review thread.
    public var transcriptUpdates: CodexThreadTranscriptSequence {
        eventThread.transcriptUpdates
    }

    /// Log-oriented review entries.
    ///
    /// ReviewMonitor-style logs can be built from this sequence without
    /// depending on raw JSON-RPC notifications.
    public var logEntries: CodexThreadLogSequence {
        eventThread.logEntries
    }

    /// Collects the review response until the turn finishes.
    public func collect() async throws -> CodexResponse {
        try await response.collect()
    }

    /// Interrupts the running review turn.
    public func interrupt() async throws {
        try await response.interrupt()
    }

    /// Sends additional input to the running review turn.
    public func steer(with prompt: CodexPrompt) async throws {
        try await response.steer(with: prompt)
    }

    /// Sends additional text input to the running review turn.
    public func steer(with prompt: String) async throws {
        try await response.steer(with: prompt)
    }
}

public struct CodexTurnID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

package struct CodexTurn: Identifiable, Sendable {
    package let id: CodexTurnID
    package let threadID: CodexThreadID

    package let client: AppServerClient
    package let router: CodexAppServerNotificationRouter

    package init(
        id: CodexTurnID,
        threadID: CodexThreadID,
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
    public var id: CodexThreadID
    public var workspace: URL?
    public var name: String?
    public var preview: String?
    public var turns: [CodexTurnSnapshot]

    public init(
        id: CodexThreadID,
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
    public var id: CodexTurnID
    public var status: CodexTurnStatus?
    public var errorMessage: String?

    public init(
        id: CodexTurnID,
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

    public var responseText: String? {
        messages.reversed().first { $0.role == .assistant }?.text
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
    public var rawPayload: Data?

    public init(
        id: String,
        kind: Kind,
        content: Content,
        rawPayload: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.rawPayload = rawPayload
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

public struct CodexResponse: Identifiable, Equatable, Sendable {
    public var turnID: CodexTurnID
    public var status: CodexTurnStatus?
    public var errorMessage: String?
    public var finalAnswer: String?
    public var transcript: CodexTranscript
    public var usage: CodexTokenUsage?

    public var id: CodexTurnID {
        turnID
    }

    public init(
        turnID: CodexTurnID,
        status: CodexTurnStatus? = nil,
        errorMessage: String? = nil,
        finalAnswer: String? = nil,
        transcript: CodexTranscript = .init(),
        usage: CodexTokenUsage? = nil
    ) {
        self.turnID = turnID
        self.status = status
        self.errorMessage = errorMessage
        self.finalAnswer = finalAnswer
        self.transcript = transcript
        self.usage = usage
    }
}

public struct CodexResponseStream: AsyncSequence, Sendable {
    public enum SubmissionMode: Equatable, Sendable {
        case queueAfterCurrentResponse
        case interruptCurrentResponse
    }

    public struct Snapshot: Equatable, Sendable {
        public var turnID: CodexTurnID
        public var content: String?
        public var transcript: CodexTranscript
        public var usage: CodexTokenUsage?
        public var response: CodexResponse?

        public init(
            turnID: CodexTurnID,
            content: String? = nil,
            transcript: CodexTranscript = .init(),
            usage: CodexTokenUsage? = nil,
            response: CodexResponse? = nil
        ) {
            self.turnID = turnID
            self.content = content
            self.transcript = transcript
            self.usage = usage
            self.response = response
        }
    }

    private let turn: CodexTurn
    private let transcriptErrorHandlingPolicy: CodexTranscriptErrorHandlingPolicy

    package init(
        turn: CodexTurn,
        transcriptErrorHandlingPolicy: CodexTranscriptErrorHandlingPolicy
    ) {
        self.turn = turn
        self.transcriptErrorHandlingPolicy = transcriptErrorHandlingPolicy
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            turn: turn,
            transcriptErrorHandlingPolicy: transcriptErrorHandlingPolicy,
            progress: turn.progress.makeAsyncIterator()
        )
    }

    public func collect() async throws -> CodexResponse {
        try await withTaskCancellationHandler {
            do {
                return try await turn.result()
            } catch {
                try await handleFailure()
                throw error
            }
        } onCancel: {
            let turn = turn
            Task {
                try? await turn.interrupt()
            }
        }
    }

    public func interrupt() async throws {
        try await turn.interrupt()
    }

    public func steer(with prompt: CodexPrompt) async throws {
        try await turn.steer(with: prompt)
    }

    public func steer(with prompt: String) async throws {
        try await steer(with: CodexPrompt(prompt))
    }

    public func steer(@CodexPromptBuilder prompt: () throws -> CodexPrompt) async throws {
        try await steer(with: try prompt())
    }

    public func submit(
        _ prompt: CodexPrompt,
        mode: SubmissionMode,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponseStream {
        switch mode {
        case .queueAfterCurrentResponse:
            _ = try await collect()
            return try await startFollowUp(to: prompt, options: options)
        case .interruptCurrentResponse:
            try await interrupt()
            try await waitForInterruptedResponse()
            return try await startFollowUp(to: prompt, options: options)
        }
    }

    public func submit(
        _ prompt: String,
        mode: SubmissionMode,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponseStream {
        try await submit(CodexPrompt(prompt), mode: mode, options: options)
    }

    public func submit(
        mode: SubmissionMode,
        options: CodexGenerationOptions = .init(),
        @CodexPromptBuilder prompt: () throws -> CodexPrompt
    ) async throws -> CodexResponseStream {
        try await submit(try prompt(), mode: mode, options: options)
    }

    private func startFollowUp(
        to prompt: CodexPrompt,
        options: CodexGenerationOptions
    ) async throws -> CodexResponseStream {
        let turn = try await startCodexTurn(
            threadID: turn.threadID,
            prompt: prompt,
            options: options,
            client: turn.client,
            router: turn.router
        )
        return .init(
            turn: turn,
            transcriptErrorHandlingPolicy: options.transcriptErrorHandlingPolicy
        )
    }

    private func waitForInterruptedResponse() async throws {
        for try await event in turn.events {
            switch event {
            case .completed(let response):
                if let message = response.errorMessage {
                    throw CodexAppServerError.turnFailed(message)
                }
                switch response.status {
                case .interrupted, .cancelled:
                    return
                case .failed:
                    throw CodexAppServerError.turnFailed(CodexTurnStatus.failed.rawValue)
                case .running, .completed, .unknown, nil:
                    return
                }
            case .failed(let message):
                throw CodexAppServerError.turnFailed(message)
            case .started, .itemStarted, .itemUpdated, .itemCompleted, .messageDelta,
                .tokenUsageUpdated, .unknown:
                continue
            }
        }
        throw CodexAppServerError.transportClosed
    }

    private func handleFailure() async throws {
        guard transcriptErrorHandlingPolicy.shouldRevertTranscript else {
            return
        }
        let _: EmptyResponse = try await turn.client.send(
            AppServerAPI.Thread.Rollback.Request(
                params: .init(threadID: turn.threadID.rawValue, numTurns: 1)
            ))
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let turn: CodexTurn
        private let transcriptErrorHandlingPolicy: CodexTranscriptErrorHandlingPolicy
        private var progress: CodexTurnProgressSequence.Iterator

        fileprivate init(
            turn: CodexTurn,
            transcriptErrorHandlingPolicy: CodexTranscriptErrorHandlingPolicy,
            progress: CodexTurnProgressSequence.Iterator
        ) {
            self.turn = turn
            self.transcriptErrorHandlingPolicy = transcriptErrorHandlingPolicy
            self.progress = progress
        }

        public mutating func next() async throws -> Snapshot? {
            guard let progress = try await progress.next() else {
                return nil
            }
            if case .failed(let error) = progress.phase {
                try await handleFailure()
                throw error
            }
            return Snapshot(
                turnID: turn.id,
                content: progress.result?.finalAnswer ?? progress.transcript.responseText,
                transcript: progress.transcript,
                usage: progress.result?.usage,
                response: progress.result
            )
        }

        private func handleFailure() async throws {
            guard transcriptErrorHandlingPolicy.shouldRevertTranscript else {
                return
            }
            let _: EmptyResponse = try await turn.client.send(
                AppServerAPI.Thread.Rollback.Request(
                    params: .init(threadID: turn.threadID.rawValue, numTurns: 1)
                ))
        }
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

package enum CodexTurnEvent: Equatable, Sendable {
    case started(CodexTurnID)
    case itemStarted(CodexThreadItem)
    case itemUpdated(CodexThreadItem)
    case itemCompleted(CodexThreadItem)
    case messageDelta(CodexMessageDelta)
    case tokenUsageUpdated(CodexTokenUsage)
    case completed(CodexResponse)
    case failed(String)
    case unknown(CodexRawNotification)
}

public enum CodexThreadEvent: Equatable, Sendable {
    case turnStarted(CodexTurnID)
    case turnCompleted(CodexResponse)
    case turnFailed(turnID: CodexTurnID?, message: String)
    case itemStarted(CodexThreadItem, turnID: CodexTurnID?)
    case itemUpdated(CodexThreadItem, turnID: CodexTurnID?)
    case itemCompleted(CodexThreadItem, turnID: CodexTurnID?)
    case message(CodexMessage, turnID: CodexTurnID?)
    case messageDelta(CodexMessageDelta, turnID: CodexTurnID?)
    case tokenUsageUpdated(CodexTokenUsage, turnID: CodexTurnID?)
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
    public var turnID: CodexTurnID?
    public var phase: Phase
    public var item: CodexThreadItem?
    public var messageDelta: CodexMessageDelta?

    public init(
        id: String,
        turnID: CodexTurnID? = nil,
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

package struct CodexTurnProgress: Equatable, Sendable {
    package enum Phase: Equatable, Sendable {
        case running
        case completed
        case failed(CodexAppServerError)
    }

    package var phase: Phase
    package var transcript: CodexTranscript
    package var result: CodexResponse?

    package init(
        phase: Phase,
        transcript: CodexTranscript = .init(),
        result: CodexResponse? = nil
    ) {
        self.phase = phase
        self.transcript = transcript
        self.result = result
    }
}

public struct CodexRawNotification: Equatable, Sendable {
    public var method: String
    public var params: Data
    public var threadID: CodexThreadID?
    public var turnID: CodexTurnID?

    public init(
        method: String,
        params: Data,
        threadID: CodexThreadID? = nil,
        turnID: CodexTurnID? = nil
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

package extension CodexRateLimits {
    init(appServer response: AppServerAPI.Account.RateLimits.Response) {
        self.init(
            planType: response.codexPlanType,
            windows: response.codexRateLimitWindows.map {
                .init(
                    windowDurationMinutes: $0.windowDurationMinutes,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
        )
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

/// The result of an app-server account login completion notification.
public struct CodexLoginCompletion: Equatable, Sendable {
    /// The app-server login identifier, when the notification is scoped to a login flow.
    public var loginID: CodexLoginHandle.ID?

    /// Whether the login completed successfully.
    public var success: Bool

    /// The server-provided failure message when `success` is false.
    public var error: String?

    public init(loginID: CodexLoginHandle.ID? = nil, success: Bool, error: String? = nil) {
        self.loginID = loginID
        self.success = success
        self.error = error
    }
}

/// A typed account-related notification emitted by Codex app-server.
public enum CodexAccountEvent: Equatable, Sendable {
    /// A login flow reached a terminal state.
    case loginCompleted(CodexLoginCompletion)

    /// The active account changed or was refreshed.
    case accountUpdated

    /// Account rate-limit information changed.
    case rateLimitsUpdated(CodexRateLimits)

    /// A known account notification arrived with a shape this SDK could not decode.
    case malformed(method: String, message: String)

    /// A notification outside the current account event surface.
    case unknown(CodexRawNotification)
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
