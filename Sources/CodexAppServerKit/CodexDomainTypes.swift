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

/// A JSON value used for app-server configuration and structured output schema.
public enum CodexJSONValue: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([CodexJSONValue])
    case object([String: CodexJSONValue])
    case null

    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CodexJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension CodexJSONValue {
    package var appServerJSONValue: AppServerJSONValue {
        switch self {
        case .string(let value):
            .string(value)
        case .int(let value):
            .int(value)
        case .double(let value):
            .double(value)
        case .bool(let value):
            .bool(value)
        case .array(let value):
            .array(value.map(\.appServerJSONValue))
        case .object(let value):
            .object(value.mapValues(\.appServerJSONValue))
        case .null:
            .null
        }
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

/// Permission profile selection for a newly created Codex thread.
public struct CodexThreadPermissions: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case profileID(String)
        case profileSelection(String)
    }

    package var kind: Kind

    package init(kind: Kind) {
        self.kind = kind
    }

    public static func profile(id: String) -> Self {
        .init(kind: .profileID(id))
    }

    package static func profileSelection(id: String) -> Self {
        .init(kind: .profileSelection(id))
    }

    package var appServerPermissions: AppServerAPI.Thread.Start.Permissions {
        switch kind {
        case .profileID(let id):
            .profileID(id)
        case .profileSelection(let id):
            .profileSelection(.init(id: id))
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

/// The amount of model reasoning requested for a Codex turn.
public struct CodexReasoningEffort: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let none = Self(rawValue: "none")
    public static let minimal = Self(rawValue: "minimal")
    public static let low = Self(rawValue: "low")
    public static let medium = Self(rawValue: "medium")
    public static let high = Self(rawValue: "high")
    public static let xhigh = Self(rawValue: "xhigh")
}

extension CodexReasoningEffort: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The reasoning summary mode requested for a Codex turn.
public struct CodexReasoningSummary: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let none = Self(rawValue: "none")
    public static let auto = Self(rawValue: "auto")
    public static let concise = Self(rawValue: "concise")
    public static let detailed = Self(rawValue: "detailed")
}

extension CodexReasoningSummary: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The app-server personality to apply to a thread or turn.
public struct CodexPersonality: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let none = Self(rawValue: "none")
    public static let friendly = Self(rawValue: "friendly")
    public static let pragmatic = Self(rawValue: "pragmatic")
}

/// The source that created a new app-server session.
public enum CodexThreadStartSource: String, Codable, Equatable, Sendable {
    case startup
    case clear

    package var appServerSource: AppServerAPI.Thread.Start.Source {
        switch self {
        case .startup:
            .startup
        case .clear:
            .clear
        }
    }
}

/// Client-supplied analytics classification for a Codex thread.
public struct CodexThreadSource: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let user = Self(rawValue: "user")
    public static let subagent = Self(rawValue: "subagent")
    public static let memoryConsolidation = Self(rawValue: "memory_consolidation")

    package var appServerSource: AppServerAPI.Thread.Source {
        .init(rawValue: rawValue)
    }
}

public struct CodexGenerationOptions: Equatable, Sendable {
    public var model: String?
    public var approvalMode: CodexApprovalMode?
    public var sandbox: CodexSandbox?
    public var cwd: URL?
    public var effort: CodexReasoningEffort?
    public var serviceTier: String?
    public var summary: CodexReasoningSummary?
    public var outputSchema: CodexJSONValue?
    public var personality: CodexPersonality?
    public var clientUserMessageID: String?

    public init(
        model: String? = nil,
        approvalMode: CodexApprovalMode? = nil,
        sandbox: CodexSandbox? = nil,
        cwd: URL? = nil,
        effort: CodexReasoningEffort? = nil,
        serviceTier: String? = nil,
        summary: CodexReasoningSummary? = nil,
        outputSchema: CodexJSONValue? = nil,
        personality: CodexPersonality? = nil,
        clientUserMessageID: String? = nil
    ) {
        self.model = model
        self.approvalMode = approvalMode
        self.sandbox = sandbox
        self.cwd = cwd
        self.effort = effort
        self.serviceTier = serviceTier
        self.summary = summary
        self.outputSchema = outputSchema
        self.personality = personality
        self.clientUserMessageID = clientUserMessageID
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
        public var permissions: CodexThreadPermissions?
        public var serviceTier: String?
        public var ephemeral: Bool?
        public var config: [String: CodexJSONValue]?
        public var personality: CodexPersonality?
        public var serviceName: String?
        public var sessionStartSource: CodexThreadStartSource?
        public var threadSource: CodexThreadSource?

        public init(
            model: String? = nil,
            modelProvider: String? = nil,
            approvalMode: CodexApprovalMode? = nil,
            sandbox: CodexSandbox? = nil,
            permissions: CodexThreadPermissions? = nil,
            serviceTier: String? = nil,
            ephemeral: Bool? = nil,
            config: [String: CodexJSONValue]? = nil,
            personality: CodexPersonality? = nil,
            serviceName: String? = nil,
            sessionStartSource: CodexThreadStartSource? = nil,
            threadSource: CodexThreadSource? = nil
        ) {
            self.model = model
            self.modelProvider = modelProvider
            self.approvalMode = approvalMode
            self.sandbox = sandbox
            self.permissions = permissions
            self.serviceTier = serviceTier
            self.ephemeral = ephemeral
            self.config = config
            self.personality = personality
            self.serviceName = serviceName
            self.sessionStartSource = sessionStartSource
            self.threadSource = threadSource
        }
    }

    public typealias ResumeOptions = Options

    public let id: CodexThreadID
    public let workspace: URL?
    public let model: String?

    package let client: AppServerClient
    package let router: CodexAppServerNotificationRouter
    package let turnReplayStore: TurnReplayStore
    package let connectionLease: AppServerConnectionLease

    package init(
        id: CodexThreadID,
        workspace: URL? = nil,
        model: String? = nil,
        client: AppServerClient,
        router: CodexAppServerNotificationRouter,
        connectionLease: AppServerConnectionLease
    ) {
        self.id = id
        self.workspace = workspace
        self.model = model
        self.client = client
        self.router = router
        self.turnReplayStore = router.turnReplayStore
        self.connectionLease = connectionLease
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

/// Persistable app-server identity for a Codex review run.
public struct CodexReviewIdentity: Codable, Equatable, Identifiable, Sendable {
    /// The source thread where the review was started.
    public var threadID: CodexThreadID

    /// The app-server turn producing the review response.
    public var turnID: CodexTurnID

    /// The detached review thread, when app-server created one.
    public var reviewThreadID: CodexThreadID?

    /// The active review thread model, when known.
    public var model: String?

    public var id: CodexTurnID {
        turnID
    }

    /// Alias for `threadID` that makes review lifecycle ownership explicit.
    public var sourceThreadID: CodexThreadID {
        threadID
    }

    /// The thread that owns the currently active review turn.
    public var activeTurnThreadID: CodexThreadID {
        reviewThreadID ?? sourceThreadID
    }

    /// Source and review thread identities in source-first order.
    public var associatedThreadIDs: [CodexThreadID] {
        if activeTurnThreadID == sourceThreadID {
            return [sourceThreadID]
        }
        return [sourceThreadID, activeTurnThreadID]
    }

    /// Thread identities to clean up after a review, with detached review
    /// threads before the source thread.
    public var cleanupThreadIDs: [CodexThreadID] {
        if activeTurnThreadID == sourceThreadID {
            return [sourceThreadID]
        }
        return [activeTurnThreadID, sourceThreadID]
    }

    public init(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        reviewThreadID: CodexThreadID? = nil,
        model: String? = nil
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.reviewThreadID = reviewThreadID
        self.model = model
    }
}

/// One thread deletion that failed during review lifecycle cleanup.
public struct CodexReviewCleanupFailure: Equatable, Sendable {
    /// Thread whose deletion failed.
    public var threadID: CodexThreadID

    /// Stable diagnostic message from the app-server operation.
    public var message: String

    public init(threadID: CodexThreadID, message: String) {
        self.threadID = threadID
        self.message = message
    }
}

/// Ordered result of deleting the threads retained by a review lifecycle.
public struct CodexReviewCleanupResult: Equatable, Sendable {
    /// Thread identifiers in the exact source-last order cleanup attempted.
    public var attemptedThreadIDs: [CodexThreadID]

    /// Failed deletions in attempted order.
    public var failures: [CodexReviewCleanupFailure]

    public var succeeded: Bool {
        failures.isEmpty
    }

    public init(
        attemptedThreadIDs: [CodexThreadID],
        failures: [CodexReviewCleanupFailure]
    ) {
        self.attemptedThreadIDs = attemptedThreadIDs
        self.failures = failures
    }
}

/// Transient token for a review restart prepared by ``CodexAppServer``.
public struct CodexReviewRestartToken: Equatable, Identifiable, Sendable {
    public typealias ID = String

    /// The app-server-local restart token identity.
    public var id: ID

    /// The review identity that was interrupted while preparing the restart.
    public var interruptedIdentity: CodexReviewIdentity

    public init(id: ID, interruptedIdentity: CodexReviewIdentity) {
        self.id = id
        self.interruptedIdentity = interruptedIdentity
    }
}

/// Thread events projected for a `CodexReviewSession`.
package enum CodexReviewEvent: Equatable, Sendable {
    case turnStarted(CodexTurnID)
    case snapshot(CodexTurnSnapshot)
    case terminal(CodexTurnOutcome)
    case itemStarted(CodexThreadItem, turnID: CodexTurnID?)
    case itemUpdated(CodexThreadItem, turnID: CodexTurnID?)
    case itemCompleted(CodexThreadItem, turnID: CodexTurnID?)
    case message(CodexMessage, turnID: CodexTurnID?)
    case messageDelta(CodexMessageDelta, turnID: CodexTurnID?)
    case reasoningSummaryPartAdded(CodexReasoningPart, turnID: CodexTurnID?)
    case reasoningDelta(CodexReasoningDelta, turnID: CodexTurnID?)
    case diagnostic(CodexTurnDiagnostic, turnID: CodexTurnID)
    case tokenUsageUpdated(CodexTokenUsage, turnID: CodexTurnID?)
    case statusChanged(CodexThreadStatus)
    case closed
    case unknown(CodexRawNotification)

    package init(_ event: CodexThreadEvent) {
        switch event {
        case .turnStarted(let turnID):
            self = .turnStarted(turnID)
        case .snapshot(let snapshot):
            self = .snapshot(snapshot)
        case .terminal(let outcome):
            self = .terminal(outcome)
        case .itemStarted(let item, let turnID):
            self = .itemStarted(item, turnID: turnID)
        case .itemUpdated(let item, let turnID):
            self = .itemUpdated(item, turnID: turnID)
        case .itemCompleted(let item, let turnID):
            self = .itemCompleted(item, turnID: turnID)
        case .message(let message, let turnID):
            self = .message(message, turnID: turnID)
        case .messageDelta(let delta, let turnID):
            self = .messageDelta(delta, turnID: turnID)
        case .reasoningSummaryPartAdded(let part, let turnID):
            self = .reasoningSummaryPartAdded(part, turnID: turnID)
        case .reasoningDelta(let delta, let turnID):
            self = .reasoningDelta(delta, turnID: turnID)
        case .diagnostic(let diagnostic, let turnID):
            self = .diagnostic(diagnostic, turnID: turnID)
        case .tokenUsageUpdated(let usage, let turnID):
            self = .tokenUsageUpdated(usage, turnID: turnID)
        case .statusChanged(let status):
            self = .statusChanged(status)
        case .closed:
            self = .closed
        case .unknown(let raw):
            self = .unknown(raw)
        }
    }

    package init(_ event: CodexTurnEvent, turnID: CodexTurnID) {
        switch event {
        case .started(let eventTurnID):
            self = .turnStarted(eventTurnID)
        case .snapshot(let snapshot):
            self = .snapshot(snapshot)
        case .terminal(let outcome):
            self = .terminal(outcome)
        case .itemStarted(let item):
            self = .itemStarted(item, turnID: turnID)
        case .itemUpdated(let item):
            self = .itemUpdated(item, turnID: turnID)
        case .itemCompleted(let item):
            self = .itemCompleted(item, turnID: turnID)
        case .message(let message):
            self = .message(message, turnID: turnID)
        case .messageDelta(let delta):
            self = .messageDelta(delta, turnID: turnID)
        case .reasoningSummaryPartAdded(let part):
            self = .reasoningSummaryPartAdded(part, turnID: turnID)
        case .reasoningDelta(let delta):
            self = .reasoningDelta(delta, turnID: turnID)
        case .diagnostic(let diagnostic):
            self = .diagnostic(diagnostic, turnID: turnID)
        case .tokenUsageUpdated(let usage):
            self = .tokenUsageUpdated(usage, turnID: turnID)
        case .unknown(let raw):
            self = .unknown(raw)
        }
    }
}

/// Incremental progress derived from the review turn's thread events.
package enum CodexReviewProgress: Equatable, Sendable {
    case running(transcript: CodexTranscript, usage: CodexTokenUsage?)
    case terminal(CodexTurnOutcome)
}

/// A review run started by `codex app-server`.
public struct CodexReviewSession: Identifiable, Sendable {
    /// The response turn identifier, used as the stable session identity.
    public var id: CodexTurnID {
        turnID
    }

    /// The thread where `startReview(target:delivery:)` was called.
    public let threadID: CodexThreadID

    /// The app-server turn that is producing the review response.
    public let turnID: CodexTurnID

    /// The thread that emits review events and logs.
    ///
    /// This equals `threadID` for inline reviews and may differ for detached
    /// reviews.
    public let reviewThreadID: CodexThreadID

    /// The active review thread model, when known.
    public let model: String?

    /// The initial turn returned synchronously by `review/start`.
    ///
    /// Inline reviews may not emit a separate `turn/started` notification, and
    /// freshly-created rollouts may not be readable yet. UI clients should seed
    /// their transcript from this turn before consuming live events.
    public let initialTurn: CodexTurnSnapshot

    /// The live response stream for the review turn.
    package let response: CodexResponseStream

    package init(
        threadID: CodexThreadID,
        turnID: CodexTurnID,
        reviewThreadID: CodexThreadID,
        model: String?,
        initialTurn: CodexTurnSnapshot,
        response: CodexResponseStream
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.reviewThreadID = reviewThreadID
        self.model = model
        self.initialTurn = initialTurn
        self.response = response
    }

    /// Persistable identity for this review run.
    public var identity: CodexReviewIdentity {
        .init(
            threadID: sourceThreadID,
            turnID: turnID,
            reviewThreadID: reviewThreadID == sourceThreadID ? nil : reviewThreadID,
            model: model
        )
    }

    /// Alias for `threadID` that makes the source/review split explicit.
    public var sourceThreadID: CodexThreadID {
        threadID
    }

    /// The thread that owns the currently active review turn.
    public var activeTurnThreadID: CodexThreadID {
        reviewThreadID
    }

    /// Source and review thread identities in source-first order.
    public var associatedThreadIDs: [CodexThreadID] {
        if activeTurnThreadID == sourceThreadID {
            return [sourceThreadID]
        }
        return [sourceThreadID, activeTurnThreadID]
    }

    /// Thread identities to clean up after this review, with detached review
    /// threads before the source thread.
    public var cleanupThreadIDs: [CodexThreadID] {
        if activeTurnThreadID == sourceThreadID {
            return [sourceThreadID]
        }
        return [activeTurnThreadID, sourceThreadID]
    }

    /// Thread events filtered to the review turn.
    package var events: CodexReviewEventSequence {
        .init(events: response.turn.events, turnID: turnID)
    }

    /// Agent messages emitted by the review thread.
    package var messages: CodexTurnMessageSequence {
        .init(events: response.turn.events)
    }

    /// Incremental transcript snapshots for the review thread.
    package var transcriptUpdates: CodexTurnTranscriptSequence {
        .init(events: response.turn.events)
    }

    /// Log-oriented item events emitted by the review thread.
    package var logEntries: CodexTurnLogSequence {
        .init(events: response.turn.events, turnID: turnID)
    }

    /// Incremental progress snapshots for the review thread.
    package var progress: CodexReviewProgressSequence {
        .init(
            turnID: turnID,
            store: response.turn.turnReplayStore,
            state: response.turn.state
        )
    }

    /// Collects the review response until the turn finishes.
    public func collect(timeout: Duration? = nil) async throws -> CodexTurnOutcome {
        try await response.collect(timeout: timeout)
    }

    /// Returns the terminal outcome already committed for this review generation.
    ///
    /// This operation never waits for a live turn and never sends a request. A
    /// connection termination committed before a turn outcome is surfaced as an
    /// error instead of being synthesized into a turn result.
    public func terminalOutcomeIfKnown() async throws -> CodexTurnOutcome? {
        try await response.turn.state.cachedOutcome()
    }

    /// Cancels the running review turn.
    ///
    /// - Returns: The turn that the app-server actually cancelled. This can
    ///   differ from `turnID` when the app-server reports a newer active turn.
    @discardableResult
    public func cancel() async throws -> CodexTurnCancellation {
        try await response.cancel()
    }

    @discardableResult
    package func cancel(
        willCancelActiveTurn: (@Sendable (CodexTurnCancellation) async -> Void)?
    ) async throws -> CodexTurnCancellation {
        try await response.cancel(willCancelActiveTurn: willCancelActiveTurn)
    }

    /// Sends additional input to the running review turn.
    package func steer(with prompt: CodexPrompt) async throws {
        try await response.steer(with: prompt)
    }

    /// Sends additional text input to the running review turn.
    package func steer(with prompt: String) async throws {
        try await response.steer(with: prompt)
    }

    /// Closes the app-server connection shared by this review session.
    public func closeConnection() async {
        await response.closeConnection()
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
    package let turnReplayStore: TurnReplayStore
    package let state: TurnGenerationHandleState

    package init(
        id: CodexTurnID,
        threadID: CodexThreadID,
        client: AppServerClient,
        router: CodexAppServerNotificationRouter,
        turnReplayStore: TurnReplayStore,
        state: TurnGenerationHandleState
    ) {
        precondition(
            router.turnReplayStore === turnReplayStore,
            "A turn and its router must share one replay store identity."
        )
        self.id = id
        self.threadID = threadID
        self.client = client
        self.router = router
        self.turnReplayStore = turnReplayStore
        self.state = state
    }
}

/// Git repository metadata captured for a thread by the app-server.
public struct CodexThreadGitInfo: Equatable, Sendable {
    /// The captured commit SHA, when the thread store recorded one.
    public var sha: String?
    /// The captured branch name, when the thread store recorded one.
    public var branch: String?
    /// The raw origin remote value. Git remotes are not required to use URL syntax.
    public var originURL: String?

    public init(
        sha: String? = nil,
        branch: String? = nil,
        originURL: String? = nil
    ) {
        self.sha = sha
        self.branch = branch
        self.originURL = originURL
    }
}

/// The exact session origin reported by the app-server for a thread.
///
/// This differs from ``CodexThreadSource``, which is a client-supplied analytics
/// classification used when starting a thread.
public enum CodexThreadSessionSource: Hashable, Sendable {
    public enum SubAgent: Hashable, Sendable {
        public struct ThreadSpawn: Hashable, Sendable {
            public var parentThreadID: CodexThreadID
            public var depth: Int
            public var agentPath: String?
            public var agentNickname: String?
            public var agentRole: String?

            public init(
                parentThreadID: CodexThreadID,
                depth: Int,
                agentPath: String? = nil,
                agentNickname: String? = nil,
                agentRole: String? = nil
            ) {
                self.parentThreadID = parentThreadID
                self.depth = depth
                self.agentPath = agentPath
                self.agentNickname = agentNickname
                self.agentRole = agentRole
            }
        }

        case review
        case compact
        case threadSpawn(ThreadSpawn)
        case memoryConsolidation
        case other(String)
    }

    case cli
    case vscode
    case exec
    case appServer
    case custom(String)
    case subAgent(SubAgent)
    case unknown

    /// A coarse compatibility projection suitable for source-kind filtering.
    ///
    /// Custom sources return `nil` because the app-server does not include them
    /// in any source-kind filter.
    public var sourceKind: CodexThreadSourceKind? {
        switch self {
        case .cli:
            .cli
        case .vscode:
            .vscode
        case .exec:
            .exec
        case .appServer:
            .appServer
        case .custom:
            nil
        case .unknown:
            .unknown
        case .subAgent(.review):
            .subAgentReview
        case .subAgent(.compact):
            .subAgentCompact
        case .subAgent(.threadSpawn):
            .subAgentThreadSpawn
        case .subAgent(.memoryConsolidation):
            .subAgent
        case .subAgent(.other):
            .subAgentOther
        }
    }

    /// Returns whether this exact source is included by an app-server source-kind filter.
    public func matches(sourceKind: CodexThreadSourceKind) -> Bool {
        if sourceKind == .subAgent, case .subAgent = self {
            return true
        }
        return self.sourceKind == sourceKind
    }
}

public struct CodexThreadSnapshot: Identifiable, Equatable, Sendable {
    package enum Field: String, Hashable, Sendable {
        case sessionID
        case parentThreadID
        case workspace
        case name
        case preview
        case modelProvider
        case source
        case sourceKind
        case gitInfo
        case createdAt
        case updatedAt
        case recencyAt
        case status
        case ephemeral
        case turns
    }

    public var id: CodexThreadID
    /// The app-server session identifier, when present in the snapshot.
    public var sessionID: String? {
        didSet { presentFields.insert(.sessionID) }
    }
    /// The direct parent thread identifier reported by the app-server.
    public var parentThreadID: CodexThreadID? {
        didSet { presentFields.insert(.parentThreadID) }
    }
    public var workspace: URL?
    public var name: String?
    public var preview: String?
    public var modelProvider: String?
    private var sourceStorage: CodexThreadSessionSource?
    private var sourceKindFallback: CodexThreadSourceKind?
    /// The exact thread session origin reported by the app-server.
    public var source: CodexThreadSessionSource? {
        get { sourceStorage }
        set {
            sourceStorage = newValue
            sourceKindFallback = nil
            presentFields.remove(.sourceKind)
            presentFields.insert(.source)
        }
    }
    /// A coarse source projection retained for source-kind filtering compatibility.
    public var sourceKind: CodexThreadSourceKind? {
        get { sourceStorage?.sourceKind ?? sourceKindFallback }
        set {
            if let sourceStorage, newValue == sourceStorage.sourceKind {
                presentFields.remove(.sourceKind)
                presentFields.insert(.source)
                return
            }
            sourceStorage = nil
            sourceKindFallback = newValue
            presentFields.remove(.source)
            presentFields.insert(.sourceKind)
        }
    }
    /// Git repository metadata captured for this thread by the app-server.
    public var gitInfo: CodexThreadGitInfo? {
        didSet { presentFields.insert(.gitInfo) }
    }
    public var createdAt: Date?
    public var updatedAt: Date?
    public var recencyAt: Date?
    public var status: CodexThreadStatus?
    public var ephemeral: Bool?
    public var turns: [CodexTurnSnapshot]?
    /// True only when `turns` may replace cached transcript items. The
    /// initializer clamps producer intent to the turns' actual load state, so
    /// summary or not-loaded items can never be marked authoritative.
    package var turnItemsAreAuthoritative: Bool
    package var presentFields: Set<Field>

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.sessionID == rhs.sessionID
            && lhs.parentThreadID == rhs.parentThreadID
            && lhs.workspace == rhs.workspace
            && lhs.name == rhs.name
            && lhs.preview == rhs.preview
            && lhs.modelProvider == rhs.modelProvider
            && lhs.source == rhs.source
            && lhs.sourceKind == rhs.sourceKind
            && lhs.gitInfo == rhs.gitInfo
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.recencyAt == rhs.recencyAt
            && lhs.status == rhs.status
            && lhs.ephemeral == rhs.ephemeral
            && lhs.turns == rhs.turns
    }

    public init(
        id: CodexThreadID,
        workspace: URL? = nil,
        name: String? = nil,
        preview: String? = nil,
        modelProvider: String? = nil,
        sessionID: String? = nil,
        parentThreadID: CodexThreadID? = nil,
        source: CodexThreadSessionSource? = nil,
        sourceKind: CodexThreadSourceKind? = nil,
        gitInfo: CodexThreadGitInfo? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        recencyAt: Date? = nil,
        status: CodexThreadStatus? = nil,
        ephemeral: Bool? = nil,
        turns: [CodexTurnSnapshot]? = nil
    ) {
        self.init(
            id: id,
            workspace: workspace,
            name: name,
            preview: preview,
            modelProvider: modelProvider,
            sessionID: sessionID,
            parentThreadID: parentThreadID,
            source: source,
            sourceKind: sourceKind,
            gitInfo: gitInfo,
            createdAt: createdAt,
            updatedAt: updatedAt,
            recencyAt: recencyAt,
            status: status,
            ephemeral: ephemeral,
            turns: turns,
            turnItemsAreAuthoritative: true,
            presentFields: Self.presentFields(
                sessionID: sessionID,
                parentThreadID: parentThreadID,
                workspace: workspace,
                name: name,
                preview: preview,
                modelProvider: modelProvider,
                source: source,
                sourceKind: sourceKind,
                gitInfo: gitInfo,
                createdAt: createdAt,
                updatedAt: updatedAt,
                recencyAt: recencyAt,
                status: status,
                ephemeral: ephemeral,
                turns: turns
            )
        )
    }

    package init(
        id: CodexThreadID,
        workspace: URL? = nil,
        name: String? = nil,
        preview: String? = nil,
        modelProvider: String? = nil,
        sessionID: String? = nil,
        parentThreadID: CodexThreadID? = nil,
        source: CodexThreadSessionSource? = nil,
        sourceKind: CodexThreadSourceKind? = nil,
        gitInfo: CodexThreadGitInfo? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        recencyAt: Date? = nil,
        status: CodexThreadStatus? = nil,
        ephemeral: Bool? = nil,
        turns: [CodexTurnSnapshot]? = nil,
        turnItemsAreAuthoritative: Bool,
        presentFields: Set<Field>? = nil
    ) {
        precondition(
            source == nil || sourceKind == nil || source?.sourceKind == sourceKind,
            "An exact thread source and its compatibility kind must agree."
        )
        self.id = id
        self.sessionID = sessionID
        self.parentThreadID = parentThreadID
        self.workspace = workspace
        self.name = name
        self.preview = preview
        self.modelProvider = modelProvider
        self.sourceStorage = source
        self.sourceKindFallback = source == nil ? sourceKind : nil
        self.gitInfo = gitInfo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recencyAt = recencyAt
        self.status = status
        self.ephemeral = ephemeral
        self.turns = turns
        self.turnItemsAreAuthoritative = turnItemsAreAuthoritative
            && (turns?.allSatisfy(\.itemsAreAuthoritative) ?? false)
        self.presentFields = presentFields ?? Self.presentFields(
            sessionID: sessionID,
            parentThreadID: parentThreadID,
            workspace: workspace,
            name: name,
            preview: preview,
            modelProvider: modelProvider,
            source: source,
            sourceKind: sourceKind,
            gitInfo: gitInfo,
            createdAt: createdAt,
            updatedAt: updatedAt,
            recencyAt: recencyAt,
            status: status,
            ephemeral: ephemeral,
            turns: turns
        )
    }

    package func hasField(_ field: Field) -> Bool {
        presentFields.contains(field)
    }

    private static func presentFields(
        sessionID: String?,
        parentThreadID: CodexThreadID?,
        workspace: URL?,
        name: String?,
        preview: String?,
        modelProvider: String?,
        source: CodexThreadSessionSource?,
        sourceKind: CodexThreadSourceKind?,
        gitInfo: CodexThreadGitInfo?,
        createdAt: Date?,
        updatedAt: Date?,
        recencyAt: Date?,
        status: CodexThreadStatus?,
        ephemeral: Bool?,
        turns: [CodexTurnSnapshot]?
    ) -> Set<Field> {
        var fields: Set<Field> = []
        if sessionID != nil {
            fields.insert(.sessionID)
        }
        if parentThreadID != nil {
            fields.insert(.parentThreadID)
        }
        if workspace != nil {
            fields.insert(.workspace)
        }
        if name != nil {
            fields.insert(.name)
        }
        if preview != nil {
            fields.insert(.preview)
        }
        if modelProvider != nil {
            fields.insert(.modelProvider)
        }
        if source != nil {
            fields.insert(.source)
        } else if sourceKind != nil {
            fields.insert(.sourceKind)
        }
        if gitInfo != nil {
            fields.insert(.gitInfo)
        }
        if createdAt != nil {
            fields.insert(.createdAt)
        }
        if updatedAt != nil {
            fields.insert(.updatedAt)
        }
        if recencyAt != nil {
            fields.insert(.recencyAt)
        }
        if status != nil {
            fields.insert(.status)
        }
        if ephemeral != nil {
            fields.insert(.ephemeral)
        }
        if turns != nil {
            fields.insert(.turns)
        }
        return fields
    }
}

public struct CodexTurnSnapshot: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case inProgress
        case completed
        case interrupted
        case failed(CodexTurnError)
        case unknown(rawValue: String, error: CodexTurnError?)
    }

    public var id: CodexTurnID
    public var state: State
    public var itemsLoadState: CodexTurnItemsLoadState
    public var items: [CodexThreadItem]
    public var startedAt: Date?
    public var completedAt: Date?
    public var duration: Duration?

    public var status: CodexTurnStatus {
        switch state {
        case .inProgress:
            .inProgress
        case .completed:
            .completed
        case .interrupted:
            .interrupted
        case .failed:
            .failed
        case .unknown(let rawValue, _):
            .unknown(rawValue: rawValue)
        }
    }

    public var error: CodexTurnError? {
        switch state {
        case .failed(let error):
            error
        case .unknown(_, let error):
            error
        case .inProgress, .completed, .interrupted:
            nil
        }
    }

    public init(
        id: CodexTurnID,
        state: State,
        itemsLoadState: CodexTurnItemsLoadState = .full,
        items: [CodexThreadItem] = [],
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        duration: Duration? = nil
    ) {
        self.id = id
        self.state = state
        self.itemsLoadState = itemsLoadState
        self.items = items
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.duration = duration
    }

    package var itemsAreAuthoritative: Bool {
        itemsLoadState == .full
    }
}

public enum CodexTurnItemsLoadState: String, Codable, Equatable, Sendable {
    case notLoaded
    case summary
    case full
}

public struct CodexTurnQuery: Equatable, Sendable {
    public var cursor: String?
    public var limit: Int?
    public var sortDirection: CodexSortDirection?
    public var itemsLoadState: CodexTurnItemsLoadState?

    public init(
        cursor: String? = nil,
        limit: Int? = nil,
        sortDirection: CodexSortDirection? = nil,
        itemsLoadState: CodexTurnItemsLoadState? = nil
    ) {
        self.cursor = cursor
        self.limit = limit
        self.sortDirection = sortDirection
        self.itemsLoadState = itemsLoadState
    }
}

public struct CodexTurnPage: Equatable, Sendable {
    public var turns: [CodexTurnSnapshot]
    public var nextCursor: String?
    public var backwardsCursor: String?

    public init(
        turns: [CodexTurnSnapshot],
        nextCursor: String? = nil,
        backwardsCursor: String? = nil
    ) {
        self.turns = turns
        self.nextCursor = nextCursor
        self.backwardsCursor = backwardsCursor
    }
}

public struct CodexThreadQuery: Equatable, Sendable {
    public var archived: Bool?
    public var cursor: String?
    public var workspaces: [URL]? {
        get {
            _workspaces
        }
        set {
            _workspaces = Self.normalizedWorkspaces(newValue)
        }
    }
    public var workspace: URL? {
        get {
            workspaces?.first
        }
        set {
            _workspaces = Self.normalizedWorkspaces(newValue.map { [$0] })
        }
    }
    public var limit: Int?
    public var searchTerm: String?
    public var modelProviders: [String]?
    public var sortDirection: CodexSortDirection?
    public var sortKey: CodexThreadSortKey?
    public var sourceKinds: [CodexThreadSourceKind]?
    public var useStateDBOnly: Bool?
    private var _workspaces: [URL]?

    public init(
        archived: Bool? = nil,
        cursor: String? = nil,
        workspace: URL? = nil,
        workspaces: [URL]? = nil,
        limit: Int? = nil,
        searchTerm: String? = nil,
        modelProviders: [String]? = nil,
        sortDirection: CodexSortDirection? = nil,
        sortKey: CodexThreadSortKey? = nil,
        sourceKinds: [CodexThreadSourceKind]? = nil,
        useStateDBOnly: Bool? = nil
    ) {
        self.archived = archived
        self.cursor = cursor
        self._workspaces = Self.normalizedWorkspaces(workspaces ?? workspace.map { [$0] })
        self.limit = limit
        self.searchTerm = searchTerm
        self.modelProviders = modelProviders
        self.sortDirection = sortDirection
        self.sortKey = sortKey
        self.sourceKinds = sourceKinds
        self.useStateDBOnly = useStateDBOnly
    }

    private static func normalizedWorkspaces(_ workspaces: [URL]?) -> [URL]? {
        guard let workspaces else {
            return nil
        }
        let normalized = workspaces.filter { $0.path.isEmpty == false }
        return normalized.isEmpty ? nil : normalized
    }
}

/// Sort direction for thread list queries.
public enum CodexSortDirection: String, Codable, Equatable, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

/// Sort key for thread list queries.
public enum CodexThreadSortKey: String, Codable, Equatable, Sendable {
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case recencyAt = "recency_at"
}

/// Source-kind filter for thread list queries.
public struct CodexThreadSourceKind: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let cli = Self(rawValue: "cli")
    public static let vscode = Self(rawValue: "vscode")
    public static let exec = Self(rawValue: "exec")
    public static let appServer = Self(rawValue: "appServer")
    public static let subAgent = Self(rawValue: "subAgent")
    public static let subAgentReview = Self(rawValue: "subAgentReview")
    public static let subAgentCompact = Self(rawValue: "subAgentCompact")
    public static let subAgentThreadSpawn = Self(rawValue: "subAgentThreadSpawn")
    public static let subAgentOther = Self(rawValue: "subAgentOther")
    public static let unknown = Self(rawValue: "unknown")
}

extension CodexThreadSourceKind: Codable {}

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
            guard message.text.isEmpty == false else {
                continue
            }
            if message.phase == .finalAnswer {
                return message.text
            }
            if message.phase == nil, fallback == nil {
                fallback = message.text
            }
        }
        return fallback
    }

    public var reviewOutputText: String? {
        for item in items.reversed() where item.kind == .exitedReviewMode {
            if let text = item.text, text.isEmpty == false {
                return text
            }
        }
        return nil
    }

    public var responseText: String? {
        messages.reversed().first {
            $0.role == .assistant && $0.text.isEmpty == false
        }?.text
    }
}

public struct CodexThreadItem: Identifiable, Equatable, Sendable {
    public enum Origin: Hashable, Sendable {
        case currentV2Item
        case reviewRolloutAssistant
    }

    public enum SemanticTarget: Hashable, Sendable {
        case exitedReviewMode
    }

    public enum SemanticRelation: Hashable, Sendable {
        case companionOf(SemanticTarget)
    }

    public enum Kind: Hashable, Sendable {
        case userMessage
        case agentMessage
        case enteredReviewMode
        case exitedReviewMode
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
            case "enteredReviewMode":
                self = .enteredReviewMode
            case "exitedReviewMode":
                self = .exitedReviewMode
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
            case .enteredReviewMode:
                "enteredReviewMode"
            case .exitedReviewMode:
                "exitedReviewMode"
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
        case reasoning(CodexReasoning)
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
    public private(set) var origin: Origin
    public private(set) var semanticRelation: SemanticRelation?
    public var rawPayload: Data?

    public init(
        id: String,
        kind: Kind,
        content: Content,
        rawPayload: Data? = nil
    ) {
        let semanticMetadata = Self.semanticMetadata(id: id, kind: kind)
        self.id = id
        self.kind = kind
        self.content = content
        self.origin = semanticMetadata.origin
        self.semanticRelation = semanticMetadata.relation
        self.rawPayload = rawPayload
    }

    package init(
        id: String,
        kind: Kind,
        content: Content,
        origin: Origin,
        semanticRelation: SemanticRelation?,
        rawPayload: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.origin = origin
        self.semanticRelation = semanticRelation
        self.rawPayload = rawPayload
    }

    private static func semanticMetadata(
        id: String,
        kind: Kind
    ) -> (origin: Origin, relation: SemanticRelation?) {
        guard kind == .agentMessage, id == "review_rollout_assistant" else {
            return (.currentV2Item, nil)
        }
        return (.reviewRolloutAssistant, .companionOf(.exitedReviewMode))
    }

    public var text: String? {
        switch content {
        case .message(let message):
            message.text
        case .plan(let text), .diagnostic(let text), .log(let text):
            text
        case .reasoning(let reasoning):
            reasoning.text
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

public struct CodexReasoning: Equatable, Sendable {
    public var summary: [String] {
        didSet {
            summary = Self.normalizedFragments(summary)
        }
    }
    public var content: [String] {
        didSet {
            content = Self.normalizedFragments(content)
        }
    }

    public static let empty = Self(summary: [], content: [])

    public init(summary: [String] = [], content: [String] = []) {
        self.summary = Self.normalizedFragments(summary)
        self.content = Self.normalizedFragments(content)
    }

    public init(summary: String, content: String? = nil) {
        self.init(
            summary: [summary],
            content: content.map { [$0] } ?? []
        )
    }

    public init(content: String) {
        self.init(summary: [], content: [content])
    }

    public var text: String {
        let preferred = summary.isEmpty ? content : summary
        return preferred.joined(separator: "\n\n")
    }

    private static func normalizedFragments(_ fragments: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        normalized.reserveCapacity(fragments.count)
        for fragment in fragments {
            let key = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.isEmpty == false, seen.insert(key).inserted else {
                continue
            }
            normalized.append(fragment)
        }
        return normalized
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
    public struct Source: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }

        public static let agent = Self(rawValue: "agent")
        public static let user = Self(rawValue: "user")
    }

    public struct Action: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case read
            case listFiles
            case search
            case unknown
        }

        public var kind: Kind
        public var command: String?
        public var name: String?
        public var path: String?
        public var query: String?

        public init(
            kind: Kind,
            command: String? = nil,
            name: String? = nil,
            path: String? = nil,
            query: String? = nil
        ) {
            self.kind = kind
            self.command = command
            self.name = name
            self.path = path
            self.query = query
        }
    }

    public var command: String
    public var cwd: String?
    public var output: String?
    public var exitCode: Int?
    public var status: CodexTurnStatus?
    public var startedAt: Date?
    public var completedAt: Date?
    public var duration: Duration?
    public var processID: String?
    public var source: Source?
    public var commandActions: [Action]

    public var durationMilliseconds: Int? {
        guard let duration else {
            return nil
        }
        let components = duration.components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        guard milliseconds >= 0, milliseconds <= Int.max else {
            return nil
        }
        return Int(milliseconds)
    }

    public init(
        command: String,
        cwd: String? = nil,
        output: String? = nil,
        exitCode: Int? = nil,
        status: CodexTurnStatus? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        duration: Duration? = nil,
        processID: String? = nil,
        source: Source? = nil,
        commandActions: [Action] = []
    ) {
        self.command = command
        self.cwd = cwd
        self.output = output
        self.exitCode = exitCode
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.duration = duration
        self.processID = processID
        self.source = source
        self.commandActions = commandActions
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

public struct CodexFileUpdateChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case add
        case delete
        case update(movePath: String?)
    }

    public var path: String
    public var kind: Kind
    public var diff: String

    public init(path: String, kind: Kind, diff: String) {
        self.path = path
        self.kind = kind
        self.diff = diff
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
    case inProgress
    case completed
    case interrupted
    case failed
    case unknown(rawValue: String)

    public init(rawValue: String) {
        switch rawValue {
        case "inProgress", "running", "started":
            self = .inProgress
        case "completed":
            self = .completed
        case "interrupted":
            self = .interrupted
        case "failed":
            self = .failed
        case let rawValue:
            self = .unknown(rawValue: rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .inProgress:
            "inProgress"
        case .completed:
            "completed"
        case .interrupted:
            "interrupted"
        case .failed:
            "failed"
        case .unknown(let rawValue):
            rawValue
        }
    }
}

public struct CodexResponse: Identifiable, Equatable, Sendable {
    public var turnID: CodexTurnID
    public var transcript: CodexTranscript
    /// Completeness of the transcript items carried by this response.
    public var transcriptItemsLoadState: CodexTurnItemsLoadState
    public var usage: CodexTokenUsage?
    public var startedAt: Date?
    public var completedAt: Date?
    public var duration: Duration?

    public var id: CodexTurnID {
        turnID
    }

    public init(
        turnID: CodexTurnID,
        usage: CodexTokenUsage? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        duration: Duration? = nil
    ) {
        self.init(
            turnID: turnID,
            transcript: .init(),
            transcriptItemsLoadState: .notLoaded,
            usage: usage,
            startedAt: startedAt,
            completedAt: completedAt,
            duration: duration
        )
    }

    public init(
        turnID: CodexTurnID,
        transcript: CodexTranscript,
        transcriptItemsLoadState: CodexTurnItemsLoadState = .full,
        usage: CodexTokenUsage? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        duration: Duration? = nil
    ) {
        self.turnID = turnID
        self.transcript = transcript
        self.transcriptItemsLoadState = transcriptItemsLoadState
        self.usage = usage
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.duration = duration
    }
}

public enum CodexErrorInfo: Equatable, Sendable {
    case contextWindowExceeded
    case sessionBudgetExceeded
    case usageLimitExceeded
    case serverOverloaded
    case cyberPolicy
    case httpConnectionFailed(httpStatusCode: UInt16?)
    case responseStreamConnectionFailed(httpStatusCode: UInt16?)
    case internalServerError
    case unauthorized
    case badRequest
    case threadRollbackFailed
    case sandboxError
    case responseStreamDisconnected(httpStatusCode: UInt16?)
    case responseTooManyFailedAttempts(httpStatusCode: UInt16?)
    case activeTurnNotSteerable(turnKind: String)
    case other
    case unknown(rawValue: String)
}

public struct CodexTurnError: Error, Equatable, LocalizedError, Sendable {
    public var message: String
    public var info: CodexErrorInfo?
    public var additionalDetails: String?

    public init(
        message: String,
        info: CodexErrorInfo? = nil,
        additionalDetails: String? = nil
    ) {
        self.message = message
        self.info = info
        self.additionalDetails = additionalDetails
    }

    public var errorDescription: String? { message }
}

/// A nonterminal error notification emitted while a turn is running.
public struct CodexTurnDiagnostic: Equatable, Sendable {
    /// The app-server error payload.
    public var error: CodexTurnError

    /// Whether the app-server will retry the operation that produced this diagnostic.
    public var willRetry: Bool

    public init(error: CodexTurnError, willRetry: Bool) {
        self.error = error
        self.willRetry = willRetry
    }
}

public enum CodexTurnOutcome: Equatable, Sendable {
    case completed(CodexResponse)
    case interrupted(CodexResponse)
    case failed(CodexFailedTurn)
    case invalidTerminalStatus(
        rawStatus: String,
        error: CodexTurnError?,
        response: CodexResponse
    )

    public var response: CodexResponse {
        switch self {
        case .completed(let response), .interrupted(let response),
             .invalidTerminalStatus(_, _, let response):
            response
        case .failed(let failedTurn):
            failedTurn.response
        }
    }
}

public struct CodexFailedTurn: Equatable, Sendable {
    public var response: CodexResponse
    public var error: CodexTurnError

    package init(response: CodexResponse, error: CodexTurnError) {
        self.response = response
        self.error = error
    }
}

/// The turn cancelled by an app-server control request.
public struct CodexTurnCancellation: Equatable, Sendable {
    /// The thread that owns the cancelled turn.
    public var threadID: CodexThreadID

    /// The cancelled turn, when the app-server reported one.
    public var turnID: CodexTurnID?

    public init(threadID: CodexThreadID, turnID: CodexTurnID?) {
        self.threadID = threadID
        self.turnID = turnID
    }

    package init(threadID: String, turnID: String?) {
        self.threadID = .init(rawValue: threadID)
        self.turnID = turnID.flatMap { value in
            value.isEmpty ? nil : CodexTurnID(rawValue: value)
        }
    }
}

package struct CodexResponseStream: AsyncSequence, Sendable {
    package struct Snapshot: Equatable, Sendable {
        package var turnID: CodexTurnID
        package var content: String?
        package var transcript: CodexTranscript
        package var usage: CodexTokenUsage?
        package var response: CodexResponse?

        package init(
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

    package let turn: CodexTurn

    package init(turn: CodexTurn) {
        self.turn = turn
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(
            turn: turn,
            progress: turn.progress.makeAsyncIterator()
        )
    }

    package func collect(timeout: Duration? = nil) async throws -> CodexTurnOutcome {
        if let timeout {
            return try await turn.client.runTurnWithDeadline(
                turnID: turn.id,
                duration: timeout
            ) {
                try await turn.result()
            }
        }
        return try await turn.result()
    }

    /// Cancels the running response.
    ///
    /// - Returns: The turn that the app-server actually cancelled. This can
    ///   differ from the stream's original turn when the app-server reports a
    ///   newer active turn.
    @discardableResult
    package func cancel() async throws -> CodexTurnCancellation {
        try await turn.interrupt()
    }

    @discardableResult
    package func cancel(
        willCancelActiveTurn: (@Sendable (CodexTurnCancellation) async -> Void)?
    ) async throws -> CodexTurnCancellation {
        try await turn.interrupt(willCancelActiveTurn: willCancelActiveTurn)
    }

    package func steer(with prompt: CodexPrompt) async throws {
        try await turn.steer(with: prompt)
    }

    package func steer(with prompt: String) async throws {
        try await steer(with: CodexPrompt(prompt))
    }

    package func steer(@CodexPromptBuilder prompt: () throws -> CodexPrompt) async throws {
        try await steer(with: try prompt())
    }

    package func waitForCancelledResponse(
        _ cancellation: CodexTurnCancellation,
        preparedState: TurnGenerationHandleState? = nil
    ) async throws -> CodexTurnOutcome {
        let cancelledTurn = try await cancelledTurn(
            for: cancellation,
            preparedState: preparedState
        )
        for try await event in cancelledTurn.events {
            switch event {
            case .terminal(let outcome):
                switch outcome {
                case .interrupted, .completed, .invalidTerminalStatus:
                    return outcome
                case .failed(let failedTurn):
                    throw failedTurn.error
                }
            case .started, .snapshot, .itemStarted, .itemUpdated, .itemCompleted, .message, .messageDelta,
                .reasoningSummaryPartAdded, .reasoningDelta, .diagnostic,
                .tokenUsageUpdated, .unknown:
                continue
            }
        }
        throw CodexAppServerError.connectionTerminated(.transportFailure(.closed))
    }

    package func closeConnection() async {
        await turn.state.closeConnection()
    }

    private func cancelledTurn(
        for cancellation: CodexTurnCancellation,
        preparedState: TurnGenerationHandleState?
    ) async throws -> CodexTurn {
        let cancelledTurnID = cancellation.turnID ?? turn.id
        if cancelledTurnID == turn.id {
            if let preparedState {
                precondition(
                    preparedState === turn.state,
                    "The original cancellation generation must preserve its state identity."
                )
            }
            return turn
        }
        let state: TurnGenerationHandleState
        if let preparedState {
            state = preparedState
        } else {
            let connectionLease = try await turn.state.connectionLeaseForSiblingGeneration()
            state = await turn.turnReplayStore.restoreGeneration(
                turnID: cancelledTurnID,
                initialSnapshot: .init(
                    id: cancelledTurnID,
                    state: .inProgress,
                    itemsLoadState: .notLoaded
                ),
                connectionLease: connectionLease
            )
        }
        return CodexTurn(
            id: cancelledTurnID,
            threadID: cancellation.threadID,
            client: turn.client,
            router: turn.router,
            turnReplayStore: turn.turnReplayStore,
            state: state
        )
    }

    package struct Iterator: AsyncIteratorProtocol {
        private let turn: CodexTurn
        private var progress: CodexTurnProgressSequence.Iterator

        fileprivate init(
            turn: CodexTurn,
            progress: CodexTurnProgressSequence.Iterator
        ) {
            self.turn = turn
            self.progress = progress
        }

        package mutating func next() async throws -> Snapshot? {
            guard let progress = try await progress.next() else {
                try Task.checkCancellation()
                return nil
            }
            switch progress {
            case .running(let transcript, let usage):
                return Snapshot(
                    turnID: turn.id,
                    content: transcript.responseText,
                    transcript: transcript,
                    usage: usage
                )
            case .terminal(let outcome):
                let response = outcome.response
                return Snapshot(
                    turnID: turn.id,
                    content: response.transcript.responseText,
                    transcript: response.transcript,
                    usage: response.usage,
                    response: response
                )
            }
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

package struct CodexMessageDelta: Equatable, Sendable {
    package var text: String
    package let itemID: String
    package var phase: CodexMessagePhase?
    package var currentItem: CodexThreadItem?

    package init(text: String, itemID: String, phase: CodexMessagePhase? = nil) {
        Self.preconditionValidItemID(itemID)
        self.text = text
        self.itemID = itemID
        self.phase = phase
        currentItem = nil
    }

    package init(
        text: String,
        itemID: String,
        phase: CodexMessagePhase?,
        currentItem: CodexThreadItem
    ) {
        Self.preconditionValidItemID(itemID)
        self.text = text
        self.itemID = itemID
        self.phase = phase
        self.currentItem = currentItem
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
            && lhs.itemID == rhs.itemID
            && lhs.phase == rhs.phase
    }

    private static func preconditionValidItemID(_ itemID: String) {
        precondition(
            itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            "CodexMessageDelta.itemID must not be empty or whitespace."
        )
    }
}

/// A reasoning summary or raw reasoning text part emitted by app-server.
package struct CodexReasoningPart: Identifiable, Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case summary
        case text
    }

    package var itemID: String
    package var kind: Kind
    package var index: Int
    package var currentItem: CodexThreadItem?

    package var id: String {
        switch kind {
        case .summary:
            "\(itemID):summary:\(index)"
        case .text:
            "\(itemID):content:\(index)"
        }
    }

    package init(itemID: String, kind: Kind, index: Int) {
        self.itemID = itemID
        self.kind = kind
        self.index = index
        currentItem = nil
    }

    package init(
        itemID: String,
        kind: Kind,
        index: Int,
        currentItem: CodexThreadItem
    ) {
        self.itemID = itemID
        self.kind = kind
        self.index = index
        self.currentItem = currentItem
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.itemID == rhs.itemID
            && lhs.kind == rhs.kind
            && lhs.index == rhs.index
    }
}

/// Incremental text for a reasoning summary or raw reasoning text part.
package struct CodexReasoningDelta: Identifiable, Equatable, Sendable {
    package var part: CodexReasoningPart
    package var delta: String
    package var currentItem: CodexThreadItem?

    package var id: String {
        part.id
    }

    package init(part: CodexReasoningPart, delta: String) {
        self.part = part
        self.delta = delta
        currentItem = nil
    }

    package init(
        part: CodexReasoningPart,
        delta: String,
        currentItem: CodexThreadItem
    ) {
        self.part = part
        self.delta = delta
        self.currentItem = currentItem
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.part == rhs.part && lhs.delta == rhs.delta
    }
}

package enum CodexTurnEvent: Equatable, Sendable {
    case started(CodexTurnID)
    case snapshot(CodexTurnSnapshot)
    case itemStarted(CodexThreadItem)
    case itemUpdated(CodexThreadItem)
    case itemCompleted(CodexThreadItem)
    case message(CodexMessage)
    case messageDelta(CodexMessageDelta)
    case reasoningSummaryPartAdded(CodexReasoningPart)
    case reasoningDelta(CodexReasoningDelta)
    case diagnostic(CodexTurnDiagnostic)
    case tokenUsageUpdated(CodexTokenUsage)
    case terminal(CodexTurnOutcome)
    case unknown(CodexRawNotification)
}

package enum CodexThreadEvent: Equatable, Sendable {
    case turnStarted(CodexTurnID)
    case snapshot(CodexTurnSnapshot)
    case terminal(CodexTurnOutcome)
    case itemStarted(CodexThreadItem, turnID: CodexTurnID?)
    case itemUpdated(CodexThreadItem, turnID: CodexTurnID?)
    case itemCompleted(CodexThreadItem, turnID: CodexTurnID?)
    case message(CodexMessage, turnID: CodexTurnID?)
    case messageDelta(CodexMessageDelta, turnID: CodexTurnID?)
    case reasoningSummaryPartAdded(CodexReasoningPart, turnID: CodexTurnID?)
    case reasoningDelta(CodexReasoningDelta, turnID: CodexTurnID?)
    case diagnostic(CodexTurnDiagnostic, turnID: CodexTurnID)
    case tokenUsageUpdated(CodexTokenUsage, turnID: CodexTurnID?)
    case statusChanged(CodexThreadStatus)
    case closed
    case unknown(CodexRawNotification)
}

package enum CodexThreadLogEntry: Identifiable, Equatable, Sendable {
    package enum Phase: Equatable, Sendable {
        case started
        case updated
        case completed
        case delta
        case diagnostic
    }

    case itemStarted(CodexThreadItem, turnID: CodexTurnID?)
    case itemUpdated(CodexThreadItem, turnID: CodexTurnID?)
    case itemCompleted(CodexThreadItem, turnID: CodexTurnID?)
    case messageDelta(CodexMessageDelta, turnID: CodexTurnID?, id: String)
    case reasoningPartStarted(CodexReasoningPart, turnID: CodexTurnID?)
    case reasoningDelta(CodexReasoningDelta, turnID: CodexTurnID?)
    case diagnostic(CodexTurnDiagnostic, turnID: CodexTurnID, id: String)

    package var id: String {
        switch self {
        case .itemStarted(let item, _), .itemUpdated(let item, _), .itemCompleted(let item, _):
            item.id
        case .messageDelta(_, _, let id):
            id
        case .reasoningPartStarted(let part, _):
            part.id
        case .reasoningDelta(let delta, _):
            delta.id
        case .diagnostic(_, _, let id):
            id
        }
    }

    package var turnID: CodexTurnID? {
        switch self {
        case .itemStarted(_, let turnID), .itemUpdated(_, let turnID),
             .itemCompleted(_, let turnID), .messageDelta(_, let turnID, _),
             .reasoningPartStarted(_, let turnID), .reasoningDelta(_, let turnID):
            turnID
        case .diagnostic(_, let turnID, _):
            turnID
        }
    }

    package var phase: Phase {
        switch self {
        case .itemStarted, .reasoningPartStarted:
            .started
        case .itemUpdated:
            .updated
        case .itemCompleted:
            .completed
        case .messageDelta, .reasoningDelta:
            .delta
        case .diagnostic:
            .diagnostic
        }
    }

    package var item: CodexThreadItem? {
        switch self {
        case .itemStarted(let item, _), .itemUpdated(let item, _), .itemCompleted(let item, _):
            item
        case .reasoningPartStarted(let part, _):
            .init(id: part.id, kind: .reasoning, content: .reasoning(.empty))
        case .messageDelta, .reasoningDelta:
            nil
        case .diagnostic:
            nil
        }
    }

    package var messageDelta: CodexMessageDelta? {
        if case .messageDelta(let delta, _, _) = self {
            return delta
        }
        return nil
    }

    package var reasoningDelta: CodexReasoningDelta? {
        if case .reasoningDelta(let delta, _) = self {
            return delta
        }
        return nil
    }

    package var diagnostic: CodexTurnDiagnostic? {
        if case .diagnostic(let diagnostic, _, _) = self {
            return diagnostic
        }
        return nil
    }
}

public struct CodexThreadActiveFlag: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let waitingOnApproval = Self(rawValue: "waitingOnApproval")
    public static let waitingOnUserInput = Self(rawValue: "waitingOnUserInput")
}

public enum CodexThreadStatus: Equatable, Sendable {
    case notLoaded
    case idle
    case systemError
    case active(activeFlags: [CodexThreadActiveFlag])
    case unknown(rawValue: String)

    public init(rawValue: String) {
        switch rawValue {
        case "notLoaded":
            self = .notLoaded
        case "idle":
            self = .idle
        case "systemError":
            self = .systemError
        case "active":
            self = .active(activeFlags: [])
        case let rawValue:
            self = .unknown(rawValue: rawValue)
        }
    }

    package init(type: String, activeFlags: [String]? = nil) {
        switch type {
        case "active":
            self = .active(activeFlags: activeFlags?.map(CodexThreadActiveFlag.init(rawValue:)) ?? [])
        default:
            self.init(rawValue: type)
        }
    }

    public var rawValue: String {
        switch self {
        case .notLoaded:
            "notLoaded"
        case .idle:
            "idle"
        case .systemError:
            "systemError"
        case .active:
            "active"
        case .unknown(let rawValue):
            rawValue
        }
    }

    public var isActive: Bool {
        if case .active = self {
            return true
        }
        return false
    }

    public var activeFlags: [CodexThreadActiveFlag] {
        if case .active(let activeFlags) = self {
            return activeFlags
        }
        return []
    }
}

package enum CodexTurnProgress: Equatable, Sendable {
    case running(transcript: CodexTranscript, usage: CodexTokenUsage?)
    case terminal(CodexTurnOutcome)
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
    public var reasoningEffort: CodexReasoningEffort?
    public var serviceTier: String?

    public init(
        model: String? = nil,
        reviewModel: String? = nil,
        reasoningEffort: CodexReasoningEffort? = nil,
        serviceTier: String? = nil
    ) {
        self.model = model
        self.reviewModel = reviewModel
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
    }
}

public struct CodexConfigurationPatch: Equatable, Sendable {
    public private(set) var reviewModel: String?
    public private(set) var reasoningEffort: CodexReasoningEffort?
    public private(set) var serviceTier: String?
    public private(set) var updatesReviewModel: Bool
    public private(set) var updatesReasoningEffort: Bool
    public private(set) var updatesServiceTier: Bool

    public init() {
        self.reviewModel = nil
        self.reasoningEffort = nil
        self.serviceTier = nil
        self.updatesReviewModel = false
        self.updatesReasoningEffort = false
        self.updatesServiceTier = false
    }

    public mutating func setReviewModel(_ reviewModel: String?) {
        self.reviewModel = reviewModel
        self.updatesReviewModel = true
    }

    public mutating func setReasoningEffort(_ reasoningEffort: CodexReasoningEffort?) {
        self.reasoningEffort = reasoningEffort
        self.updatesReasoningEffort = true
    }

    public mutating func setServiceTier(_ serviceTier: String?) {
        self.serviceTier = serviceTier
        self.updatesServiceTier = true
    }

    package init(
        reviewModel: String? = nil,
        reasoningEffort: CodexReasoningEffort? = nil,
        serviceTier: String? = nil,
        updatesReviewModel: Bool = false,
        updatesReasoningEffort: Bool = false,
        updatesServiceTier: Bool = false
    ) {
        self.reviewModel = reviewModel
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.updatesReviewModel = updatesReviewModel
        self.updatesReasoningEffort = updatesReasoningEffort
        self.updatesServiceTier = updatesServiceTier
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
        public var reasoningEffort: CodexReasoningEffort
        public var description: String

        public init(reasoningEffort: CodexReasoningEffort, description: String) {
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
    public var defaultReasoningEffort: CodexReasoningEffort?
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
        defaultReasoningEffort: CodexReasoningEffort? = nil,
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
            CodexReasoningEffort.self, forKey: .defaultReasoningEffort)
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
package struct CodexLoginCompletion: Equatable, Sendable {
    /// The app-server login identifier, when the notification is scoped to a login flow.
    package var loginID: CodexLoginHandle.ID?

    /// Whether the login completed successfully.
    package var success: Bool

    /// The server-provided failure message when `success` is false.
    package var error: String?

    package init(loginID: CodexLoginHandle.ID? = nil, success: Bool, error: String? = nil) {
        self.loginID = loginID
        self.success = success
        self.error = error
    }
}

/// A typed account-related notification emitted by Codex app-server.
public enum CodexAccountEvent: Equatable, Sendable {
    /// The active account changed or was refreshed.
    case accountUpdated

    /// Account rate-limit information changed.
    case rateLimitsUpdated(CodexRateLimits)

    /// A known account notification arrived with a shape this SDK could not decode.
    case malformed(method: String, message: String)

    /// A notification outside the current account event surface.
    case unknown(CodexRawNotification)
}

public enum CodexLoginOutcome: Equatable, Sendable {
    case succeeded
    case authenticationCommittedNeedsConnectionReconciliation(CodexLoginReconciliationReason)
    case failed(message: String?)
    case cancelled
}

public enum CodexLoginReconciliationReason: Equatable, Sendable {
    case connectionTerminated(CodexConnectionTermination)
    case accountReadinessDeadlineExceeded(Duration)
    case chatGPTAccountUnavailableAfterSuccess
    case malformedAccountUpdateAfterSuccess(CodexMalformedNotification)
    case cancelOutcomeUnknown(CodexRequestFailure?)
}

public struct CodexLoginHandle: Identifiable, Equatable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    public let id: ID
    public let authenticationURL: URL
    private let state: LoginState

    package init(state: LoginState, id: ID, authenticationURL: URL) {
        self.state = state
        self.id = id
        self.authenticationURL = authenticationURL
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.authenticationURL == rhs.authenticationURL
    }

    public func result() async throws -> CodexLoginOutcome {
        try await state.result()
    }

    @discardableResult
    public func cancel(acknowledgementTimeout: Duration? = nil) async throws -> CodexLoginOutcome {
        try await state.cancel(acknowledgementTimeout: acknowledgementTimeout)
    }

    public func closeConnection() async {
        await state.closeConnection()
    }
}

/// Why an API key was rejected before an authentication request was sent.
public enum CodexAPIKeyValidationFailure: Equatable, Sendable {
    /// The key is empty or contains only whitespace.
    case empty

    /// The key has leading or trailing whitespace.
    case surroundingWhitespace
}

/// Why the result of a written authentication request could not be confirmed.
public enum CodexAuthenticationOutcomeUnknownReason: Equatable, Sendable {
    /// The app-server connection terminated before a correlated response was accepted.
    case connectionTerminated

    /// The authentication request exceeded its configured deadline after being written.
    case deadlineExceeded(Duration)

    /// The transport ended after the request was written but before its result was confirmed.
    case transportEnded

    /// The app-server returned bytes that were not a valid login response.
    case invalidResponse

    /// The app-server returned a valid response for a different login method.
    case unexpectedResponse
}

public enum CodexAppServerError: Error, Equatable, LocalizedError, Sendable {
    case launch(CodexLaunchFailure)
    case request(CodexRequestFailure)
    case connectionTerminated(CodexConnectionTermination)
    case turnDeadlineExceeded(turnID: CodexTurnID, duration: Duration)
    case malformedNotification(CodexMalformedNotification)
    case reviewRestartUnavailable(CodexReviewRestartToken.ID)
    case loginAlreadyInProgress
    case invalidAPIKey(CodexAPIKeyValidationFailure)
    case authenticationOutcomeUnknown(CodexAuthenticationOutcomeUnknownReason)

    public var errorDescription: String? {
        switch self {
        case .launch(let failure):
            failure.localizedDescription
        case .request(let failure):
            failure.localizedDescription
        case .connectionTerminated(let termination):
            termination.errorDescription
        case .turnDeadlineExceeded(let turnID, let duration):
            "Turn \(turnID.rawValue) did not reach a terminal outcome within \(duration)."
        case .malformedNotification(let failure):
            failure.localizedDescription
        case .reviewRestartUnavailable(let tokenID):
            "Prepared review restart is no longer available for token \(tokenID)."
        case .loginAlreadyInProgress:
            "A ChatGPT login is already in progress."
        case .invalidAPIKey(.empty):
            "The API key must not be empty."
        case .invalidAPIKey(.surroundingWhitespace):
            "The API key must not contain leading or trailing whitespace."
        case .authenticationOutcomeUnknown(.connectionTerminated):
            "The app-server connection terminated before the API-key login result was confirmed. Reconcile account state before retrying."
        case .authenticationOutcomeUnknown(.deadlineExceeded(let duration)):
            "The written API-key login request exceeded its deadline of \(duration) before its result was confirmed. Reconcile account state before retrying."
        case .authenticationOutcomeUnknown(.transportEnded):
            "The transport ended before the written API-key login result was confirmed. Reconcile account state before retrying."
        case .authenticationOutcomeUnknown(.invalidResponse):
            "The app-server returned an invalid API-key login response. Reconcile account state before retrying."
        case .authenticationOutcomeUnknown(.unexpectedResponse):
            "The app-server returned an unexpected login response. Reconcile account state before retrying."
        }
    }
}

public struct CodexRequestFailure: Error, Equatable, LocalizedError, Sendable {
    public enum Kind: Equatable, Sendable {
        case encode(message: String)
        case write(CodexTransportFailure)
        case transport(CodexTransportFailure)
        case server(CodexServerError)
        case invalidResponse(expectedType: String, message: String, rawData: Data?)
        case deadlineExceeded(Duration)
        case overloadRetryExhausted(last: CodexServerError, attempts: Int)
    }

    public var requestID: Int
    public var method: String
    public var purpose: CodexRequestPurpose
    public var kind: Kind

    package init(
        requestID: Int,
        method: String,
        purpose: CodexRequestPurpose,
        kind: Kind
    ) {
        self.requestID = requestID
        self.method = method
        self.purpose = purpose
        self.kind = kind
    }

    public var errorDescription: String? {
        let prefix = "JSON-RPC request \(requestID) (\(method))"
        return switch kind {
        case .encode(let message):
            "\(prefix) could not be encoded: \(message)"
        case .write(let failure):
            "\(prefix) could not be written: \(failure.localizedDescription)"
        case .transport(let failure):
            "\(prefix) failed in transport: \(failure.localizedDescription)"
        case .server(let error):
            "\(prefix) was rejected by the server: \(error.message)"
        case .invalidResponse(_, let message, _):
            "\(prefix) returned an invalid response: \(message)"
        case .deadlineExceeded(let duration):
            "\(prefix) exceeded its deadline of \(duration)."
        case .overloadRetryExhausted(let last, let attempts):
            "\(prefix) remained overloaded after \(attempts) attempts: \(last.message)"
        }
    }
}

public enum CodexRequestPurpose: Equatable, Sendable {
    case handshake
    case operation(String)
}

public struct CodexServerError: Error, Equatable, LocalizedError, Sendable {
    public var code: Int
    public var message: String
    public var data: Data?
    public var turnError: CodexTurnError?

    public init(
        code: Int,
        message: String,
        data: Data? = nil,
        turnError: CodexTurnError? = nil
    ) {
        self.code = code
        self.message = message
        self.data = data
        self.turnError = turnError
    }

    public var errorDescription: String? { message }
}

public enum CodexTransportFailure: Error, Equatable, LocalizedError, Sendable {
    case closed
    case io(errno: Int32?, message: String)
    case framing(message: String, rawData: Data?)
    case protocolViolation(message: String, rawData: Data?)
    case contractViolation(message: String)

    public var errorDescription: String? {
        switch self {
        case .closed:
            "The Codex app-server transport is closed."
        case .io(_, let message), .framing(let message, _),
             .protocolViolation(let message, _), .contractViolation(let message):
            message
        }
    }
}

public enum CodexLaunchFailure: Error, Equatable, LocalizedError, Sendable {
    case executableNotFound(command: String, searchedPath: String?)
    case scaffold(path: String, message: String)
    case spawn(executable: String, errno: Int32?, message: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let command, let searchedPath):
            if let searchedPath, searchedPath.isEmpty == false {
                "Unable to locate \(command) executable in PATH: \(searchedPath)"
            } else {
                "Unable to locate \(command) executable."
            }
        case .scaffold(let path, let message):
            "Unable to prepare Codex home at \(path): \(message)"
        case .spawn(let executable, _, let message):
            "Unable to launch \(executable): \(message)"
        }
    }
}

public struct CodexMalformedNotification: Error, Equatable, LocalizedError, Sendable {
    public var method: String
    public var message: String
    public var rawData: Data?

    package init(method: String, message: String, rawData: Data?) {
        self.method = method
        self.message = message
        self.rawData = rawData
    }

    public var errorDescription: String? {
        "Malformed \(method) notification: \(message)"
    }
}

public enum CodexConnectionTermination: Equatable, Sendable {
    case closedByCaller
    case transportFailure(CodexTransportFailure)
    case processExited(status: Int32?)

    package var errorDescription: String {
        switch self {
        case .closedByCaller:
            "The Codex app-server connection was closed by the caller."
        case .transportFailure(let failure):
            "The Codex app-server connection terminated: \(failure.localizedDescription)"
        case .processExited(let status):
            if let status {
                "The Codex app-server process exited with status \(status)."
            } else {
                "The Codex app-server process exited."
            }
        }
    }
}

package struct CodexAppServerClock: Sendable {
    package var now: @Sendable () -> Date

    package init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }
}

package struct CodexDeadlineClock: Sendable {
    package var sleep: @Sendable (Duration) async throws -> Void

    package init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.sleep = sleep
    }

    package static var continuous: Self {
        .init { try await Task.sleep(for: $0) }
    }
}
