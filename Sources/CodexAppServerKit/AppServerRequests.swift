import Foundation

package enum AppServerAPI {
    package enum Initialize {}
    package enum Thread {
        package enum Start {}
        package enum Resume {}
        package enum Fork {}
        package enum List {}
        package enum Read {}
        package enum Turns {
            package enum List {}
        }
        package enum Archive {}
        package enum Unarchive {}
        package enum Name {
            package enum Set {}
        }
        package enum Compact {
            package enum Start {}
        }
        package enum Rollback {}
        package enum Delete {}
        package enum Unsubscribe {}
        package enum BackgroundTerminals {
            package enum Clean {}
        }
    }
    package enum Review {
        package enum Start {}
    }
    package enum Turn {
        package enum Start {}
        package enum Steer {}
        package enum Interrupt {}
    }
    package enum Config {
        package enum Read {}
        package enum BatchWrite {}
    }
    package enum Model {
        package enum List {}
    }
    package enum Auth {
        package enum Read {}
    }
    package enum Account {
        package enum Read {}
        package enum Logout {}
        package enum RateLimits {
            package enum Read {}
        }
        package enum Login {
            package enum Start {}
            package enum Cancel {}
        }
    }
}

extension AppServerAPI {
    package enum RequestScope: Hashable, Sendable {
        case thread(String)
    }
}

extension AppServerAPI.Review.Start {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String
        package var target: CodexReviewTarget
        package var delivery: CodexReviewDelivery

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case target
            case delivery
        }

        package init(
            threadID: String,
            target: CodexReviewTarget,
            delivery: CodexReviewDelivery = .inline
        ) {
            self.threadID = threadID
            self.target = target
            self.delivery = delivery
        }
    }
}

extension AppServerAPI.Review.Start {
    package struct Response: Codable, Equatable, Sendable {
        package var turn: AppServerAPI.Turn.Payload
        package var reviewThreadID: String
        package var turnID: String {
            turn.id
        }

        enum CodingKeys: String, CodingKey {
            case turn
            case reviewThreadID = "reviewThreadId"
        }

        package init(turnID: String, reviewThreadID: String) {
            self.init(
                turn: AppServerAPI.Turn.Payload(id: turnID, status: "inProgress"),
                reviewThreadID: reviewThreadID
            )
        }

        package init(
            turn: AppServerAPI.Turn.Payload,
            reviewThreadID: String
        ) {
            self.turn = turn
            self.reviewThreadID = reviewThreadID
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.turn = try container.decode(AppServerAPI.Turn.Payload.self, forKey: .turn)
            self.reviewThreadID = try container.decode(
                String.self, forKey: .reviewThreadID)
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(turn, forKey: .turn)
            try container.encode(reviewThreadID, forKey: .reviewThreadID)
        }
    }
}

extension AppServerAPI.Review.Start {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Review.Start.Response

        package static let method = "review/start"
        package var params: AppServerAPI.Review.Start.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Review.Start.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI {
    package protocol Request: Sendable {
        associatedtype Params: Encodable & Sendable
        associatedtype Response: Decodable & Sendable

        static var method: String { get }
        var params: Params { get }
        var scope: AppServerAPI.RequestScope? { get }
    }
}

extension AppServerAPI.Request {
    package var scope: AppServerAPI.RequestScope? { nil }
}

package enum AppServerJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AppServerJSONValue])
    case object([String: AppServerJSONValue])
    case null

    package init(from decoder: Decoder) throws {
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
        } else if let value = try? container.decode([AppServerJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AppServerJSONValue].self))
        }
    }

    package func encode(to encoder: Encoder) throws {
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

extension AppServerAPI.Initialize {
    package struct ClientInfo: Codable, Equatable, Sendable {
        package var name: String
        package var title: String?
        package var version: String

        package init(name: String, title: String? = nil, version: String) {
            self.name = name
            self.title = title
            self.version = version
        }
    }
}

extension AppServerAPI.Initialize {
    package struct Capabilities: Codable, Equatable, Sendable {
        package var experimentalAPI: Bool

        enum CodingKeys: String, CodingKey {
            case experimentalAPI = "experimentalApi"
        }

        package init(experimentalAPI: Bool = true) {
            self.experimentalAPI = experimentalAPI
        }
    }
}

extension AppServerAPI.Initialize {
    package struct Params: Codable, Equatable, Sendable {
        package var clientInfo: AppServerAPI.Initialize.ClientInfo
        package var capabilities: AppServerAPI.Initialize.Capabilities

        enum CodingKeys: String, CodingKey {
            case clientInfo
            case capabilities
        }

        package init(clientName: String, clientVersion: String) {
            self.clientInfo = .init(name: clientName, version: clientVersion)
            self.capabilities = .init()
        }
    }
}

extension AppServerAPI.Initialize {
    package struct Response: Codable, Equatable, Sendable {
        package var codexHome: String?
        package var userAgent: String?

        package init(codexHome: String? = nil, userAgent: String? = nil) {
            self.codexHome = codexHome
            self.userAgent = userAgent
        }
    }
}

extension AppServerAPI.Initialize {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Initialize.Response

        package static let method = "initialize"
        package var params: AppServerAPI.Initialize.Params

        package init(params: AppServerAPI.Initialize.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.Start {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String?
        package var cwd: String?
        package var model: String?
        package var modelProvider: String?
        package var ephemeral: Bool?
        package var baseInstructions: String?
        package var developerInstructions: String?
        package var approvalPolicy: String?
        package var approvalsReviewer: String?
        package var sandbox: String?
        package var serviceName: String?
        package var serviceTier: String?
        package var personality: String?
        package var config: [String: AppServerJSONValue]?
        package var permissions: AppServerAPI.Thread.Start.Permissions?
        // Session start source drives lifecycle hooks; thread source is analytics classification.
        package var sessionStartSource: AppServerAPI.Thread.Start.Source?
        package var threadSource: AppServerAPI.Thread.Source?

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case cwd
            case model
            case modelProvider
            case ephemeral
            case baseInstructions
            case developerInstructions
            case approvalPolicy
            case approvalsReviewer
            case sandbox
            case serviceName
            case serviceTier
            case personality
            case config
            case permissions
            case sessionStartSource
            case threadSource
        }

        package init(
            threadID: String? = nil,
            cwd: String? = nil,
            model: String? = nil,
            modelProvider: String? = nil,
            ephemeral: Bool? = nil,
            baseInstructions: String? = nil,
            developerInstructions: String? = nil,
            approvalPolicy: String? = nil,
            approvalsReviewer: String? = nil,
            sandbox: String? = nil,
            serviceName: String? = nil,
            serviceTier: String? = nil,
            personality: String? = nil,
            config: [String: AppServerJSONValue]? = nil,
            permissions: AppServerAPI.Thread.Start.Permissions? = nil,
            sessionStartSource: AppServerAPI.Thread.Start.Source? = nil,
            threadSource: AppServerAPI.Thread.Source? = nil
        ) {
            self.threadID = threadID
            self.cwd = cwd
            self.model = model
            self.modelProvider = modelProvider
            self.ephemeral = ephemeral
            self.baseInstructions = baseInstructions
            self.developerInstructions = developerInstructions
            self.approvalPolicy = approvalPolicy
            self.approvalsReviewer = approvalsReviewer
            self.sandbox = sandbox
            self.serviceName = serviceName
            self.serviceTier = serviceTier
            self.personality = personality
            self.config = config
            self.permissions = permissions
            self.sessionStartSource = sessionStartSource
            self.threadSource = threadSource
        }
    }
}

extension AppServerAPI.Thread.Start {
    package enum Source: String, Codable, Equatable, Sendable {
        case startup
        case clear
    }
}

extension AppServerAPI.Thread {
    package struct Source: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        package var rawValue: String

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package init(stringLiteral value: String) {
            self.rawValue = value
        }

        package static let user = Self(rawValue: "user")
        package static let subagent = Self(rawValue: "subagent")
        package static let memoryConsolidation = Self(rawValue: "memory_consolidation")
    }
}

extension AppServerAPI.Thread.Start {
    package enum Permissions: Codable, Equatable, Sendable {
        case profileID(String)
        case profileSelection(AppServerAPI.Thread.Start.PermissionProfileSelection)

        package init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let profileID = try? container.decode(String.self) {
                self = .profileID(profileID)
                return
            }
            if let profileSelection = try? container.decode(
                AppServerAPI.Thread.Start.PermissionProfileSelection.self)
            {
                self = .profileSelection(profileSelection)
                return
            }
            throw DecodingError.typeMismatch(
                AppServerAPI.Thread.Start.Permissions.self,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Expected a permissions profile ID or profile selection object."
                )
            )
        }

        package func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .profileID(let profileID):
                try container.encode(profileID)
            case .profileSelection(let profileSelection):
                try container.encode(profileSelection)
            }
        }
    }
}

extension AppServerAPI.Thread.Start {
    package struct PermissionProfileSelection: Codable, Equatable, Sendable {
        package var type: String
        package var id: String

        package init(id: String, type: String = "profile") {
            self.type = type
            self.id = id
        }
    }
}

extension AppServerAPI.Thread.Start {
    package struct Response: Codable, Equatable, Sendable {
        package var threadID: String
        package var model: String?

        enum CodingKeys: String, CodingKey {
            case thread
            case model
        }

        private struct Thread: Codable, Equatable, Sendable {
            var id: String
        }

        package init(threadID: String, model: String? = nil) {
            self.threadID = threadID
            self.model = model
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.threadID = try container.decode(Thread.self, forKey: .thread).id
            self.model = try container.decodeIfPresent(String.self, forKey: .model)
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Thread(id: threadID), forKey: .thread)
            try container.encodeIfPresent(model, forKey: .model)
        }
    }
}

extension AppServerAPI.Thread.Start {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.Start.Response

        package static let method = "thread/start"
        package var params: AppServerAPI.Thread.Start.Params

        package init(params: AppServerAPI.Thread.Start.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread {
    package enum SessionSource: Equatable, Sendable {
        package enum SubAgent: Equatable, Sendable {
            package struct ThreadSpawn: Codable, Equatable, Sendable {
                package var parentThreadID: String
                package var depth: Int
                package var agentPath: String?
                package var agentNickname: String?
                package var agentRole: String?

                enum CodingKeys: String, CodingKey {
                    case parentThreadID = "parent_thread_id"
                    case depth
                    case agentPath = "agent_path"
                    case agentNickname = "agent_nickname"
                    case agentRole = "agent_role"
                }

                package init(
                    parentThreadID: String,
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

        package var sourceKind: CodexThreadSourceKind? {
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
    }

    package struct Snapshot: Codable, Equatable, Sendable {
        package enum Field: String, Hashable, Sendable {
            case sessionID
            case parentThreadID
            case cwd
            case name
            case preview
            case modelProvider
            case source
            case gitInfo
            case createdAt
            case updatedAt
            case recencyAt
            case status
            case ephemeral
            case turns
        }

        package struct Status: Codable, Equatable, Sendable {
            package var type: String
            package var activeFlags: [String]?

            package init(type: String, activeFlags: [String]? = nil) {
                self.type = type
                self.activeFlags = activeFlags
            }
        }

        package struct GitInfo: Codable, Equatable, Sendable {
            package var sha: String?
            package var branch: String?
            package var originURL: String?

            enum CodingKeys: String, CodingKey {
                case sha
                case branch
                case originURL = "originUrl"
            }

            package init(
                sha: String? = nil,
                branch: String? = nil,
                originURL: String? = nil
            ) {
                self.sha = sha
                self.branch = branch
                self.originURL = originURL
            }
        }

        package var id: String
        package var sessionID: String?
        package var parentThreadID: String?
        package var cwd: String?
        package var name: String?
        package var preview: String?
        package var modelProvider: String?
        package var source: AppServerAPI.Thread.SessionSource?
        package var gitInfo: GitInfo?
        package var createdAt: Int?
        package var updatedAt: Int?
        package var recencyAt: Int?
        package var status: Status?
        package var ephemeral: Bool?
        package var turns: [AppServerAPI.Turn.Payload]?
        package var presentFields: Set<Field>

        package var sourceKind: CodexThreadSourceKind? {
            source?.sourceKind
        }

        enum CodingKeys: String, CodingKey {
            case id
            case sessionID = "sessionId"
            case parentThreadID = "parentThreadId"
            case cwd
            case name
            case preview
            case modelProvider
            case source
            case gitInfo
            case createdAt
            case updatedAt
            case recencyAt
            case status
            case ephemeral
            case turns
        }

        package init(
            id: String,
            sessionID: String? = nil,
            parentThreadID: String? = nil,
            cwd: String? = nil,
            name: String? = nil,
            preview: String? = nil,
            modelProvider: String? = nil,
            source: AppServerAPI.Thread.SessionSource? = nil,
            gitInfo: GitInfo? = nil,
            createdAt: Int? = nil,
            updatedAt: Int? = nil,
            recencyAt: Int? = nil,
            status: Status? = nil,
            ephemeral: Bool? = nil,
            turns: [AppServerAPI.Turn.Payload]? = nil,
            presentFields: Set<Field>? = nil
        ) {
            self.id = id
            self.sessionID = sessionID
            self.parentThreadID = parentThreadID
            self.cwd = cwd
            self.name = name
            self.preview = preview
            self.modelProvider = modelProvider
            self.source = source
            self.gitInfo = gitInfo
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.recencyAt = recencyAt
            self.status = status
            self.ephemeral = ephemeral
            self.turns = turns
            self.presentFields = presentFields ?? Self.presentFields(
                sessionID: sessionID,
                parentThreadID: parentThreadID,
                cwd: cwd,
                name: name,
                preview: preview,
                modelProvider: modelProvider,
                source: source,
                gitInfo: gitInfo,
                createdAt: createdAt,
                updatedAt: updatedAt,
                recencyAt: recencyAt,
                status: status,
                ephemeral: ephemeral,
                turns: turns
            )
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            parentThreadID = try container.decodeIfPresent(String.self, forKey: .parentThreadID)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            preview = try container.decodeIfPresent(String.self, forKey: .preview)
            modelProvider = try container.decodeIfPresent(String.self, forKey: .modelProvider)
            source = try container.decodeIfPresent(
                AppServerAPI.Thread.SessionSource.self,
                forKey: .source
            )
            gitInfo = try container.decodeIfPresent(GitInfo.self, forKey: .gitInfo)
            createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
            updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
            recencyAt = try container.decodeIfPresent(Int.self, forKey: .recencyAt)
            status = try container.decodeIfPresent(Status.self, forKey: .status)
            ephemeral = try container.decodeIfPresent(Bool.self, forKey: .ephemeral)
            turns = try container.decodeIfPresent([AppServerAPI.Turn.Payload].self, forKey: .turns)
            presentFields = Self.presentFields(from: container)
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try encode(sessionID, forKey: .sessionID, into: &container)
            try encode(parentThreadID, forKey: .parentThreadID, into: &container)
            try encode(cwd, forKey: .cwd, into: &container)
            try encode(name, forKey: .name, into: &container)
            try encode(preview, forKey: .preview, into: &container)
            try encode(modelProvider, forKey: .modelProvider, into: &container)
            try encode(source, forKey: .source, into: &container)
            try encode(gitInfo, forKey: .gitInfo, into: &container)
            try encode(createdAt, forKey: .createdAt, into: &container)
            try encode(updatedAt, forKey: .updatedAt, into: &container)
            try encode(recencyAt, forKey: .recencyAt, into: &container)
            try encode(status, forKey: .status, into: &container)
            try encode(ephemeral, forKey: .ephemeral, into: &container)
            try encode(turns, forKey: .turns, into: &container)
        }

        private func encode<Value: Encodable>(
            _ value: Value?,
            forKey key: CodingKeys,
            into container: inout KeyedEncodingContainer<CodingKeys>
        ) throws {
            guard let field = Field(key), presentFields.contains(field) else {
                return
            }
            if let value {
                try container.encode(value, forKey: key)
            } else {
                try container.encodeNil(forKey: key)
            }
        }

        private static func presentFields(
            sessionID: String?,
            parentThreadID: String?,
            cwd: String?,
            name: String?,
            preview: String?,
            modelProvider: String?,
            source: AppServerAPI.Thread.SessionSource?,
            gitInfo: GitInfo?,
            createdAt: Int?,
            updatedAt: Int?,
            recencyAt: Int?,
            status: AppServerAPI.Thread.Snapshot.Status?,
            ephemeral: Bool?,
            turns: [AppServerAPI.Turn.Payload]?
        ) -> Set<Field> {
            var fields: Set<Field> = []
            if sessionID != nil {
                fields.insert(.sessionID)
            }
            if parentThreadID != nil {
                fields.insert(.parentThreadID)
            }
            if cwd != nil {
                fields.insert(.cwd)
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

        private static func presentFields(
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> Set<Field> {
            var fields: Set<Field> = []
            for key in container.allKeys {
                if let field = Field(key) {
                    fields.insert(field)
                }
            }
            return fields
        }
    }
}

extension AppServerAPI.Thread.SessionSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case custom
        case subAgent
    }

    package init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            switch value {
            case "cli":
                self = .cli
            case "vscode":
                self = .vscode
            case "exec":
                self = .exec
            case "appServer":
                self = .appServer
            case "unknown":
                self = .unknown
            default:
                self = .unknown
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.custom) {
            self = .custom(try container.decode(String.self, forKey: .custom))
            return
        }
        if container.contains(.subAgent) {
            self = .subAgent(try container.decode(SubAgent.self, forKey: .subAgent))
            return
        }
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported current-v2 thread session source."
            )
        )
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case .cli:
            var container = encoder.singleValueContainer()
            try container.encode("cli")
        case .vscode:
            var container = encoder.singleValueContainer()
            try container.encode("vscode")
        case .exec:
            var container = encoder.singleValueContainer()
            try container.encode("exec")
        case .appServer:
            var container = encoder.singleValueContainer()
            try container.encode("appServer")
        case .unknown:
            var container = encoder.singleValueContainer()
            try container.encode("unknown")
        case .custom(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .custom)
        case .subAgent(let source):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(source, forKey: .subAgent)
        }
    }
}

extension AppServerAPI.Thread.SessionSource.SubAgent: Codable {
    private enum CodingKeys: String, CodingKey {
        case threadSpawn = "thread_spawn"
        case other
    }

    package init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            switch value {
            case "review":
                self = .review
            case "compact":
                self = .compact
            case "memory_consolidation":
                self = .memoryConsolidation
            default:
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unsupported current-v2 sub-agent source \(value)."
                    )
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.threadSpawn) {
            self = .threadSpawn(try container.decode(ThreadSpawn.self, forKey: .threadSpawn))
            return
        }
        if container.contains(.other) {
            self = .other(try container.decode(String.self, forKey: .other))
            return
        }
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported current-v2 sub-agent source."
            )
        )
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case .review:
            var container = encoder.singleValueContainer()
            try container.encode("review")
        case .compact:
            var container = encoder.singleValueContainer()
            try container.encode("compact")
        case .memoryConsolidation:
            var container = encoder.singleValueContainer()
            try container.encode("memory_consolidation")
        case .threadSpawn(let source):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(source, forKey: .threadSpawn)
        case .other(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .other)
        }
    }
}

private extension AppServerAPI.Thread.Snapshot.Field {
    init?(_ key: AppServerAPI.Thread.Snapshot.CodingKeys) {
        switch key {
        case .id:
            return nil
        case .sessionID:
            self = .sessionID
        case .parentThreadID:
            self = .parentThreadID
        case .cwd:
            self = .cwd
        case .name:
            self = .name
        case .preview:
            self = .preview
        case .modelProvider:
            self = .modelProvider
        case .source:
            self = .source
        case .gitInfo:
            self = .gitInfo
        case .createdAt:
            self = .createdAt
        case .updatedAt:
            self = .updatedAt
        case .recencyAt:
            self = .recencyAt
        case .status:
            self = .status
        case .ephemeral:
            self = .ephemeral
        case .turns:
            self = .turns
        }
    }
}

extension AppServerAPI.Thread.Resume {
    package typealias Params = AppServerAPI.Thread.Start.Params

    package struct Response: Codable, Equatable, Sendable {
        package var thread: AppServerAPI.Thread.Snapshot
        package var model: String?

        package init(thread: AppServerAPI.Thread.Snapshot, model: String? = nil) {
            self.thread = thread
            self.model = model
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.Resume.Response

        package static let method = "thread/resume"
        package var params: AppServerAPI.Thread.Resume.Params
        package var scope: AppServerAPI.RequestScope? {
            params.threadID.map(AppServerAPI.RequestScope.thread)
        }

        package init(threadID: String, params: AppServerAPI.Thread.Start.Params = .init()) {
            var scopedParams = params
            scopedParams.threadID = threadID
            self.params = scopedParams
        }
    }
}

extension AppServerAPI.Thread.Fork {
    package typealias Params = AppServerAPI.Thread.Start.Params

    package struct Response: Codable, Equatable, Sendable {
        package var thread: AppServerAPI.Thread.Snapshot

        package init(thread: AppServerAPI.Thread.Snapshot) {
            self.thread = thread
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.Fork.Response

        package static let method = "thread/fork"
        package var params: AppServerAPI.Thread.Fork.Params
        package var scope: AppServerAPI.RequestScope? {
            params.threadID.map(AppServerAPI.RequestScope.thread)
        }

        package init(threadID: String, params: AppServerAPI.Thread.Start.Params = .init()) {
            var scopedParams = params
            scopedParams.threadID = threadID
            self.params = scopedParams
        }
    }
}

extension AppServerAPI.Turn {
    package struct Payload: Codable, Equatable, Sendable {
        package var id: String
        package var status: String
        package var error: AppServerAPI.Turn.Error?
        package var startedAt: Int?
        package var completedAt: Int?
        package var durationMS: Int?
        package var itemsLoadState: CodexTurnItemsLoadState?
        package var items: [AppServerJSONValue]?

        enum CodingKeys: String, CodingKey {
            case id
            case status
            case error
            case startedAt
            case completedAt
            case durationMS = "durationMs"
            case itemsLoadState = "itemsView"
            case items
        }

        package init(
            id: String,
            status: String,
            error: AppServerAPI.Turn.Error? = nil,
            startedAt: Int? = nil,
            completedAt: Int? = nil,
            durationMS: Int? = nil,
            itemsLoadState: CodexTurnItemsLoadState? = nil,
            items: [AppServerJSONValue]? = nil
        ) {
            self.id = id
            self.status = status
            self.error = error
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.durationMS = durationMS
            self.itemsLoadState = itemsLoadState
            self.items = items
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            status = try container.decode(String.self, forKey: .status)
            error = try container.decodeIfPresent(AppServerAPI.Turn.Error.self, forKey: .error)
            startedAt = try container.decodeIfPresent(Int.self, forKey: .startedAt)
            completedAt = try container.decodeIfPresent(Int.self, forKey: .completedAt)
            durationMS = try container.decodeIfPresent(Int.self, forKey: .durationMS)
            itemsLoadState = try container.decodeIfPresent(
                CodexTurnItemsLoadState.self,
                forKey: .itemsLoadState
            )
            items = try container.decodeIfPresent([AppServerJSONValue].self, forKey: .items)

            switch CodexTurnStatus(rawValue: status) {
            case .failed:
                guard error != nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .error,
                        in: container,
                        debugDescription: "A failed turn requires an error payload."
                    )
                }
            case .inProgress, .completed, .interrupted:
                guard error == nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .error,
                        in: container,
                        debugDescription: "Known non-failed turn status \(status) cannot carry an error."
                    )
                }
            case .unknown:
                break
            }
        }
    }
}

extension AppServerAPI.Thread.List {
    package struct Params: Codable, Equatable, Sendable {
        package var archived: Bool?
        package var cursor: String?
        package var cwd: AppServerAPI.Thread.List.CWDFilter?
        package var limit: Int?
        package var modelProviders: [String]?
        package var searchTerm: String?
        package var sortDirection: String?
        package var sortKey: String?
        package var sourceKinds: [String]?
        package var useStateDbOnly: Bool?

        package init(
            archived: Bool? = nil,
            cursor: String? = nil,
            cwd: AppServerAPI.Thread.List.CWDFilter? = nil,
            limit: Int? = nil,
            modelProviders: [String]? = nil,
            searchTerm: String? = nil,
            sortDirection: String? = nil,
            sortKey: String? = nil,
            sourceKinds: [String]? = nil,
            useStateDbOnly: Bool? = nil
        ) {
            self.archived = archived
            self.cursor = cursor
            self.cwd = cwd
            self.limit = limit
            self.modelProviders = modelProviders
            self.searchTerm = searchTerm
            self.sortDirection = sortDirection
            self.sortKey = sortKey
            self.sourceKinds = sourceKinds
            self.useStateDbOnly = useStateDbOnly
        }
    }

    package enum CWDFilter: Codable, Equatable, Sendable {
        case paths([String])

        package init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self = .paths(try container.decode([String].self))
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .paths(let paths):
                try container.encode(paths)
            }
        }
    }

    package struct Response: Codable, Equatable, Sendable {
        package var data: [AppServerAPI.Thread.Snapshot]
        package var nextCursor: String?
        package var backwardsCursor: String?

        package init(
            data: [AppServerAPI.Thread.Snapshot],
            nextCursor: String? = nil,
            backwardsCursor: String? = nil
        ) {
            self.data = data
            self.nextCursor = nextCursor
            self.backwardsCursor = backwardsCursor
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.List.Response

        package static let method = "thread/list"
        package var params: AppServerAPI.Thread.List.Params

        package init(params: AppServerAPI.Thread.List.Params = .init()) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.Read {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String
        package var includeTurns: Bool?

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case includeTurns
        }

        package init(threadID: String, includeTurns: Bool? = nil) {
            self.threadID = threadID
            self.includeTurns = includeTurns
        }
    }

    package struct Response: Codable, Equatable, Sendable {
        package var thread: AppServerAPI.Thread.Snapshot

        package init(thread: AppServerAPI.Thread.Snapshot) {
            self.thread = thread
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.Read.Response

        package static let method = "thread/read"
        package var params: AppServerAPI.Thread.Read.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Thread.Read.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.Turns.List {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String
        package var cursor: String?
        package var limit: Int?
        package var sortDirection: CodexSortDirection?
        package var itemsLoadState: CodexTurnItemsLoadState?

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case cursor
            case limit
            case sortDirection
            case itemsLoadState = "itemsView"
        }

        package init(
            threadID: String,
            cursor: String? = nil,
            limit: Int? = nil,
            sortDirection: CodexSortDirection? = nil,
            itemsLoadState: CodexTurnItemsLoadState? = nil
        ) {
            self.threadID = threadID
            self.cursor = cursor
            self.limit = limit
            self.sortDirection = sortDirection
            self.itemsLoadState = itemsLoadState
        }
    }

    package struct Response: Codable, Equatable, Sendable {
        package var data: [AppServerAPI.Turn.Payload]
        package var nextCursor: String?
        package var backwardsCursor: String?

        package init(
            data: [AppServerAPI.Turn.Payload],
            nextCursor: String? = nil,
            backwardsCursor: String? = nil
        ) {
            self.data = data
            self.nextCursor = nextCursor
            self.backwardsCursor = backwardsCursor
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.Turns.List.Response

        package static let method = "thread/turns/list"
        package var params: AppServerAPI.Thread.Turns.List.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Thread.Turns.List.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.Archive {
    package typealias Response = EmptyResponse

    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
        }

        package init(threadID: String) {
            self.threadID = threadID
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.Archive.Response

        package static let method = "thread/archive"
        package var params: AppServerAPI.Thread.Archive.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Thread.Archive.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.Unarchive {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
        }

        package init(threadID: String) {
            self.threadID = threadID
        }
    }

    package struct Response: Codable, Equatable, Sendable {
        package var thread: AppServerAPI.Thread.Snapshot

        package init(thread: AppServerAPI.Thread.Snapshot) {
            self.thread = thread
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.Unarchive.Response

        package static let method = "thread/unarchive"
        package var params: AppServerAPI.Thread.Unarchive.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Thread.Unarchive.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.Name.Set {
    package typealias Response = EmptyResponse

    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String
        package var name: String

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case name
        }

        package init(threadID: String, name: String) {
            self.threadID = threadID
            self.name = name
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.Name.Set.Response

        package static let method = "thread/name/set"
        package var params: AppServerAPI.Thread.Name.Set.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Thread.Name.Set.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.Compact.Start {
    package typealias Response = EmptyResponse

    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
        }

        package init(threadID: String) {
            self.threadID = threadID
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.Compact.Start.Response

        package static let method = "thread/compact/start"
        package var params: AppServerAPI.Thread.Compact.Start.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Thread.Compact.Start.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Turn {
    package struct Error: Codable, Equatable, Sendable {
        package var message: String
        package var codexErrorInfo: AppServerAPI.CodexErrorInfo?
        package var additionalDetails: String?

        package init(
            message: String,
            codexErrorInfo: AppServerAPI.CodexErrorInfo? = nil,
            additionalDetails: String? = nil
        ) {
            self.message = message
            self.codexErrorInfo = codexErrorInfo
            self.additionalDetails = additionalDetails
        }
    }
}

extension AppServerAPI {
    package enum CodexErrorInfo: Codable, Equatable, Sendable {
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

        package init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                self = Self(simpleRawValue: value)
                return
            }
            let object = try decoder.singleValueContainer().decode([String: Payload].self)
            guard object.count == 1, let (key, payload) = object.first else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid codexErrorInfo payload.")
                )
            }
            switch key {
            case "httpConnectionFailed":
                self = .httpConnectionFailed(httpStatusCode: payload.httpStatusCode)
            case "responseStreamConnectionFailed":
                self = .responseStreamConnectionFailed(httpStatusCode: payload.httpStatusCode)
            case "responseStreamDisconnected":
                self = .responseStreamDisconnected(httpStatusCode: payload.httpStatusCode)
            case "responseTooManyFailedAttempts":
                self = .responseTooManyFailedAttempts(httpStatusCode: payload.httpStatusCode)
            case "activeTurnNotSteerable":
                guard let turnKind = payload.turnKind else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath, debugDescription: "Missing turnKind.")
                    )
                }
                self = .activeTurnNotSteerable(turnKind: turnKind)
            default:
                self = .unknown(rawValue: key)
            }
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .httpConnectionFailed(let code):
                try container.encode(["httpConnectionFailed": Payload(httpStatusCode: code)])
            case .responseStreamConnectionFailed(let code):
                try container.encode(["responseStreamConnectionFailed": Payload(httpStatusCode: code)])
            case .responseStreamDisconnected(let code):
                try container.encode(["responseStreamDisconnected": Payload(httpStatusCode: code)])
            case .responseTooManyFailedAttempts(let code):
                try container.encode(["responseTooManyFailedAttempts": Payload(httpStatusCode: code)])
            case .activeTurnNotSteerable(let turnKind):
                try container.encode(["activeTurnNotSteerable": Payload(turnKind: turnKind)])
            default:
                try container.encode(simpleRawValue)
            }
        }

        private struct Payload: Codable, Equatable, Sendable {
            var httpStatusCode: UInt16?
            var turnKind: String?

            init(httpStatusCode: UInt16? = nil, turnKind: String? = nil) {
                self.httpStatusCode = httpStatusCode
                self.turnKind = turnKind
            }
        }

        private init(simpleRawValue: String) {
            switch simpleRawValue {
            case "contextWindowExceeded": self = .contextWindowExceeded
            case "sessionBudgetExceeded": self = .sessionBudgetExceeded
            case "usageLimitExceeded": self = .usageLimitExceeded
            case "serverOverloaded": self = .serverOverloaded
            case "cyberPolicy": self = .cyberPolicy
            case "internalServerError": self = .internalServerError
            case "unauthorized": self = .unauthorized
            case "badRequest": self = .badRequest
            case "threadRollbackFailed": self = .threadRollbackFailed
            case "sandboxError": self = .sandboxError
            case "other": self = .other
            default: self = .unknown(rawValue: simpleRawValue)
            }
        }

        private var simpleRawValue: String {
            switch self {
            case .contextWindowExceeded: "contextWindowExceeded"
            case .sessionBudgetExceeded: "sessionBudgetExceeded"
            case .usageLimitExceeded: "usageLimitExceeded"
            case .serverOverloaded: "serverOverloaded"
            case .cyberPolicy: "cyberPolicy"
            case .internalServerError: "internalServerError"
            case .unauthorized: "unauthorized"
            case .badRequest: "badRequest"
            case .threadRollbackFailed: "threadRollbackFailed"
            case .sandboxError: "sandboxError"
            case .other: "other"
            case .unknown(let rawValue): rawValue
            case .httpConnectionFailed, .responseStreamConnectionFailed,
                 .responseStreamDisconnected, .responseTooManyFailedAttempts,
                 .activeTurnNotSteerable:
                preconditionFailure("Associated codexErrorInfo has no simple raw value.")
            }
        }
    }
}

extension AppServerAPI {
    package enum UserInput: Codable, Equatable, Sendable {
        case text(String)
        case image(url: String)
        case localImage(path: String)
        case skill(name: String, path: String)
        case mention(name: String, path: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case url
            case path
            case name
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "text":
                self = .text(try container.decode(String.self, forKey: .text))
            case "image":
                self = .image(url: try container.decode(String.self, forKey: .url))
            case "localImage":
                self = .localImage(path: try container.decode(String.self, forKey: .path))
            case "skill":
                self = .skill(
                    name: try container.decode(String.self, forKey: .name),
                    path: try container.decode(String.self, forKey: .path)
                )
            case "mention":
                self = .mention(
                    name: try container.decode(String.self, forKey: .name),
                    path: try container.decode(String.self, forKey: .path)
                )
            case let type:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unsupported app-server input type: \(type)"
                )
            }
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let url):
                try container.encode("image", forKey: .type)
                try container.encode(url, forKey: .url)
            case .localImage(let path):
                try container.encode("localImage", forKey: .type)
                try container.encode(path, forKey: .path)
            case .skill(let name, let path):
                try container.encode("skill", forKey: .type)
                try container.encode(name, forKey: .name)
                try container.encode(path, forKey: .path)
            case .mention(let name, let path):
                try container.encode("mention", forKey: .type)
                try container.encode(name, forKey: .name)
                try container.encode(path, forKey: .path)
            }
        }
    }
}

extension AppServerAPI.Turn {
    package enum SandboxPolicy: Codable, Equatable, Sendable {
        case readOnly(networkAccess: Bool)
        case workspaceWrite(
            writableRoots: [String],
            networkAccess: Bool,
            excludeTmpdirEnvVar: Bool,
            excludeSlashTmp: Bool
        )
        case dangerFullAccess

        private enum CodingKeys: String, CodingKey {
            case type
            case writableRoots
            case networkAccess
            case excludeTmpdirEnvVar
            case excludeSlashTmp
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "readOnly":
                self = .readOnly(
                    networkAccess: try container.decodeIfPresent(Bool.self, forKey: .networkAccess)
                        ?? false)
            case "workspaceWrite":
                self = .workspaceWrite(
                    writableRoots: try container.decodeIfPresent(
                        [String].self, forKey: .writableRoots) ?? [],
                    networkAccess: try container.decodeIfPresent(Bool.self, forKey: .networkAccess)
                        ?? false,
                    excludeTmpdirEnvVar: try container.decodeIfPresent(
                        Bool.self, forKey: .excludeTmpdirEnvVar) ?? false,
                    excludeSlashTmp: try container.decodeIfPresent(
                        Bool.self, forKey: .excludeSlashTmp) ?? false
                )
            case "dangerFullAccess":
                self = .dangerFullAccess
            case let type:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unsupported sandbox policy type: \(type)"
                )
            }
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .readOnly(let networkAccess):
                try container.encode("readOnly", forKey: .type)
                try container.encode(networkAccess, forKey: .networkAccess)
            case .workspaceWrite(
                let writableRoots, let networkAccess, let excludeTmpdirEnvVar, let excludeSlashTmp):
                try container.encode("workspaceWrite", forKey: .type)
                try container.encode(writableRoots, forKey: .writableRoots)
                try container.encode(networkAccess, forKey: .networkAccess)
                try container.encode(excludeTmpdirEnvVar, forKey: .excludeTmpdirEnvVar)
                try container.encode(excludeSlashTmp, forKey: .excludeSlashTmp)
            case .dangerFullAccess:
                try container.encode("dangerFullAccess", forKey: .type)
            }
        }
    }
}

extension AppServerAPI.Turn.Start {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String
        package var input: [AppServerAPI.UserInput]
        package var approvalPolicy: String?
        package var approvalsReviewer: String?
        package var clientUserMessageID: String?
        package var cwd: String?
        package var effort: String?
        package var model: String?
        package var outputSchema: AppServerJSONValue?
        package var personality: String?
        package var sandboxPolicy: AppServerAPI.Turn.SandboxPolicy?
        package var serviceTier: String?
        package var summary: String?

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case input
            case approvalPolicy
            case approvalsReviewer
            case clientUserMessageID = "clientUserMessageId"
            case cwd
            case effort
            case model
            case outputSchema
            case personality
            case sandboxPolicy
            case serviceTier
            case summary
        }

        package init(
            threadID: String,
            input: [AppServerAPI.UserInput],
            approvalPolicy: String? = nil,
            approvalsReviewer: String? = nil,
            clientUserMessageID: String? = nil,
            cwd: String? = nil,
            effort: String? = nil,
            model: String? = nil,
            outputSchema: AppServerJSONValue? = nil,
            personality: String? = nil,
            sandboxPolicy: AppServerAPI.Turn.SandboxPolicy? = nil,
            serviceTier: String? = nil,
            summary: String? = nil
        ) {
            self.threadID = threadID
            self.input = input
            self.approvalPolicy = approvalPolicy
            self.approvalsReviewer = approvalsReviewer
            self.clientUserMessageID = clientUserMessageID
            self.cwd = cwd
            self.effort = effort
            self.model = model
            self.outputSchema = outputSchema
            self.personality = personality
            self.sandboxPolicy = sandboxPolicy
            self.serviceTier = serviceTier
            self.summary = summary
        }
    }

    package struct Response: Codable, Equatable, Sendable {
        package var turn: AppServerAPI.Turn.Payload

        package init(turn: AppServerAPI.Turn.Payload) {
            self.turn = turn
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Turn.Start.Response

        package static let method = "turn/start"
        package var params: AppServerAPI.Turn.Start.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Turn.Start.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Turn.Steer {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String
        package var expectedTurnID: String
        package var input: [AppServerAPI.UserInput]

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case expectedTurnID = "expectedTurnId"
            case input
        }

        package init(threadID: String, expectedTurnID: String, input: [AppServerAPI.UserInput]) {
            self.threadID = threadID
            self.expectedTurnID = expectedTurnID
            self.input = input
        }
    }

    package struct Response: Codable, Equatable, Sendable {
        package var turnID: String

        enum CodingKeys: String, CodingKey {
            case turnID = "turnId"
        }

        package init(turnID: String) {
            self.turnID = turnID
        }
    }

    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Turn.Steer.Response

        package static let method = "turn/steer"
        package var params: AppServerAPI.Turn.Steer.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Turn.Steer.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Turn.Interrupt {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String
        package var turnID: String

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case turnID = "turnId"
        }

        package init(threadID: String, turnID: String) {
            self.threadID = threadID
            self.turnID = turnID
        }
    }
}

extension AppServerAPI.Turn.Interrupt {
    package struct Request: AppServerAPI.Request {
        package typealias Response = EmptyResponse

        package static let method = "turn/interrupt"
        package var params: AppServerAPI.Turn.Interrupt.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Turn.Interrupt.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.Rollback {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String
        package var numTurns: Int

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case numTurns
        }

        package init(threadID: String, numTurns: Int) {
            self.threadID = threadID
            self.numTurns = numTurns
        }
    }
}

extension AppServerAPI.Thread.Rollback {
    package struct Request: AppServerAPI.Request {
        package typealias Response = EmptyResponse

        package static let method = "thread/rollback"
        package var params: AppServerAPI.Thread.Rollback.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Thread.Rollback.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.Delete {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
        }

        package init(threadID: String) {
            self.threadID = threadID
        }
    }
}

extension AppServerAPI.Thread.Delete {
    package struct Request: AppServerAPI.Request {
        package typealias Response = EmptyResponse

        package static let method = "thread/delete"
        package var params: AppServerAPI.Thread.Delete.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Thread.Delete.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.Unsubscribe {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
        }

        package init(threadID: String) {
            self.threadID = threadID
        }
    }
}

extension AppServerAPI.Thread.Unsubscribe {
    package enum Status: String, Codable, Equatable, Sendable {
        case notLoaded
        case notSubscribed
        case unsubscribed
    }
}

extension AppServerAPI.Thread.Unsubscribe {
    package struct Response: Codable, Equatable, Sendable {
        package var status: AppServerAPI.Thread.Unsubscribe.Status

        package init(status: AppServerAPI.Thread.Unsubscribe.Status) {
            self.status = status
        }
    }
}

extension AppServerAPI.Thread.Unsubscribe {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Thread.Unsubscribe.Response

        package static let method = "thread/unsubscribe"
        package var params: AppServerAPI.Thread.Unsubscribe.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Thread.Unsubscribe.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Thread.BackgroundTerminals.Clean {
    package struct Params: Codable, Equatable, Sendable {
        package var threadID: String

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
        }

        package init(threadID: String) {
            self.threadID = threadID
        }
    }
}

extension AppServerAPI.Thread.BackgroundTerminals.Clean {
    package struct Request: AppServerAPI.Request {
        package typealias Response = EmptyResponse

        package static let method = "thread/backgroundTerminals/clean"
        package var params: AppServerAPI.Thread.BackgroundTerminals.Clean.Params
        package var scope: AppServerAPI.RequestScope? {
            .thread(params.threadID)
        }

        package init(params: AppServerAPI.Thread.BackgroundTerminals.Clean.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Config.Read {
    package struct Response: Codable, Equatable, Sendable {
        package var config: AppServerAPI.Config.Snapshot

        package init(config: AppServerAPI.Config.Snapshot) {
            self.config = config
        }
    }
}

extension AppServerAPI.Config {
    package struct Snapshot: Codable, Equatable, Sendable {
        package var model: String?
        package var reviewModel: String?
        package var modelReasoningEffort: String?
        package var serviceTier: String?

        enum CodingKeys: String, CodingKey {
            case model
            case reviewModel = "review_model"
            case modelReasoningEffort = "model_reasoning_effort"
            case serviceTier = "service_tier"
        }

        package init(
            model: String? = nil,
            reviewModel: String? = nil,
            modelReasoningEffort: String? = nil,
            serviceTier: String? = nil
        ) {
            self.model = model
            self.reviewModel = reviewModel
            self.modelReasoningEffort = modelReasoningEffort
            self.serviceTier = serviceTier
        }
    }
}

extension AppServerAPI.Config.Read {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Config.Read.Response

        package static let method = "config/read"
        package var params: EmptyResponse

        package init() {
            self.params = .init()
        }
    }
}

extension AppServerAPI.Config {
    package enum Value: Encodable, Equatable, Sendable {
        case string(String)
        case null

        package func encode(to encoder: Encoder) throws {
            switch self {
            case .string(let value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .null:
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            }
        }
    }
}

extension AppServerAPI.Config {
    package enum MergeStrategy: String, Codable, Equatable, Sendable {
        case replace
        case upsert
    }
}

extension AppServerAPI.Config {
    package struct Edit: Encodable, Equatable, Sendable {
        package var keyPath: String
        package var value: AppServerAPI.Config.Value
        package var mergeStrategy: AppServerAPI.Config.MergeStrategy

        package init(
            keyPath: String,
            value: AppServerAPI.Config.Value,
            mergeStrategy: AppServerAPI.Config.MergeStrategy = .replace
        ) {
            self.keyPath = keyPath
            self.value = value
            self.mergeStrategy = mergeStrategy
        }
    }
}

extension AppServerAPI.Config.BatchWrite {
    package struct Params: Encodable, Equatable, Sendable {
        package var edits: [AppServerAPI.Config.Edit]
        package var filePath: String?
        package var expectedVersion: String?
        package var reloadUserConfig: Bool

        package init(
            edits: [AppServerAPI.Config.Edit],
            filePath: String? = nil,
            expectedVersion: String? = nil,
            reloadUserConfig: Bool = true
        ) {
            self.edits = edits
            self.filePath = filePath
            self.expectedVersion = expectedVersion
            self.reloadUserConfig = reloadUserConfig
        }
    }
}

extension AppServerAPI.Config.BatchWrite {
    package struct Response: Decodable, Equatable, Sendable {
        package var status: String
        package var version: String?
        package var filePath: String?
    }
}

extension AppServerAPI.Config.BatchWrite {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Config.BatchWrite.Response

        package static let method = "config/batchWrite"
        package var params: AppServerAPI.Config.BatchWrite.Params

        package init(params: AppServerAPI.Config.BatchWrite.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Model.List {
    package struct Params: Codable, Equatable, Sendable {
        package var cursor: String?
        package var limit: Int?
        package var includeHidden: Bool?

        package init(
            cursor: String? = nil,
            limit: Int? = nil,
            includeHidden: Bool? = nil
        ) {
            self.cursor = cursor
            self.limit = limit
            self.includeHidden = includeHidden
        }
    }
}

extension AppServerAPI.Model.List {
    package struct Response: Codable, Equatable, Sendable {
        package var data: [CodexModel]
        package var nextCursor: String?

        package init(
            data: [CodexModel],
            nextCursor: String? = nil
        ) {
            self.data = data
            self.nextCursor = nextCursor
        }
    }
}

extension AppServerAPI.Model.List {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Model.List.Response

        package static let method = "model/list"
        package var params: AppServerAPI.Model.List.Params

        package init(params: AppServerAPI.Model.List.Params = .init(includeHidden: true)) {
            self.params = params
        }
    }
}

extension AppServerAPI.Auth.Read {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Account.Read.Response

        package static let method = "account/read"
        package var params: AppServerAPI.Account.Read.Params

        package init() {
            self.params = .init(refreshToken: false)
        }
    }
}

extension AppServerAPI.Account.Read {
    package struct Params: Codable, Equatable, Sendable {
        package var refreshToken: Bool

        package init(refreshToken: Bool) {
            self.refreshToken = refreshToken
        }
    }
}

extension AppServerAPI.Account.Read {
    package struct Response: Codable, Equatable, Sendable {
        package var account: AppServerAPI.Account.Snapshot?
        package var requiresOpenAIAuth: Bool

        enum CodingKeys: String, CodingKey {
            case account
            case requiresOpenAIAuth = "requiresOpenaiAuth"
        }

        package init(
            account: AppServerAPI.Account.Snapshot? = nil, requiresOpenAIAuth: Bool = false
        ) {
            self.account = account
            self.requiresOpenAIAuth = requiresOpenAIAuth
        }
    }
}

extension AppServerAPI.Account.Read {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Account.Read.Response

        package static let method = "account/read"
        package var params: AppServerAPI.Account.Read.Params

        package init(params: AppServerAPI.Account.Read.Params = .init(refreshToken: false)) {
            self.params = params
        }
    }
}

extension AppServerAPI.Account.RateLimits.Read {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Account.RateLimits.Response

        package static let method = "account/rateLimits/read"
        package var params: EmptyResponse

        package init() {
            self.params = .init()
        }
    }
}

extension AppServerAPI.Account.RateLimits {
    package struct Response: Codable, Equatable, Sendable {
        package var rateLimits: AppServerAPI.Account.RateLimits.Snapshot
        package var rateLimitsByLimitID: [String: AppServerAPI.Account.RateLimits.Snapshot]?

        enum CodingKeys: String, CodingKey {
            case rateLimits
            case rateLimitsByLimitID = "rateLimitsByLimitId"
        }

        package init(
            rateLimits: AppServerAPI.Account.RateLimits.Snapshot,
            rateLimitsByLimitID: [String: AppServerAPI.Account.RateLimits.Snapshot]? = nil
        ) {
            self.rateLimits = rateLimits
            self.rateLimitsByLimitID = rateLimitsByLimitID
        }
    }
}

extension AppServerAPI.Account.RateLimits {
    package struct Snapshot: Codable, Equatable, Sendable {
        package var limitID: String?
        package var primary: AppServerAPI.Account.RateLimits.Window?
        package var secondary: AppServerAPI.Account.RateLimits.Window?
        package var planType: String?

        enum CodingKeys: String, CodingKey {
            case limitID = "limitId"
            case primary
            case secondary
            case planType
        }

        package init(
            limitID: String? = nil,
            primary: AppServerAPI.Account.RateLimits.Window? = nil,
            secondary: AppServerAPI.Account.RateLimits.Window? = nil,
            planType: String? = nil
        ) {
            self.limitID = limitID
            self.primary = primary
            self.secondary = secondary
            self.planType = planType
        }
    }
}

extension AppServerAPI.Account.RateLimits {
    package struct Window: Codable, Equatable, Sendable {
        package var usedPercent: Int
        package var windowDurationMins: Int?
        package var resetsAt: Int64?

        private enum CodingKeys: String, CodingKey {
            case usedPercent
            case usedPercentSnake = "used_percent"
            case windowDurationMins
            case windowDurationMinsSnake = "window_duration_mins"
            case windowMinutes = "window_minutes"
            case resetsAt
            case resetsAtSnake = "resets_at"
        }

        package init(
            usedPercent: Int,
            windowDurationMins: Int? = nil,
            resetsAt: Int64? = nil
        ) {
            self.usedPercent = usedPercent
            self.windowDurationMins = windowDurationMins
            self.resetsAt = resetsAt
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let usedPercent = try Self.decodeNumber(
                for: [.usedPercent, .usedPercentSnake],
                in: container
            )
            self.usedPercent = Int(usedPercent.rounded())
            windowDurationMins = try Self.decodeOptionalInt(
                for: [.windowDurationMins, .windowDurationMinsSnake, .windowMinutes],
                in: container
            )
            resetsAt = try Self.decodeOptionalInt64(
                for: [.resetsAt, .resetsAtSnake],
                in: container
            )
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(usedPercent, forKey: .usedPercent)
            try container.encodeIfPresent(windowDurationMins, forKey: .windowDurationMins)
            try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
        }

        private static func decodeNumber(
            for keys: [CodingKeys],
            in container: KeyedDecodingContainer<CodingKeys>
        ) throws -> Double {
            for key in keys where container.contains(key) {
                if let value = try? container.decode(Double.self, forKey: key) {
                    return value
                }
                throw DecodingError.typeMismatch(
                    Double.self,
                    .init(
                        codingPath: container.codingPath + [key],
                        debugDescription: "Expected numeric rate-limit field."
                    )
                )
            }
            throw DecodingError.keyNotFound(
                keys[0],
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Missing rate-limit field \(keys[0].stringValue)."
                )
            )
        }

        private static func decodeOptionalInt(
            for keys: [CodingKeys],
            in container: KeyedDecodingContainer<CodingKeys>
        ) throws -> Int? {
            guard let value = try decodeOptionalInt64(for: keys, in: container) else {
                return nil
            }
            guard let intValue = Int(exactly: value) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: container.codingPath,
                        debugDescription: "Rate-limit integer value exceeds platform Int range."
                    )
                )
            }
            return intValue
        }

        private static func decodeOptionalInt64(
            for keys: [CodingKeys],
            in container: KeyedDecodingContainer<CodingKeys>
        ) throws -> Int64? {
            for key in keys where container.contains(key) {
                if try container.decodeNil(forKey: key) {
                    return nil
                }
                if let value = try? container.decode(Int64.self, forKey: key) {
                    return value
                }
                if let value = try? container.decode(Double.self, forKey: key) {
                    return Int64(value.rounded())
                }
                throw DecodingError.typeMismatch(
                    Int64.self,
                    .init(
                        codingPath: container.codingPath + [key],
                        debugDescription: "Expected integer rate-limit field."
                    )
                )
            }
            return nil
        }
    }
}

extension AppServerAPI.Account.RateLimits.Response {
    package var codexRateLimitWindows:
        [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)]
    {
        Self.rateLimitWindows(from: codexSnapshot)
    }

    package var codexPlanType: String? {
        codexSnapshot?.planType
    }

    private var codexSnapshot: AppServerAPI.Account.RateLimits.Snapshot? {
        if let codexSnapshot = rateLimitsByLimitID?["codex"] {
            return codexSnapshot
        }
        if let codexSnapshot = rateLimitsByLimitID?.first(where: { limitID, snapshot in
            Self.isCodexRateLimit(limitID) || Self.isCodexRateLimit(snapshot.limitID)
        })?.value {
            return codexSnapshot
        }
        if Self.isCodexRateLimit(rateLimits.limitID) {
            return rateLimits
        }
        return nil
    }

    private static func rateLimitWindows(
        from snapshot: AppServerAPI.Account.RateLimits.Snapshot?
    ) -> [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)] {
        [snapshot?.primary, snapshot?.secondary].compactMap { window in
            guard let window,
                let duration = window.windowDurationMins
            else {
                return nil
            }
            return (
                windowDurationMinutes: duration,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    package static func isCodexRateLimit(_ limitID: String?) -> Bool {
        let trimmedLimitID = limitID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLimitID =
            if let trimmedLimitID, trimmedLimitID.isEmpty == false {
                trimmedLimitID
            } else {
                "codex"
            }
        return normalizedLimitID == "codex" || normalizedLimitID.hasPrefix("codex_")
    }
}

extension AppServerAPI.Account {
    package struct Snapshot: Codable, Equatable, Sendable {
        package enum Kind: String, Codable, Equatable, Sendable {
            case chatGPT = "chatgpt"
            case apiKey
            case amazonBedrock
        }

        package var id: String
        package var kind: Kind
        package var label: String
        package var planType: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case email
            case planType
        }

        package init(
            kind: Kind,
            id: String,
            label: String,
            planType: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.label = label
            self.planType = planType
        }

        package init(email: String, planType: String) {
            self.init(
                kind: .chatGPT,
                id: Self.normalizedAccountID(email),
                label: email,
                planType: planType
            )
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(Kind.self, forKey: .type)
            switch kind {
            case .apiKey:
                self.init(kind: .apiKey, id: "api-key", label: "API Key")
            case .chatGPT:
                let email = try container.decodeIfPresent(String.self, forKey: .email)
                let normalizedEmail = email.map(Self.normalizedAccountID) ?? ""
                let label = email?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayLabel = label.flatMap { $0.isEmpty ? nil : $0 } ?? "ChatGPT"
                self.init(
                    kind: .chatGPT,
                    id: normalizedEmail.isEmpty ? "chatgpt" : normalizedEmail,
                    label: displayLabel,
                    planType: try container.decodeIfPresent(String.self, forKey: .planType)
                )
            case .amazonBedrock:
                self.init(kind: .amazonBedrock, id: "amazon-bedrock", label: "Amazon Bedrock")
            }
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .type)
            switch kind {
            case .apiKey, .amazonBedrock:
                break
            case .chatGPT:
                try container.encode(label, forKey: .email)
                try container.encodeIfPresent(planType, forKey: .planType)
            }
        }

        private static func normalizedAccountID(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
    }
}

extension AppServerAPI.Account.Login {
    package enum Params: Codable, Equatable, Sendable {
        case chatGPT(codexStreamlinedLogin: Bool = true)
        case apiKey(String)

        private enum Kind: String, Codable {
            case apiKey
            case chatGPT = "chatgpt"
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case apiKey
            case codexStreamlinedLogin
        }

        package var type: String {
            switch self {
            case .chatGPT:
                "chatgpt"
            case .apiKey:
                "apiKey"
            }
        }

        package var apiKey: String? {
            guard case .apiKey(let apiKey) = self else {
                return nil
            }
            return apiKey
        }

        package var codexStreamlinedLogin: Bool? {
            guard case .chatGPT(let codexStreamlinedLogin) = self else {
                return nil
            }
            return codexStreamlinedLogin
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .type) {
            case .chatGPT:
                guard container.contains(.apiKey) == false else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .apiKey,
                        in: container,
                        debugDescription: "ChatGPT login parameters cannot contain an API key."
                    )
                }
                self = .chatGPT(
                    codexStreamlinedLogin: try container.decode(
                        Bool.self,
                        forKey: .codexStreamlinedLogin
                    )
                )
            case .apiKey:
                guard container.contains(.codexStreamlinedLogin) == false else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .codexStreamlinedLogin,
                        in: container,
                        debugDescription: "API-key login parameters cannot contain ChatGPT options."
                    )
                }
                self = .apiKey(try container.decode(String.self, forKey: .apiKey))
            }
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .chatGPT(let codexStreamlinedLogin):
                try container.encode(Kind.chatGPT, forKey: .type)
                try container.encode(codexStreamlinedLogin, forKey: .codexStreamlinedLogin)
            case .apiKey(let apiKey):
                try container.encode(Kind.apiKey, forKey: .type)
                try container.encode(apiKey, forKey: .apiKey)
            }
        }
    }
}

extension AppServerAPI.Account.Login {
    package enum Response: Codable, Equatable, Sendable {
        case apiKey
        case chatgpt(loginID: String, authURL: String)
        case chatgptDeviceCode(loginID: String, verificationURL: String, userCode: String)
        case chatgptAuthTokens

        private enum CodingKeys: String, CodingKey {
            case type
            case loginID = "loginId"
            case authURL = "authUrl"
            case verificationURL = "verificationUrl"
            case userCode
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "apiKey":
                self = .apiKey
            case "chatgpt":
                self = .chatgpt(
                    loginID: try container.decode(String.self, forKey: .loginID),
                    authURL: try container.decode(String.self, forKey: .authURL)
                )
            case "chatgptDeviceCode":
                self = .chatgptDeviceCode(
                    loginID: try container.decode(String.self, forKey: .loginID),
                    verificationURL: try container.decode(String.self, forKey: .verificationURL),
                    userCode: try container.decode(String.self, forKey: .userCode)
                )
            case "chatgptAuthTokens":
                self = .chatgptAuthTokens
            case let type:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unsupported login response type: \(type)"
                )
            }
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .apiKey:
                try container.encode("apiKey", forKey: .type)
            case .chatgpt(let loginID, let authURL):
                try container.encode("chatgpt", forKey: .type)
                try container.encode(loginID, forKey: .loginID)
                try container.encode(authURL, forKey: .authURL)
            case .chatgptDeviceCode(let loginID, let verificationURL, let userCode):
                try container.encode("chatgptDeviceCode", forKey: .type)
                try container.encode(loginID, forKey: .loginID)
                try container.encode(verificationURL, forKey: .verificationURL)
                try container.encode(userCode, forKey: .userCode)
            case .chatgptAuthTokens:
                try container.encode("chatgptAuthTokens", forKey: .type)
            }
        }
    }
}

extension AppServerAPI.Account.Login.Response {
    package var pendingLoginID: String? {
        switch self {
        case .chatgpt(let loginID, _), .chatgptDeviceCode(let loginID, _, _):
            loginID
        case .apiKey, .chatgptAuthTokens:
            nil
        }
    }
}

extension AppServerAPI.Account.Login.Start {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Account.Login.Response

        package static let method = "account/login/start"
        package var params: AppServerAPI.Account.Login.Params

        package init(params: AppServerAPI.Account.Login.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Account.Login.Cancel {
    package struct Params: Codable, Equatable, Sendable {
        package var loginID: String

        enum CodingKeys: String, CodingKey {
            case loginID = "loginId"
        }

        package init(loginID: String) {
            self.loginID = loginID
        }
    }
}

extension AppServerAPI.Account.Login.Cancel {
    package struct Response: Codable, Equatable, Sendable {
        package var status: String

        package init(status: String = "canceled") {
            self.status = status
        }
    }
}

extension AppServerAPI.Account.Login.Cancel {
    package struct Request: AppServerAPI.Request {
        package typealias Response = AppServerAPI.Account.Login.Cancel.Response

        package static let method = "account/login/cancel"
        package var params: AppServerAPI.Account.Login.Cancel.Params

        package init(params: AppServerAPI.Account.Login.Cancel.Params) {
            self.params = params
        }
    }
}

extension AppServerAPI.Account.Logout {
    package struct Request: AppServerAPI.Request {
        package typealias Response = EmptyResponse

        package static let method = "account/logout"
        package var params: EmptyResponse

        package init() {
            self.params = .init()
        }
    }
}
