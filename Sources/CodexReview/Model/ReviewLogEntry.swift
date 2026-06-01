import Foundation

public struct ReviewLogEntry: Codable, Identifiable, Sendable, Hashable {
    public struct Metadata: Codable, Sendable, Hashable {
        public struct CommandAction: Codable, Sendable, Hashable {
            public enum Kind: String, Codable, Sendable, Hashable {
                case read
                case listFiles
                case search
                case unknown
            }

            public let kind: Kind
            public let command: String?
            public let name: String?
            public let path: String?
            public let query: String?

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

        public let sourceType: String
        public let title: String?
        public let status: String?
        public let detail: String?
        public let itemID: String?
        public let command: String?
        public let cwd: String?
        public let exitCode: Int?
        public let startedAt: Date?
        public let completedAt: Date?
        public let durationMs: Int?
        public let commandActions: [CommandAction]?
        public let commandStatus: String?
        public let namespace: String?
        public let server: String?
        public let tool: String?
        public let query: String?
        public let path: String?
        public let resultText: String?
        public let errorText: String?

        public init(
            sourceType: String,
            title: String? = nil,
            status: String? = nil,
            detail: String? = nil,
            itemID: String? = nil,
            command: String? = nil,
            cwd: String? = nil,
            exitCode: Int? = nil,
            startedAt: Date? = nil,
            completedAt: Date? = nil,
            durationMs: Int? = nil,
            commandActions: [CommandAction]? = nil,
            commandStatus: String? = nil,
            namespace: String? = nil,
            server: String? = nil,
            tool: String? = nil,
            query: String? = nil,
            path: String? = nil,
            resultText: String? = nil,
            errorText: String? = nil
        ) {
            self.sourceType = sourceType
            self.title = title
            self.status = status
            self.detail = detail
            self.itemID = itemID
            self.command = command
            self.cwd = cwd
            self.exitCode = exitCode
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.durationMs = durationMs
            self.commandActions = commandActions
            self.commandStatus = commandStatus
            self.namespace = namespace
            self.server = server
            self.tool = tool
            self.query = query
            self.path = path
            self.resultText = resultText
            self.errorText = errorText
        }
    }

    public enum Kind: String, Codable, Sendable, Hashable {
        case agentMessage
        case command
        case commandOutput
        case plan
        case todoList
        case reasoning
        case reasoningSummary
        case rawReasoning
        case toolCall
        case diagnostic
        case error
        case progress
        case event
    }

    public let id: UUID
    public let kind: Kind
    public let groupID: String?
    public let replacesGroup: Bool
    public let text: String
    public let metadata: Metadata?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        groupID: String? = nil,
        replacesGroup: Bool = false,
        text: String,
        metadata: Metadata? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.groupID = groupID
        self.replacesGroup = replacesGroup
        self.text = text
        self.metadata = metadata
        self.timestamp = timestamp
    }

}
