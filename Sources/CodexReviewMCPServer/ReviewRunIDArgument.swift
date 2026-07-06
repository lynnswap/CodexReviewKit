import CodexReviewKit
import MCP

enum ReviewRunIDArgument {
    static let acceptedNames = ["runId", "runID", "jobId", "jobID"]
    static let requiredDescription = acceptedNames.joined(separator: "/")

    static func properties() -> [String: Value] {
        Dictionary(uniqueKeysWithValues: acceptedNames.map { name in
            (name, Value.object(["type": .string("string")]))
        })
    }

    static func requiredAnyOf() -> Value {
        .array(acceptedNames.map { name in
            .object(["required": .array([.string(name)])])
        })
    }

    static func optionalValue(in arguments: [String: Value]) throws -> String? {
        let provided = acceptedNames.compactMap { name -> (name: String, value: String)? in
            guard let value = arguments[name]?.stringValue?.nilIfEmpty else {
                return nil
            }
            return (name, value)
        }
        guard let first = provided.first else {
            return nil
        }
        if let conflict = provided.first(where: { $0.value != first.value }) {
            throw MCPProtocolServerError.invalidArgument(
                "Conflicting run identifier arguments: \(first.name) and \(conflict.name)."
            )
        }
        return first.value
    }

    static func requiredValue(in arguments: [String: Value]) throws -> String {
        guard let runID = try optionalValue(in: arguments) else {
            throw MCPProtocolServerError.missingArgument(requiredDescription)
        }
        return runID
    }
}
