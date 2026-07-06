import MCP
import CodexReviewKit

func schema(for tool: CodexReviewMCP.Tool.Name) -> Value {
    switch tool {
    case .reviewStart:
        .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object(["type": .string("string")]),
                "cwd": .object(["type": .string("string")]),
                "target": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["type": .string("string")]),
                        "branch": .object(["type": .string("string")]),
                        "sha": .object(["type": .string("string")]),
                        "title": .object(["type": .string("string")]),
                        "instructions": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("type")]),
                ]),
            ]),
            "required": .array([.string("cwd"), .string("target")]),
        ])
    case .reviewAwait:
        .object([
            "type": .string("object"),
            "properties": .object(reviewRunIDProperties(extra: [
                "sessionID": .object(["type": .string("string")]),
            ])),
            "anyOf": ReviewRunIDArgument.requiredAnyOf(),
        ])
    case .reviewRead:
        .object([
            "type": .string("object"),
            "properties": .object(reviewRunIDProperties(extra: [
                "sessionID": .object(["type": .string("string")]),
            ])),
            "anyOf": ReviewRunIDArgument.requiredAnyOf(),
        ])
    case .reviewList:
        .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object(["type": .string("string")]),
                "cwd": .object(["type": .string("string")]),
                "statuses": .object(["type": .string("array")]),
                "limit": .object(["type": .string("integer")]),
            ]),
        ])
    case .reviewCancel:
        .object([
            "type": .string("object"),
            "properties": .object(reviewRunIDProperties(extra: [
                "sessionID": .object(["type": .string("string")]),
                "cwd": .object(["type": .string("string")]),
                "statuses": .object(["type": .string("array")]),
                "reason": .object(["type": .string("string")]),
            ])),
        ])
    }
}

private func reviewRunIDProperties(extra: [String: Value]) -> [String: Value] {
    var properties = ReviewRunIDArgument.properties()
    for (name, schema) in extra {
        properties[name] = schema
    }
    return properties
}
