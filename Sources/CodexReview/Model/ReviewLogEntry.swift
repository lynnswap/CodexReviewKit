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

package struct ReviewMonitorLogBlockID: Codable, Hashable, Sendable {
    package var rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

package struct ReviewMonitorLogBlock: Equatable, Sendable {
    package var id: ReviewMonitorLogBlockID
    package var kind: ReviewLogEntry.Kind
    package var groupID: String?
    package var range: NSRange

    package init(
        id: ReviewMonitorLogBlockID,
        kind: ReviewLogEntry.Kind,
        groupID: String?,
        range: NSRange
    ) {
        self.id = id
        self.kind = kind
        self.groupID = groupID
        self.range = range
    }
}

package struct ReviewMonitorLogAppend: Equatable, Sendable {
    package var kind: ReviewLogEntry.Kind
    package var blockID: ReviewMonitorLogBlockID
    package var range: NSRange
    package var text: String
    package var textUTF16Length: Int

    package init(
        kind: ReviewLogEntry.Kind,
        blockID: ReviewMonitorLogBlockID,
        range: NSRange,
        text: String,
        textUTF16Length: Int? = nil
    ) {
        self.kind = kind
        self.blockID = blockID
        self.range = range
        self.text = text
        self.textUTF16Length = textUTF16Length ?? (text as NSString).length
    }
}

package struct ReviewMonitorLogReplacement: Equatable, Sendable {
    package var kind: ReviewLogEntry.Kind
    package var blockID: ReviewMonitorLogBlockID
    package var range: NSRange
    package var text: String
    package var textUTF16Length: Int

    package init(
        kind: ReviewLogEntry.Kind,
        blockID: ReviewMonitorLogBlockID,
        range: NSRange,
        text: String,
        textUTF16Length: Int? = nil
    ) {
        self.kind = kind
        self.blockID = blockID
        self.range = range
        self.text = text
        self.textUTF16Length = textUTF16Length ?? (text as NSString).length
    }
}

package enum ReviewMonitorLogChange: Equatable, Sendable {
    case reload
    case append(ReviewMonitorLogAppend)
    case replace(ReviewMonitorLogReplacement)
}

package struct ReviewMonitorLogDocument: Equatable, Sendable {
    package var text: String
    package var textUTF16Length: Int
    package var blocks: [ReviewMonitorLogBlock]
    package var revision: UInt64
    package var lastChange: ReviewMonitorLogChange

    package init(
        text: String = "",
        textUTF16Length: Int? = nil,
        blocks: [ReviewMonitorLogBlock] = [],
        revision: UInt64 = 0,
        lastChange: ReviewMonitorLogChange = .reload
    ) {
        self.text = text
        self.textUTF16Length = textUTF16Length ?? (text as NSString).length
        self.blocks = blocks
        self.revision = revision
        self.lastChange = lastChange
    }
}
