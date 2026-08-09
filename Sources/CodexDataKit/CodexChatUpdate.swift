import CodexAppServerKit
import Foundation

package enum CodexChatMutation: Equatable, Sendable {
    case turnInserted(id: CodexTurnID)
    case turnUpdated(id: CodexTurnID)
    case turnRemoved(id: CodexTurnID)
    case itemInserted(id: CodexChatItemID, turnID: CodexTurnID?)
    case itemUpdated(id: CodexChatItemID, turnID: CodexTurnID?)
    case itemRemoved(locator: CodexChatItemLocator, modelID: CodexChatItemID)
    case itemTextAppended(id: CodexChatItemID, turnID: CodexTurnID?, delta: String)
    case statusChanged(CodexThreadStatus?)
    case phaseChanged(CodexChatPhase)

    var affectedTurnID: CodexTurnID? {
        switch self {
        case .statusChanged, .phaseChanged:
            nil
        case .turnInserted(let id), .turnUpdated(let id), .turnRemoved(let id):
            id
        case .itemInserted(_, let turnID), .itemUpdated(_, let turnID),
             .itemTextAppended(_, let turnID, _):
            turnID
        case .itemRemoved(let locator, _):
            locator.turnID
        }
    }
}

public struct CodexChatItemLocator: Equatable, Hashable, Sendable {
    public let id: String
    public let kind: CodexThreadItem.Kind
    public let turnID: CodexTurnID

    public init(id: String, kind: CodexThreadItem.Kind, turnID: CodexTurnID) {
        self.id = id
        self.kind = kind
        self.turnID = turnID
    }

    public init(item: CodexThreadItem, turnID: CodexTurnID) {
        self.init(id: item.id, kind: item.kind, turnID: turnID)
    }
}

public enum CodexChatUpdate: Equatable, Sendable {
    case turnInserted(CodexTurnSnapshot, index: Int)
    case turnUpdated(CodexTurnSnapshot, index: Int)
    case turnRemoved(id: CodexTurnID)
    case itemInserted(item: CodexThreadItem, turnID: CodexTurnID, index: Int)
    case itemUpdated(item: CodexThreadItem, turnID: CodexTurnID, index: Int)
    case itemRemoved(CodexChatItemLocator)
    case itemTextAppended(CodexChatItemLocator, delta: String)
    case statusChanged(CodexThreadStatus?)
    case phaseChanged(CodexChatPhase)

    public var affectedTurnID: CodexTurnID? {
        switch self {
        case .statusChanged, .phaseChanged:
            nil
        case .turnInserted(let turn, _), .turnUpdated(let turn, _):
            turn.id
        case .turnRemoved(let id):
            id
        case .itemInserted(_, let turnID, _),
             .itemUpdated(_, let turnID, _):
            turnID
        case .itemRemoved(let locator), .itemTextAppended(let locator, _):
            locator.turnID
        }
    }
}
