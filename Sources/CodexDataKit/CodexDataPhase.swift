import CodexAppServerKit

public enum CodexTurnTerminalDisposition: Equatable, Sendable {
    case completed
    case interrupted
    case failed
    case invalid(rawStatus: String)
}

public enum CodexChatPhase: Equatable, Sendable {
    case idle
    case loading
    case running(turnID: CodexTurnID)
    case terminal(
        turnID: CodexTurnID,
        disposition: CodexTurnTerminalDisposition
    )
    case failed(CodexFetchFailure)

    public var turnID: CodexTurnID? {
        switch self {
        case .running(let turnID), .terminal(let turnID, _):
            turnID
        case .idle, .loading, .failed:
            nil
        }
    }
}

extension CodexTurnOutcome {
    package var chatTerminalDisposition: CodexTurnTerminalDisposition {
        switch self {
        case .completed:
            .completed
        case .interrupted:
            .interrupted
        case .failed:
            .failed
        case .invalidTerminalStatus(let rawStatus, _, _):
            .invalid(rawStatus: rawStatus)
        }
    }
}
