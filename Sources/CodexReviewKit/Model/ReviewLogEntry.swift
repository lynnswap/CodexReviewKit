import Foundation

package struct ReviewLogEntry: Codable, Identifiable, Sendable, Hashable {
    package struct Metadata: Codable, Sendable, Hashable {
        package struct CommandAction: Codable, Sendable, Hashable {
            package enum Kind: String, Codable, Sendable, Hashable {
                case read
                case listFiles
                case search
                case unknown
            }

            package let kind: Kind
            package let command: String?
            package let name: String?
            package let path: String?
            package let query: String?

            package init(
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

        package let sourceType: String
        package let title: String?
        package let status: String?
        package let detail: String?
        package let itemID: String?
        package let command: String?
        package let cwd: String?
        package let exitCode: Int?
        package let startedAt: Date?
        package let completedAt: Date?
        package let durationMs: Int?
        package let commandActions: [CommandAction]?
        package let commandStatus: String?
        package let namespace: String?
        package let server: String?
        package let tool: String?
        package let query: String?
        package let path: String?
        package let resultText: String?
        package let errorText: String?

        package init(
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

    package enum Kind: String, Codable, Sendable, Hashable {
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
        case contextCompaction
    }

    package let id: UUID
    package let kind: Kind
    package let groupID: String?
    package let replacesGroup: Bool
    package let text: String
    package let metadata: Metadata?
    package let timestamp: Date

    package init(
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
