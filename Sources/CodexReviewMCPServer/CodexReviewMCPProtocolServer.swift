import Foundation
import MCP
import CodexReview

@MainActor
package func makeMCPProtocolServer(
    adapter: CodexReviewMCPServer,
    defaultSessionID: String? = nil
) async -> Server {
    let server = Server(
        name: "codex_review",
        version: "0.1.0",
        capabilities: .init(
            resources: .init(listChanged: true),
            tools: .init(listChanged: true)
        )
    )

    await server.withMethodHandler(ListTools.self) { _ in
        let tools = await adapter.tools.map { descriptor in
            Tool(
                name: descriptor.name.rawValue,
                description: descriptor.description,
                inputSchema: schema(for: descriptor.name)
            )
        }
        return .init(tools: tools)
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard let tool = MCPToolName(rawValue: params.name) else {
            return .init(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        do {
            let request = try toolRequest(
                tool: tool,
                arguments: params.arguments ?? [:],
                defaultSessionID: defaultSessionID
            )
            let response = try await adapter.handle(request)
            return try toolResult(tool: tool, response: response)
        } catch {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    await server.withMethodHandler(ListResources.self) { _ in
        .init(resources: helpResources.map(\.resource))
    }

    await server.withMethodHandler(ReadResource.self) { params in
        let content = helpResources.first { $0.uri == params.uri }?.content
            ?? "Resource not found: \(params.uri)"
        return .init(contents: [.text(content, uri: params.uri, mimeType: "text/markdown")])
    }

    await server.withMethodHandler(ListResourceTemplates.self) { _ in
        .init(templates: helpResourceTemplates)
    }

    return server
}

private func schema(for tool: MCPToolName) -> Value {
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
    case .reviewRead:
        .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object(["type": .string("string")]),
                "jobID": .object(["type": .string("string")]),
                "jobId": .object(["type": .string("string")]),
                "logFilter": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string(ReviewLogFilter.defaultSetting.rawValue),
                        .string(ReviewLogFilter.all.rawValue),
                    ]),
                ]),
            ]),
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
            "properties": .object([
                "sessionID": .object(["type": .string("string")]),
                "jobID": .object(["type": .string("string")]),
                "jobId": .object(["type": .string("string")]),
                "cwd": .object(["type": .string("string")]),
                "statuses": .object(["type": .string("array")]),
                "reason": .object(["type": .string("string")]),
            ]),
        ])
    }
}

private func toolRequest(
    tool: MCPToolName,
    arguments: [String: Value],
    defaultSessionID: String?
) throws -> MCPToolRequest {
    switch tool {
    case .reviewStart:
        let cwd = try requiredString("cwd", in: arguments)
        let target = try reviewTarget(from: requiredObject("target", in: arguments))
        return .reviewStart(
            sessionID: sessionID(in: arguments, defaultSessionID: defaultSessionID) ?? "default",
            request: .init(cwd: cwd, target: target)
        )
    case .reviewRead:
        return .reviewRead(
            sessionID: sessionID(in: arguments, defaultSessionID: defaultSessionID),
            jobID: try requiredJobID(in: arguments),
            logFilter: try reviewLogFilter(in: arguments)
        )
    case .reviewList:
        return .reviewList(
            sessionID: sessionID(in: arguments, defaultSessionID: defaultSessionID),
            cwd: arguments["cwd"]?.stringValue,
            statuses: try statuses(from: arguments["statuses"]),
            limit: arguments["limit"]?.intValue
        )
    case .reviewCancel:
        let jobID = optionalJobID(in: arguments)
        let sessionID = sessionID(
            in: arguments,
            defaultSessionID: defaultSessionID,
            fallback: jobID == nil ? "default" : nil
        )
        return .reviewCancel(
            sessionID: sessionID,
            selector: .init(
                jobID: jobID,
                cwd: arguments["cwd"]?.stringValue,
                statuses: try statuses(from: arguments["statuses"])
            ),
            reason: .mcpClient(message: arguments["reason"]?.stringValue ?? "Cancellation requested.")
        )
    }
}

private func sessionID(
    in arguments: [String: Value],
    defaultSessionID: String?,
    fallback: String? = nil
) -> String? {
    defaultSessionID ?? arguments["sessionID"]?.stringValue ?? fallback
}

private func toolResult(tool: MCPToolName, response: MCPToolResponse) throws -> CallTool.Result {
    let value: Value
    let text: String
    let isError: Bool
    switch response {
    case .reviewRead(let result):
        value = tool == .reviewStart
            ? result.structuredContentForStart()
            : result.structuredContentForRead()
        text = result.textContent()
        isError = result.core.lifecycle.status == .failed
    case .reviewList(let result):
        value = result.structuredContent()
        text = "Listed \(result.items.count) review job(s)."
        isError = false
    case .reviewCancel(let result):
        value = result.structuredContent()
        text = result.textContent()
        isError = false
    }
    return try .init(
        content: [.text(text: text, annotations: nil, _meta: nil)],
        structuredContent: value,
        isError: isError
    )
}

private func optionalJobID(in arguments: [String: Value]) -> String? {
    arguments["jobID"]?.stringValue?.nilIfEmpty ?? arguments["jobId"]?.stringValue?.nilIfEmpty
}

private func requiredJobID(in arguments: [String: Value]) throws -> String {
    guard let jobID = optionalJobID(in: arguments) else {
        throw MCPProtocolServerError.missingArgument("jobID/jobId")
    }
    return jobID
}

private func reviewLogFilter(in arguments: [String: Value]) throws -> ReviewLogFilter {
    guard let rawValue = arguments["logFilter"]?.stringValue?.nilIfEmpty else {
        return .defaultSetting
    }
    guard let filter = ReviewLogFilter(rawValue: rawValue) else {
        throw MCPProtocolServerError.invalidArgument(
            "Unsupported logFilter: \(rawValue). Use `default` or `all`."
        )
    }
    return filter
}

private func reviewTarget(from object: [String: Value]) throws -> ReviewTarget {
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

private struct HelpResource: Sendable {
    var uri: String
    var name: String
    var description: String
    var content: String

    var resource: Resource {
        Resource(
            name: name,
            uri: uri,
            description: description,
            mimeType: "text/markdown"
        )
    }
}

private let helpResources: [HelpResource] = [
    .init(
        uri: "codex-review://help/overview",
        name: "Codex Review MCP Overview",
        description: "Overview of the Codex review MCP tools.",
        content: """
        # Codex Review MCP

        Use `review_start` to run a review, then `review_read`, `review_list`, or `review_cancel` to inspect or control review jobs.
        """
    ),
    .init(
        uri: "codex-review://help/tools/review_start",
        name: "review_start",
        description: "Input shape for starting a Codex review.",
        content: """
        # review_start

        Required arguments: `cwd` and `target`.

        Supported target types: `uncommittedChanges`, `baseBranch`, `commit`, and `custom`.
        """
    ),
    .init(
        uri: "codex-review://help/targets/uncommittedChanges",
        name: "Target: uncommittedChanges",
        description: "Review uncommitted workspace changes.",
        content: """
        # Target: uncommittedChanges

        `{"type":"uncommittedChanges"}`
        """
    ),
    .init(
        uri: "codex-review://help/targets/baseBranch",
        name: "Target: baseBranch",
        description: "Review changes against a base branch.",
        content: """
        # Target: baseBranch

        `{"type":"baseBranch","branch":"main"}`
        """
    ),
    .init(
        uri: "codex-review://help/targets/commit",
        name: "Target: commit",
        description: "Review a specific commit.",
        content: """
        # Target: commit

        `{"type":"commit","sha":"abc1234","title":"Optional title"}`
        """
    ),
    .init(
        uri: "codex-review://help/targets/custom",
        name: "Target: custom",
        description: "Run a review with custom instructions.",
        content: """
        # Target: custom

        `{"type":"custom","instructions":"Free-form review instructions"}`
        """
    ),
]

private let helpResourceTemplates: [Resource.Template] = [
    .init(
        uriTemplate: "codex-review://help/tools/{tool}",
        name: "Codex Review tool help",
        description: "Help for a Codex Review MCP tool.",
        mimeType: "text/markdown"
    ),
    .init(
        uriTemplate: "codex-review://help/targets/{target}",
        name: "Codex Review target help",
        description: "Help for a Codex Review target shape.",
        mimeType: "text/markdown"
    ),
]

private func statuses(from value: Value?) throws -> [ReviewJobState]? {
    guard let value else {
        return nil
    }
    guard let array = value.arrayValue else {
        throw MCPProtocolServerError.invalidArgument("statuses must be an array.")
    }
    return try array.map { item in
        guard let raw = item.stringValue, let status = ReviewJobState(rawValue: raw) else {
            throw MCPProtocolServerError.invalidArgument("Invalid review status.")
        }
        return status
    }
}

private func requiredObject(
    _ key: String,
    in arguments: [String: Value]
) throws -> [String: Value] {
    guard let object = arguments[key]?.objectValue else {
        throw MCPProtocolServerError.missingArgument(key)
    }
    return object
}

private func requiredString(
    _ key: String,
    in arguments: [String: Value]
) throws -> String {
    guard let value = arguments[key]?.stringValue, value.isEmpty == false else {
        throw MCPProtocolServerError.missingArgument(key)
    }
    return value
}

private extension ReviewReadResult {
    func textContent() -> String {
        core.reviewText.nilIfEmpty ?? core.lifecycle.status.rawValue
    }

    func structuredContentForStart() -> Value {
        structuredContent(includeDetails: false)
    }

    func structuredContentForRead() -> Value {
        structuredContent(includeDetails: true)
    }

    func structuredContent(includeDetails: Bool) -> Value {
        var object: [String: Value] = [
            "jobId": .string(jobID),
            "run": core.run.structuredContent(),
            "lifecycle": core.lifecycle.structuredContent(
                elapsedSeconds: elapsedSeconds,
                cancellable: cancellable
            ),
            "output": core.output.structuredContent(review: core.reviewText),
        ]
        if includeDetails {
            object["logs"] = .array(logs.map { $0.structuredContent() })
            object["rawLogText"] = .string(rawLogText)
        }
        return .object(object)
    }
}

private extension ReviewJobListItem {
    func structuredContent() -> Value {
        .object([
            "jobId": .string(jobID),
            "cwd": .string(cwd),
            "targetSummary": .string(targetSummary),
            "run": core.run.structuredContent(),
            "lifecycle": core.lifecycle.structuredContent(
                elapsedSeconds: elapsedSeconds,
                cancellable: cancellable
            ),
            "output": core.output.structuredContent(review: core.reviewText),
        ])
    }
}

private extension ReviewListResult {
    func structuredContent() -> Value {
        .object([
            "items": .array(items.map { $0.structuredContent() }),
        ])
    }
}

private extension ReviewCancelOutcome {
    func textContent() -> String {
        if cancelled {
            core.lifecycle.cancellation?.message ?? "Review cancelled."
        } else {
            "Review was already finished."
        }
    }

    func structuredContent() -> Value {
        .object([
            "jobId": .string(jobID),
            "cancelled": .bool(cancelled),
            "run": core.run.structuredContent(),
            "lifecycle": core.lifecycle.structuredContent(
                elapsedSeconds: nil,
                cancellable: false
            ),
            "output": core.output.structuredContent(review: core.reviewText),
        ])
    }
}

private extension ReviewLogEntry {
    func structuredContent() -> Value {
        var object: [String: Value] = [
            "id": .string(id.uuidString),
            "kind": .string(kind.rawValue),
            "replacesGroup": .bool(replacesGroup),
            "text": .string(text),
            "timestamp": .string(timestamp.ISO8601Format()),
        ]
        object["groupId"] = groupID.map(Value.string) ?? .null
        return .object(object)
    }
}

private extension ReviewRunMetadata {
    func structuredContent() -> Value {
        .object([
            "reviewThreadId": reviewThreadID.map(Value.string) ?? .null,
            "threadId": threadID.map(Value.string) ?? .null,
            "turnId": turnID.map(Value.string) ?? .null,
            "model": model.map(Value.string) ?? .null,
        ])
    }
}

private extension ReviewLifecycleState {
    func structuredContent(
        elapsedSeconds: Int?,
        cancellable: Bool
    ) -> Value {
        .object([
            "status": .string(status.rawValue),
            "exitCode": exitCode.map(Value.int) ?? .null,
            "startedAt": startedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "endedAt": endedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "elapsedSeconds": elapsedSeconds.map(Value.int) ?? .null,
            "cancellable": .bool(cancellable),
            "cancellation": cancellation.map { $0.structuredContent() } ?? .null,
            "errorMessage": errorMessage.map(Value.string) ?? .null,
        ])
    }
}

private extension ReviewOutputState {
    func structuredContent(review: String) -> Value {
        .object([
            "summary": .string(summary),
            "review": .string(review),
            "hasFinalReview": .bool(hasFinalReview),
            "lastAgentMessage": lastAgentMessage.map(Value.string) ?? .null,
            "reviewResult": reviewResult.map { $0.structuredContent() } ?? .null,
        ])
    }
}

private extension ReviewCancellation {
    func structuredContent() -> Value {
        .object([
            "source": .string(source.rawValue),
            "message": .string(message),
        ])
    }
}

private extension ParsedReviewResult {
    func structuredContent() -> Value {
        .object([
            "state": .string(state.rawValue),
            "findingCount": findingCount.map(Value.int) ?? .null,
            "findings": .array(findings.map { $0.structuredContent() }),
            "source": .string(source.rawValue),
            "parserVersion": .int(parserVersion),
        ])
    }
}

private extension ParsedReviewFinding {
    func structuredContent() -> Value {
        .object([
            "title": .string(title),
            "body": .string(body),
            "priority": priority.map(Value.int) ?? .null,
            "location": location.map { $0.structuredContent() } ?? .null,
            "rawText": .string(rawText),
        ])
    }
}

private extension ParsedReviewFindingLocation {
    func structuredContent() -> Value {
        .object([
            "path": .string(path),
            "startLine": .int(startLine),
            "endLine": .int(endLine),
        ])
    }
}

private enum MCPProtocolServerError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let key):
            "Missing required argument: \(key)."
        case .invalidArgument(let message):
            message
        }
    }
}
