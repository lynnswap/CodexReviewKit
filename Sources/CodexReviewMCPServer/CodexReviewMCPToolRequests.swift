import Foundation
import MCP
import CodexReviewKit

func toolRequest(
    tool: CodexReviewMCP.Tool.Name,
    arguments: [String: Value],
    defaultSessionID: String?,
    boundedReviewWaitDuration: Duration,
    useBoundedReviewStart: Bool
) throws -> CodexReviewMCP.Tool.Request {
    switch tool {
    case .reviewStart:
        let cwd = try requiredString("cwd", in: arguments)
        let target = try reviewTarget(from: requiredObject("target", in: arguments))
        return .reviewStart(
            sessionID: try sessionID(in: arguments, defaultSessionID: defaultSessionID) ?? "default",
            request: .init(cwd: cwd, target: target),
            waitTimeout: useBoundedReviewStart ? boundedReviewWaitDuration : nil
        )
    case .reviewAwait:
        return .reviewAwait(
            sessionID: try sessionID(in: arguments, defaultSessionID: defaultSessionID),
            runID: try requiredRunID(in: arguments),
            waitTimeout: boundedReviewWaitDuration
        )
    case .reviewRead:
        return .reviewRead(
            sessionID: try sessionID(in: arguments, defaultSessionID: defaultSessionID),
            runID: try requiredRunID(in: arguments)
        )
    case .reviewList:
        return .reviewList(
            sessionID: try sessionID(in: arguments, defaultSessionID: defaultSessionID),
            cwd: arguments["cwd"]?.stringValue,
            statuses: try statuses(from: arguments["statuses"]),
            limit: arguments["limit"]?.intValue
        )
    case .reviewCancel:
        let runID = try ReviewRunIDArgument.optionalValue(in: arguments)
        let sessionID = try sessionID(
            in: arguments,
            defaultSessionID: defaultSessionID,
            fallback: runID == nil ? "default" : nil
        )
        return .reviewCancel(
            sessionID: sessionID,
            selector: .init(
                runID: runID,
                cwd: arguments["cwd"]?.stringValue,
                statuses: try statuses(from: arguments["statuses"])
            ),
            reason: .mcpClient(message: arguments["reason"]?.stringValue ?? "Cancellation requested.")
        )
    }
}

func sessionID(
    in arguments: [String: Value],
    defaultSessionID: String?,
    fallback: String? = nil
) throws -> String? {
    let suppliedSessionID: String?
    if let suppliedValue = arguments["sessionID"] {
        guard let stringValue = suppliedValue.stringValue else {
            throw MCPProtocolServerError.invalidArgument("sessionID must be a string.")
        }
        suppliedSessionID = stringValue
    } else {
        suppliedSessionID = nil
    }
    if let defaultSessionID, let suppliedSessionID {
        guard suppliedSessionID == defaultSessionID else {
            throw MCPProtocolServerError.invalidArgument(
                "sessionID must match the active MCP transport session."
            )
        }
    }
    return defaultSessionID ?? suppliedSessionID ?? fallback
}

func requiredRunID(in arguments: [String: Value]) throws -> ReviewRunID {
    try ReviewRunIDArgument.requiredValue(in: arguments)
}

func reviewTarget(from object: [String: Value]) throws -> CodexReviewAPI.Target {
    switch object["type"]?.stringValue {
    case "uncommittedChanges":
        .uncommittedChanges
    case "baseBranch":
        .baseBranch(try requiredString("branch", in: object))
    case "commit":
        .commit(
            sha: try requiredString("sha", in: object),
            title: object["title"]?.stringValue
        )
    case "custom":
        .custom(instructions: try requiredString("instructions", in: object))
    case let type:
        throw MCPProtocolServerError.invalidArgument("Unsupported review target: \(type ?? "<missing>").")
    }
}

func statuses(from value: Value?) throws -> [ReviewRunState]? {
    guard let value else {
        return nil
    }
    guard let array = value.arrayValue else {
        throw MCPProtocolServerError.invalidArgument("statuses must be an array.")
    }
    return try array.map { item in
        guard let raw = item.stringValue, let status = ReviewRunState(rawValue: raw) else {
            throw MCPProtocolServerError.invalidArgument("Invalid review status.")
        }
        return status
    }
}

func requiredObject(
    _ key: String,
    in arguments: [String: Value]
) throws -> [String: Value] {
    guard let object = arguments[key]?.objectValue else {
        throw MCPProtocolServerError.missingArgument(key)
    }
    return object
}

func requiredString(
    _ key: String,
    in arguments: [String: Value]
) throws -> String {
    guard let value = arguments[key]?.stringValue, value.isEmpty == false else {
        throw MCPProtocolServerError.missingArgument(key)
    }
    return value
}
