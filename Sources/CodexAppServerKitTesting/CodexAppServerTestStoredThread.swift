import CodexAppServerKit
import Foundation

public enum CodexAppServerTestSessionSource: Equatable, Sendable {
    case cli
    case vscode
    case exec
    case appServer
    case custom(String)
    case subAgentReview
    case subAgentCompact
    case subAgentThreadSpawn(
        parentThreadID: CodexThreadID,
        depth: Int,
        agentPath: String?,
        agentNickname: String?,
        agentRole: String?
    )
    case subAgentMemoryConsolidation
    case subAgentOther(String)
    case unknown

    /// The legacy single source-kind projection used by snapshot fixtures.
    /// Custom sources project to `.unknown`; use ``filterSourceKind`` when
    /// constructing app-server source-kind filters.
    public var sourceKind: CodexThreadSourceKind {
        filterSourceKind ?? .unknown
    }

    /// The exact source-kind filter leaf, or `nil` when no filter includes this source.
    public var filterSourceKind: CodexThreadSourceKind? {
        domainProjection.sourceKind
    }

    package var domainProjection: CodexThreadSessionSource {
        switch self {
        case .cli:
            .cli
        case .vscode:
            .vscode
        case .exec:
            .exec
        case .appServer:
            .appServer
        case .custom(let value):
            .custom(value)
        case .subAgentReview:
            .subAgent(.review)
        case .subAgentCompact:
            .subAgent(.compact)
        case .subAgentThreadSpawn(
            let parentThreadID,
            let depth,
            let agentPath,
            let agentNickname,
            let agentRole
        ):
            .subAgent(.threadSpawn(.init(
                parentThreadID: parentThreadID,
                depth: depth,
                agentPath: agentPath,
                agentNickname: agentNickname,
                agentRole: agentRole
            )))
        case .subAgentMemoryConsolidation:
            .subAgent(.memoryConsolidation)
        case .subAgentOther(let value):
            .subAgent(.other(value))
        case .unknown:
            .unknown
        }
    }

    package var wireValue: CodexJSONValue {
        do {
            return try JSONDecoder().decode(
                CodexJSONValue.self,
                from: JSONEncoder().encode(appServerValue)
            )
        } catch {
            preconditionFailure("A validated Testing session source must encode: \(error)")
        }
    }

    package var appServerValue: AppServerAPI.Thread.SessionSource {
        switch self {
        case .cli:
            .cli
        case .vscode:
            .vscode
        case .exec:
            .exec
        case .appServer:
            .appServer
        case .custom(let value):
            .custom(value)
        case .subAgentReview:
            .subAgent(.review)
        case .subAgentCompact:
            .subAgent(.compact)
        case .subAgentThreadSpawn(
            let parentThreadID,
            let depth,
            let agentPath,
            let agentNickname,
            let agentRole
        ):
            .subAgent(.threadSpawn(.init(
                parentThreadID: parentThreadID.rawValue,
                depth: depth,
                agentPath: agentPath,
                agentNickname: agentNickname,
                agentRole: agentRole
            )))
        case .subAgentMemoryConsolidation:
            .subAgent(.memoryConsolidation)
        case .subAgentOther(let value):
            .subAgent(.other(value))
        case .unknown:
            .unknown
        }
    }

    package func validateFixture() throws {
        switch self {
        case .custom(let value):
            try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                value,
                field: "custom thread session source"
            )
        case .subAgentThreadSpawn(
            let parentThreadID,
            let depth,
            let agentPath,
            let agentNickname,
            let agentRole
        ):
            try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                parentThreadID.rawValue,
                field: "sub-agent parent thread id"
            )
            guard depth >= 0 else {
                throw CodexAppServerTestError.invalidFixture(
                    "sub-agent thread-spawn depth must not be negative"
                )
            }
            for (value, field) in [
                (agentPath, "sub-agent path"),
                (agentNickname, "sub-agent nickname"),
                (agentRole, "sub-agent role"),
            ] {
                if let value {
                    try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                        value,
                        field: field
                    )
                }
            }
        case .subAgentOther(let value):
            try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                value,
                field: "other sub-agent source"
            )
        case .cli, .vscode, .exec, .appServer, .subAgentReview, .subAgentCompact,
            .subAgentMemoryConsolidation, .unknown:
            break
        }
    }
}

public struct CodexAppServerTestThreadMetadata: Equatable, Sendable {
    public enum HistoryMode: Equatable, Sendable {
        case legacy
        case paginated
    }

    public var sessionID: String
    public var forkedFromID: CodexThreadID?
    public var parentThreadID: CodexThreadID?
    public var cliVersion: String
    public var source: CodexAppServerTestSessionSource
    public var gitInfo: CodexThreadGitInfo?
    public var historyMode: HistoryMode

    public init(
        sessionID: String,
        forkedFromID: CodexThreadID? = nil,
        parentThreadID: CodexThreadID? = nil,
        cliVersion: String,
        source: CodexAppServerTestSessionSource,
        gitInfo: CodexThreadGitInfo? = nil,
        historyMode: HistoryMode = .legacy
    ) {
        self.sessionID = sessionID
        self.forkedFromID = forkedFromID
        self.parentThreadID = parentThreadID
        self.cliVersion = cliVersion
        self.source = source
        self.gitInfo = gitInfo
        self.historyMode = historyMode
    }
}

public struct CodexAppServerTestThreadRuntimeMetadata: Equatable, Sendable {
    public enum ApprovalPolicy: Equatable, Sendable {
        case unlessTrusted
        case onRequest
        case granular(
            sandboxApproval: Bool,
            rules: Bool,
            skillApproval: Bool,
            requestPermissions: Bool,
            mcpElicitations: Bool
        )
        case never
    }

    public enum ApprovalsReviewer: Equatable, Sendable {
        case user
        case autoReview
    }

    public enum NetworkAccess: Equatable, Sendable {
        case restricted
        case enabled
    }

    public enum SandboxPolicy: Equatable, Sendable {
        case dangerFullAccess
        case readOnly(networkAccess: Bool)
        case externalSandbox(networkAccess: NetworkAccess)
        case workspaceWrite(
            writableRoots: [URL],
            networkAccess: Bool,
            excludeTmpdirEnvVar: Bool,
            excludeSlashTmp: Bool
        )
    }

    public struct ActivePermissionProfile: Equatable, Sendable {
        public var id: String
        public var extends: String?

        public init(id: String, extends: String? = nil) throws {
            try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                id,
                field: "active permission profile id"
            )
            if let extends {
                try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                    extends,
                    field: "active permission profile parent id"
                )
            }
            self.id = id
            self.extends = extends
        }
    }

    public enum MultiAgentMode: Equatable, Sendable {
        case custom(String)
        case explicitRequestOnly
        case proactive
    }

    public var model: String
    public var modelProvider: String
    public var serviceTier: String?
    public var cwd: URL
    public var runtimeWorkspaceRoots: [URL]
    public var instructionSources: [URL]
    public var approvalPolicy: ApprovalPolicy
    public var approvalsReviewer: ApprovalsReviewer
    public var sandbox: SandboxPolicy
    public var activePermissionProfile: ActivePermissionProfile?
    public var reasoningEffort: CodexReasoningEffort?
    public var multiAgentMode: MultiAgentMode

    public init(
        model: String,
        modelProvider: String,
        serviceTier: String?,
        cwd: URL,
        runtimeWorkspaceRoots: [URL],
        instructionSources: [URL],
        approvalPolicy: ApprovalPolicy,
        approvalsReviewer: ApprovalsReviewer,
        sandbox: SandboxPolicy,
        activePermissionProfile: ActivePermissionProfile?,
        reasoningEffort: CodexReasoningEffort?,
        multiAgentMode: MultiAgentMode
    ) throws {
        try Self.validate(
            model: model,
            modelProvider: modelProvider,
            cwd: cwd,
            runtimeWorkspaceRoots: runtimeWorkspaceRoots,
            instructionSources: instructionSources,
            sandbox: sandbox,
            reasoningEffort: reasoningEffort,
            multiAgentMode: multiAgentMode
        )
        self.model = model
        self.modelProvider = modelProvider
        self.serviceTier = serviceTier
        self.cwd = cwd
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots
        self.instructionSources = instructionSources
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.sandbox = sandbox
        self.activePermissionProfile = activePermissionProfile
        self.reasoningEffort = reasoningEffort
        self.multiAgentMode = multiAgentMode
    }

    package var wireValue: CodexJSONValue {
        .object([
            "model": .string(model),
            "modelProvider": .string(modelProvider),
            "serviceTier": serviceTier.map(CodexJSONValue.string) ?? .null,
            "cwd": .string(cwd.standardizedFileURL.path),
            "runtimeWorkspaceRoots": .array(
                runtimeWorkspaceRoots.map {
                    .string($0.standardizedFileURL.path)
                }),
            "instructionSources": .array(
                instructionSources.map {
                    .string($0.standardizedFileURL.path)
                }),
            "approvalPolicy": approvalPolicy.wireValue,
            "approvalsReviewer": approvalsReviewer.wireValue,
            "sandbox": sandbox.wireValue,
            "activePermissionProfile": activePermissionProfile?.wireValue ?? .null,
            "reasoningEffort": reasoningEffort.map { .string($0.rawValue) } ?? .null,
            "multiAgentMode": multiAgentMode.wireValue,
        ])
    }

    package func validateFixture() throws {
        try Self.validate(
            model: model,
            modelProvider: modelProvider,
            cwd: cwd,
            runtimeWorkspaceRoots: runtimeWorkspaceRoots,
            instructionSources: instructionSources,
            sandbox: sandbox,
            reasoningEffort: reasoningEffort,
            multiAgentMode: multiAgentMode
        )
        if let activePermissionProfile {
            try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                activePermissionProfile.id,
                field: "active permission profile id"
            )
            if let extends = activePermissionProfile.extends {
                try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                    extends,
                    field: "active permission profile parent id"
                )
            }
        }
    }

    private static func validate(
        model: String,
        modelProvider: String,
        cwd: URL,
        runtimeWorkspaceRoots: [URL],
        instructionSources: [URL],
        sandbox: SandboxPolicy,
        reasoningEffort: CodexReasoningEffort?,
        multiAgentMode: MultiAgentMode
    ) throws {
        try CodexAppServerTestThreadFixtureValidation.requireNonempty(model, field: "model")
        try CodexAppServerTestThreadFixtureValidation.requireNonempty(
            modelProvider,
            field: "model provider"
        )
        try CodexAppServerTestThreadFixtureValidation.requireAbsoluteFileURL(cwd, field: "cwd")
        try CodexAppServerTestThreadFixtureValidation.requireAbsoluteFileURLs(
            runtimeWorkspaceRoots,
            field: "runtime workspace root"
        )
        try CodexAppServerTestThreadFixtureValidation.requireAbsoluteFileURLs(
            instructionSources,
            field: "instruction source"
        )
        if case .workspaceWrite(let writableRoots, _, _, _) = sandbox {
            try CodexAppServerTestThreadFixtureValidation.requireAbsoluteFileURLs(
                writableRoots,
                field: "sandbox writable root"
            )
        }
        if let reasoningEffort {
            try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                reasoningEffort.rawValue,
                field: "reasoning effort"
            )
        }
        if case .custom(let value) = multiAgentMode {
            try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                value,
                field: "custom multi-agent mode"
            )
        }
    }
}

public struct CodexAppServerTestStoredThread: Equatable, Sendable {
    public let snapshot: CodexThreadSnapshot
    public let turns: [CodexAppServerTestTurn]
    public let runtimeMetadata: CodexAppServerTestThreadRuntimeMetadata
    public let isArchived: Bool
    package let metadata: CodexAppServerTestThreadMetadata
    package let wireValue: CodexJSONValue

    public init(
        snapshot: CodexThreadSnapshot,
        turns: [CodexAppServerTestTurn],
        metadata: CodexAppServerTestThreadMetadata,
        runtimeMetadata: CodexAppServerTestThreadRuntimeMetadata,
        isArchived: Bool
    ) throws {
        let validated = try Self.validate(
            snapshot: snapshot,
            turns: turns,
            metadata: metadata,
            runtimeMetadata: runtimeMetadata
        )
        let snapshot = Self.canonicalSnapshot(snapshot, metadata: metadata)
        self.snapshot = snapshot
        self.turns = turns
        self.metadata = metadata
        self.runtimeMetadata = runtimeMetadata
        self.isArchived = isArchived
        self.wireValue = Self.makeWireValue(
            snapshot: snapshot,
            turns: turns,
            metadata: metadata,
            validated: validated
        )
    }

    public func replacingTurns(
        _ turns: [CodexAppServerTestTurn]
    ) throws -> Self {
        let snapshot = CodexThreadSnapshot(
            id: snapshot.id,
            workspace: snapshot.workspace,
            name: snapshot.name,
            preview: snapshot.preview,
            modelProvider: snapshot.modelProvider,
            sessionID: snapshot.sessionID,
            parentThreadID: snapshot.parentThreadID,
            source: snapshot.source,
            gitInfo: snapshot.gitInfo,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            recencyAt: snapshot.recencyAt,
            status: snapshot.status,
            ephemeral: snapshot.ephemeral,
            turns: turns.map(\.snapshot),
            turnItemsAreAuthoritative: true,
            presentFields: snapshot.presentFields.union([.turns])
        )
        return try Self(
            snapshot: snapshot,
            turns: turns,
            metadata: metadata,
            runtimeMetadata: runtimeMetadata,
            isArchived: isArchived
        )
    }

    public func replacingStatus(_ status: CodexThreadStatus) throws -> Self {
        var snapshot = snapshot
        snapshot.status = status
        return try Self(
            snapshot: snapshot,
            turns: turns,
            metadata: metadata,
            runtimeMetadata: runtimeMetadata,
            isArchived: isArchived
        )
    }

    package func wireValue(includingTurns: Bool) -> CodexJSONValue {
        guard includingTurns == false else {
            return wireValue
        }
        guard case .object(var fields) = wireValue else {
            preconditionFailure("A stored-thread fixture must own an object wire value.")
        }
        fields["turns"] = .array([])
        return .object(fields)
    }

    private static func canonicalSnapshot(
        _ snapshot: CodexThreadSnapshot,
        metadata: CodexAppServerTestThreadMetadata
    ) -> CodexThreadSnapshot {
        var snapshot = snapshot
        snapshot.sessionID = metadata.sessionID
        snapshot.parentThreadID = metadata.parentThreadID
        snapshot.source = metadata.source.domainProjection
        snapshot.gitInfo = metadata.gitInfo
        snapshot.presentFields.remove(.sourceKind)
        snapshot.presentFields.formUnion([
            .sessionID,
            .parentThreadID,
            .source,
            .gitInfo,
        ])
        return snapshot
    }

    private struct ValidatedSnapshot {
        var workspace: URL
        var preview: String
        var modelProvider: String
        var createdAt: Int
        var updatedAt: Int
        var recencyAt: Int?
        var status: CodexThreadStatus
        var ephemeral: Bool
    }

    private static func validate(
        snapshot: CodexThreadSnapshot,
        turns: [CodexAppServerTestTurn],
        metadata: CodexAppServerTestThreadMetadata,
        runtimeMetadata: CodexAppServerTestThreadRuntimeMetadata
    ) throws -> ValidatedSnapshot {
        try CodexAppServerTestThreadFixtureValidation.requireNonempty(
            snapshot.id.rawValue,
            field: "thread id"
        )
        try CodexAppServerTestThreadFixtureValidation.requireNonempty(
            metadata.sessionID,
            field: "thread session id"
        )
        if snapshot.hasField(.sessionID), snapshot.sessionID != metadata.sessionID {
            throw CodexAppServerTestError.invalidFixture(
                "thread snapshot session id must match the Testing thread metadata"
            )
        }
        try CodexAppServerTestThreadFixtureValidation.requireNonempty(
            metadata.cliVersion,
            field: "CLI version"
        )
        if let forkedFromID = metadata.forkedFromID {
            try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                forkedFromID.rawValue,
                field: "forked-from thread id"
            )
        }
        if let parentThreadID = metadata.parentThreadID {
            try CodexAppServerTestThreadFixtureValidation.requireNonempty(
                parentThreadID.rawValue,
                field: "parent thread id"
            )
        }
        if case .subAgentThreadSpawn(let sourceParentThreadID, _, _, _, _) = metadata.source,
            metadata.parentThreadID != sourceParentThreadID
        {
            throw CodexAppServerTestError.invalidFixture(
                "thread-spawn source parent must match the Testing thread metadata parent"
            )
        }
        if snapshot.hasField(.parentThreadID),
            snapshot.parentThreadID != metadata.parentThreadID
        {
            throw CodexAppServerTestError.invalidFixture(
                "thread snapshot parent id must match the Testing thread metadata"
            )
        }
        try metadata.source.validateFixture()
        guard let workspace = snapshot.workspace else {
            throw CodexAppServerTestError.invalidFixture("thread cwd is required")
        }
        try CodexAppServerTestThreadFixtureValidation.requireAbsoluteFileURL(
            workspace,
            field: "thread cwd"
        )
        guard let preview = snapshot.preview else {
            throw CodexAppServerTestError.invalidFixture("thread preview is required")
        }
        guard let modelProvider = snapshot.modelProvider else {
            throw CodexAppServerTestError.invalidFixture("thread model provider is required")
        }
        try CodexAppServerTestThreadFixtureValidation.requireNonempty(
            modelProvider,
            field: "thread model provider"
        )
        if snapshot.hasField(.source) {
            guard snapshot.source == metadata.source.domainProjection else {
                throw CodexAppServerTestError.invalidFixture(
                    "thread snapshot source must match the Testing thread metadata"
                )
            }
        } else if snapshot.hasField(.sourceKind) {
            guard snapshot.sourceKind == metadata.source.sourceKind else {
                throw CodexAppServerTestError.invalidFixture(
                    "thread snapshot source must match the Testing thread metadata"
                )
            }
        }
        if snapshot.hasField(.gitInfo), snapshot.gitInfo != metadata.gitInfo {
            throw CodexAppServerTestError.invalidFixture(
                "thread snapshot Git metadata must match the Testing thread metadata"
            )
        }
        guard let createdAt = snapshot.createdAt else {
            throw CodexAppServerTestError.invalidFixture("thread creation time is required")
        }
        guard let updatedAt = snapshot.updatedAt else {
            throw CodexAppServerTestError.invalidFixture("thread update time is required")
        }
        guard let status = snapshot.status else {
            throw CodexAppServerTestError.invalidFixture("thread status is required")
        }
        if case .unknown(let rawValue) = status {
            throw CodexAppServerTestError.invalidFixture(
                "unsupported thread status \(rawValue)"
            )
        }
        if case .active(let activeFlags) = status,
            activeFlags.contains(where: { Self.supportedActiveFlags.contains($0) == false })
        {
            throw CodexAppServerTestError.invalidFixture(
                "thread active flags must use pinned current-v2 values"
            )
        }
        guard let ephemeral = snapshot.ephemeral else {
            throw CodexAppServerTestError.invalidFixture("thread ephemeral flag is required")
        }
        let turnSnapshots = turns.map(\.snapshot)
        guard let snapshotTurns = snapshot.turns, snapshotTurns == turnSnapshots else {
            throw CodexAppServerTestError.invalidFixture(
                "thread snapshot turns must match the Testing turn projections"
            )
        }
        guard Set(turnSnapshots.map(\.id)).count == turnSnapshots.count else {
            throw CodexAppServerTestError.invalidFixture("thread turn ids must be unique")
        }
        try runtimeMetadata.validateFixture()
        guard runtimeMetadata.modelProvider == modelProvider else {
            throw CodexAppServerTestError.invalidFixture(
                "runtime model provider must match the thread snapshot"
            )
        }
        guard runtimeMetadata.cwd.standardizedFileURL.path == workspace.standardizedFileURL.path else {
            throw CodexAppServerTestError.invalidFixture(
                "runtime cwd must match the thread snapshot"
            )
        }
        return try .init(
            workspace: workspace,
            preview: preview,
            modelProvider: modelProvider,
            createdAt: CodexAppServerTestThreadFixtureValidation.seconds(
                since1970: createdAt,
                field: "thread creation time"
            ),
            updatedAt: CodexAppServerTestThreadFixtureValidation.seconds(
                since1970: updatedAt,
                field: "thread update time"
            ),
            recencyAt: try snapshot.recencyAt.map {
                try CodexAppServerTestThreadFixtureValidation.seconds(
                    since1970: $0,
                    field: "thread recency time"
                )
            },
            status: status,
            ephemeral: ephemeral
        )
    }

    private static func makeWireValue(
        snapshot: CodexThreadSnapshot,
        turns: [CodexAppServerTestTurn],
        metadata: CodexAppServerTestThreadMetadata,
        validated: ValidatedSnapshot
    ) -> CodexJSONValue {
        .object([
            "id": .string(snapshot.id.rawValue),
            "sessionId": .string(metadata.sessionID),
            "forkedFromId": metadata.forkedFromID.map {
                .string($0.rawValue)
            } ?? .null,
            "parentThreadId": metadata.parentThreadID.map {
                .string($0.rawValue)
            } ?? .null,
            "preview": .string(validated.preview),
            "ephemeral": .bool(validated.ephemeral),
            "historyMode": metadata.historyMode.wireValue,
            "modelProvider": .string(validated.modelProvider),
            "createdAt": .int(validated.createdAt),
            "updatedAt": .int(validated.updatedAt),
            "recencyAt": validated.recencyAt.map(CodexJSONValue.int) ?? .null,
            "status": validated.status.wireValue,
            "path": .null,
            "cwd": .string(validated.workspace.standardizedFileURL.path),
            "cliVersion": .string(metadata.cliVersion),
            "source": metadata.source.wireValue,
            "threadSource": .null,
            "agentNickname": .null,
            "agentRole": .null,
            "gitInfo": metadata.gitInfo.map(\.testWireValue) ?? .null,
            "name": snapshot.name.map(CodexJSONValue.string) ?? .null,
            "turns": .array(turns.map(\.wireValue)),
        ])
    }

    private static let supportedActiveFlags: Set<CodexThreadActiveFlag> = [
        .waitingOnApproval,
        .waitingOnUserInput,
    ]
}

private extension CodexThreadGitInfo {
    var testWireValue: CodexJSONValue {
        .object([
            "sha": sha.map(CodexJSONValue.string) ?? .null,
            "branch": branch.map(CodexJSONValue.string) ?? .null,
            "originUrl": originURL.map(CodexJSONValue.string) ?? .null,
        ])
    }
}

public struct CodexAppServerTestThreadPage: Equatable, Sendable {
    public var threads: [CodexAppServerTestStoredThread]
    public var nextCursor: String?
    public var backwardsCursor: String?

    public init(
        threads: [CodexAppServerTestStoredThread],
        nextCursor: String? = nil,
        backwardsCursor: String? = nil
    ) {
        self.threads = threads
        self.nextCursor = nextCursor
        self.backwardsCursor = backwardsCursor
    }

    package var wireValue: CodexJSONValue {
        .object([
            "data": .array(threads.map { $0.wireValue(includingTurns: false) }),
            "nextCursor": nextCursor.map(CodexJSONValue.string) ?? .null,
            "backwardsCursor": backwardsCursor.map(CodexJSONValue.string) ?? .null,
        ])
    }
}

public struct CodexAppServerTestTurnPage: Equatable, Sendable {
    public var turns: [CodexAppServerTestTurn]
    public var nextCursor: String?
    public var backwardsCursor: String?

    public init(
        turns: [CodexAppServerTestTurn],
        nextCursor: String? = nil,
        backwardsCursor: String? = nil
    ) {
        self.turns = turns
        self.nextCursor = nextCursor
        self.backwardsCursor = backwardsCursor
    }

    package var wireValue: CodexJSONValue {
        .object([
            "data": .array(turns.map(\.wireValue)),
            "nextCursor": nextCursor.map(CodexJSONValue.string) ?? .null,
            "backwardsCursor": backwardsCursor.map(CodexJSONValue.string) ?? .null,
        ])
    }
}

private enum CodexAppServerTestThreadFixtureValidation {
    static func requireNonempty(_ value: String, field: String) throws {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("\(field) must not be empty")
        }
    }

    static func requireAbsoluteFileURLs(_ urls: [URL], field: String) throws {
        for url in urls {
            try requireAbsoluteFileURL(url, field: field)
        }
    }

    static func requireAbsoluteFileURL(_ url: URL, field: String) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw CodexAppServerTestError.invalidFixture(
                "\(field) must be an absolute file URL"
            )
        }
    }

    static func seconds(since1970 date: Date, field: String) throws -> Int {
        let value = date.timeIntervalSince1970
        guard value.isFinite,
            value >= Double(Int.min),
            value <= Double(Int.max),
            value.rounded(.towardZero) == value
        else {
            throw CodexAppServerTestError.invalidFixture(
                "\(field) must be representable as whole Unix seconds"
            )
        }
        return Int(value)
    }
}

private extension CodexAppServerTestThreadMetadata.HistoryMode {
    var wireValue: CodexJSONValue {
        switch self {
        case .legacy:
            .string("legacy")
        case .paginated:
            .string("paginated")
        }
    }
}

private extension CodexAppServerTestThreadRuntimeMetadata.ApprovalPolicy {
    var wireValue: CodexJSONValue {
        switch self {
        case .unlessTrusted:
            .string("untrusted")
        case .onRequest:
            .string("on-request")
        case .granular(
            let sandboxApproval,
            let rules,
            let skillApproval,
            let requestPermissions,
            let mcpElicitations
        ):
            .object([
                "granular": .object([
                    "sandbox_approval": .bool(sandboxApproval),
                    "rules": .bool(rules),
                    "skill_approval": .bool(skillApproval),
                    "request_permissions": .bool(requestPermissions),
                    "mcp_elicitations": .bool(mcpElicitations),
                ])
            ])
        case .never:
            .string("never")
        }
    }
}

private extension CodexAppServerTestThreadRuntimeMetadata.ApprovalsReviewer {
    var wireValue: CodexJSONValue {
        switch self {
        case .user:
            .string("user")
        case .autoReview:
            .string("auto_review")
        }
    }
}

private extension CodexAppServerTestThreadRuntimeMetadata.SandboxPolicy {
    var wireValue: CodexJSONValue {
        switch self {
        case .dangerFullAccess:
            .object(["type": .string("dangerFullAccess")])
        case .readOnly(let networkAccess):
            .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(networkAccess),
            ])
        case .externalSandbox(let networkAccess):
            .object([
                "type": .string("externalSandbox"),
                "networkAccess": networkAccess.wireValue,
            ])
        case .workspaceWrite(
            let writableRoots,
            let networkAccess,
            let excludeTmpdirEnvVar,
            let excludeSlashTmp
        ):
            .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array(
                    writableRoots.map {
                        .string($0.standardizedFileURL.path)
                    }),
                "networkAccess": .bool(networkAccess),
                "excludeTmpdirEnvVar": .bool(excludeTmpdirEnvVar),
                "excludeSlashTmp": .bool(excludeSlashTmp),
            ])
        }
    }
}

private extension CodexAppServerTestThreadRuntimeMetadata.NetworkAccess {
    var wireValue: CodexJSONValue {
        switch self {
        case .restricted:
            .string("restricted")
        case .enabled:
            .string("enabled")
        }
    }
}

private extension CodexAppServerTestThreadRuntimeMetadata.ActivePermissionProfile {
    var wireValue: CodexJSONValue {
        .object([
            "id": .string(id),
            "extends": self.extends.map(CodexJSONValue.string) ?? .null,
        ])
    }
}

private extension CodexAppServerTestThreadRuntimeMetadata.MultiAgentMode {
    var wireValue: CodexJSONValue {
        switch self {
        case .custom(let value):
            .object(["custom": .string(value)])
        case .explicitRequestOnly:
            .string("explicitRequestOnly")
        case .proactive:
            .string("proactive")
        }
    }
}

private extension CodexThreadStatus {
    var wireValue: CodexJSONValue {
        switch self {
        case .notLoaded:
            .object(["type": .string("notLoaded")])
        case .idle:
            .object(["type": .string("idle")])
        case .systemError:
            .object(["type": .string("systemError")])
        case .active(let activeFlags):
            .object([
                "type": .string("active"),
                "activeFlags": .array(activeFlags.map { .string($0.rawValue) }),
            ])
        case .unknown(let rawValue):
            preconditionFailure("Unsupported Testing thread status \(rawValue) was not validated.")
        }
    }
}
