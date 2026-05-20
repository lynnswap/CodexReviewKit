import Foundation

public struct ReviewLogEntry: Codable, Identifiable, Sendable, Hashable {
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
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        groupID: String? = nil,
        replacesGroup: Bool = false,
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.groupID = groupID
        self.replacesGroup = replacesGroup
        self.text = text
        self.timestamp = timestamp
    }

}
