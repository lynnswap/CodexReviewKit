import Foundation
import MCP
import CodexReview
import CodexReviewMCPAdapter

package actor MCPClientSessionState {
    private var clientInfo: Client.Info?

    package init() {}

    package func update(clientInfo: Client.Info) {
        self.clientInfo = clientInfo
    }

    package func usesBoundedReviewStart(httpContext: HTTPRequest?) -> Bool {
        if Self.isClaudeClientName(clientInfo?.name)
            || Self.isClaudeClientName(clientInfo?.title)
            || Self.isClaudeClientName(httpContext?.header("User-Agent"))
        {
            return true
        }
        return false
    }

    private static func isClaudeClientName(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return value.localizedCaseInsensitiveContains("claude")
    }
}

@MainActor
package func makeMCPProtocolServer(
    adapter: CodexReviewMCPServer,
    defaultSessionID: String? = nil,
    clientSession: MCPClientSessionState = .init(),
    boundedReviewWaitDuration: Duration = .seconds(540)
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
        guard let tool = CodexReviewMCP.Tool.Name(rawValue: params.name) else {
            return .init(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        do {
            let httpContext = Server.currentHandlerContext?.httpContext
            let useBoundedReviewStart = await clientSession.usesBoundedReviewStart(httpContext: httpContext)
            let request = try toolRequest(
                tool: tool,
                arguments: params.arguments ?? [:],
                defaultSessionID: defaultSessionID,
                boundedReviewWaitDuration: boundedReviewWaitDuration,
                useBoundedReviewStart: useBoundedReviewStart
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

private func schema(for tool: CodexReviewMCP.Tool.Name) -> Value {
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
            "properties": .object([
                "sessionID": .object(["type": .string("string")]),
                "jobID": .object(["type": .string("string")]),
                "jobId": .object(["type": .string("string")]),
            ]),
            "anyOf": .array([
                .object(["required": .array([.string("jobId")])]),
                .object(["required": .array([.string("jobID")])]),
            ]),
        ])
    case .reviewRead:
        .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object(["type": .string("string")]),
                "jobID": .object(["type": .string("string")]),
                "jobId": .object(["type": .string("string")]),
                "logOffset": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                ]),
                "logLimit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(CodexReviewAPI.Log.PageRequest.maxLimit),
                ]),
                "logFilter": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string(CodexReviewAPI.Log.Filter.defaultSetting.rawValue),
                        .string(CodexReviewAPI.Log.Filter.all.rawValue),
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
            sessionID: sessionID(in: arguments, defaultSessionID: defaultSessionID) ?? "default",
            request: .init(cwd: cwd, target: target),
            waitTimeout: useBoundedReviewStart ? boundedReviewWaitDuration : nil
        )
    case .reviewAwait:
        return .reviewAwait(
            sessionID: sessionID(in: arguments, defaultSessionID: defaultSessionID),
            jobID: try requiredJobID(in: arguments),
            waitTimeout: boundedReviewWaitDuration
        )
    case .reviewRead:
        return .reviewRead(
            sessionID: sessionID(in: arguments, defaultSessionID: defaultSessionID),
            jobID: try requiredJobID(in: arguments),
            logFilter: try reviewLogFilter(in: arguments),
            logPage: try reviewLogPageRequest(in: arguments)
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

private func toolResult(tool: CodexReviewMCP.Tool.Name, response: CodexReviewMCP.Tool.Response) throws -> CallTool.Result {
    let value: Value
    let text: String
    let isError: Bool
    switch response {
    case .reviewRead(let result, let timeline):
        value = tool == .reviewRead
            ? result.structuredContentForRead(timeline: timeline)
            : result.structuredContentForStartOrAwait(timeline: timeline)
        text = tool == .reviewRead
            ? result.textContentForRead()
            : result.textContentForStartOrAwait()
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

private func reviewLogFilter(in arguments: [String: Value]) throws -> CodexReviewAPI.Log.Filter {
    guard let rawValue = arguments["logFilter"]?.stringValue?.nilIfEmpty else {
        return .defaultSetting
    }
    guard let filter = CodexReviewAPI.Log.Filter(rawValue: rawValue) else {
        throw MCPProtocolServerError.invalidArgument(
            "Unsupported logFilter: \(rawValue). Use `default` or `all`."
        )
    }
    return filter
}

private func reviewLogPageRequest(in arguments: [String: Value]) throws -> CodexReviewAPI.Log.PageRequest {
    let offset: Int?
    if let value = arguments["logOffset"] {
        guard let parsed = value.intValue else {
            throw MCPProtocolServerError.invalidArgument("logOffset must be an integer.")
        }
        guard parsed >= 0 else {
            throw MCPProtocolServerError.invalidArgument("logOffset must be greater than or equal to 0.")
        }
        offset = parsed
    } else {
        offset = nil
    }

    let limit: Int
    if let value = arguments["logLimit"] {
        guard let parsed = value.intValue else {
            throw MCPProtocolServerError.invalidArgument("logLimit must be an integer.")
        }
        guard (1...CodexReviewAPI.Log.PageRequest.maxLimit).contains(parsed) else {
            throw MCPProtocolServerError.invalidArgument(
                "logLimit must be between 1 and \(CodexReviewAPI.Log.PageRequest.maxLimit)."
            )
        }
        limit = parsed
    } else {
        limit = CodexReviewAPI.Log.PageRequest.defaultLimit
    }

    return CodexReviewAPI.Log.PageRequest(offset: offset, limit: limit)
}

private func reviewTarget(from object: [String: Value]) throws -> CodexReviewAPI.Target {
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

        Use `review_start` to run a review, `review_await` to continue waiting for long-running jobs, then `review_read`, `review_list`, or `review_cancel` to inspect or control review jobs.
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
        uri: "codex-review://help/tools/review_await",
        name: "review_await",
        description: "Wait for a running Codex review job.",
        content: """
        # review_await

        Required argument: `jobId`.

        Use this after `review_start` returns a running job. The tool waits for the job to finish and returns the final review when available.
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

private extension CodexReviewAPI.Read.Result {
    func textContent() -> String {
        core.reviewText.nilIfEmpty ?? core.lifecycle.status.rawValue
    }

    func textContentForStartOrAwait() -> String {
        if core.lifecycle.status.isTerminal {
            return textContent()
        }

        var status = "Review \(core.lifecycle.status.rawValue)"
        if let elapsedSeconds {
            status += " for \(elapsedSeconds)s"
        }
        return "\(status). jobId: \(jobID). Call `review_await` with this jobId to continue waiting."
    }

    func textContentForRead() -> String {
        if core.lifecycle.status.isTerminal {
            return textContent()
        }

        var parts: [String] = []
        var status = "Review \(core.lifecycle.status.rawValue)"
        if let elapsedSeconds {
            status += " for \(elapsedSeconds)s"
        }
        parts.append(status + ".")
        parts.append("Returned logs \(logsPage.rangeDescription) of \(logsPage.total).")
        if let latest = logs.last(where: { $0.text.nilIfEmpty != nil }) {
            parts.append("Latest: \(Self.truncatedLatestText(latest.text))")
        }
        return parts.joined(separator: " ")
    }

    private static func truncatedLatestText(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: " ")
        let limit = 300
        guard normalized.count > limit else {
            return normalized
        }
        let index = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<index]) + "..."
    }

    func structuredContentForStartOrAwait(timeline: ReviewMCPProjection) -> Value {
        structuredContent(
            includeDetails: false,
            includeNextAction: core.lifecycle.status.isTerminal == false,
            timeline: timeline
        )
    }

    func structuredContentForRead(timeline: ReviewMCPProjection) -> Value {
        structuredContent(includeDetails: true, includeNextAction: false, timeline: timeline)
    }

    func structuredContent(
        includeDetails: Bool,
        includeNextAction: Bool,
        timeline: ReviewMCPProjection
    ) -> Value {
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
            object["logsPage"] = logsPage.structuredContent()
            object["rawLogText"] = .string(rawLogText)
        }
        object["timeline"] = timeline.structuredContent()
        if includeNextAction {
            object["nextAction"] = .object([
                "tool": .string(CodexReviewMCP.Tool.Name.reviewAwait.rawValue),
                "jobId": .string(jobID),
            ])
        }
        return .object(object)
    }
}

private extension ReviewMCPProjection {
    func structuredContent() -> Value {
        .object([
            "revision": timelineRevision.rawValue.structuredRevisionValue(),
            "orderedItemIds": .array(orderedItemIDs.map { .string($0.rawValue) }),
            "activeItemIds": .array(activeItemIDs.map { .string($0.rawValue) }),
            "activeItemCount": .int(activeItemCount),
            "latestActivityId": latestActivityID.map { .string($0.rawValue) } ?? .null,
            "terminalSummary": terminalSummary.map(Value.string) ?? .null,
            "terminalResult": terminalResult.map(Value.string) ?? .null,
            "items": .array(items.map { $0.structuredContent() }),
        ])
    }
}

private extension ReviewMCPProjection.Item {
    func structuredContent() -> Value {
        .object([
            "id": .string(id.rawValue),
            "kind": .string(kind.rawValue),
            "family": .string(family.rawValue),
            "phase": .string(phase.rawValue),
            "isActive": .bool(isActive),
            "content": content.structuredContent(),
            "createdAt": .string(createdAt.ISO8601Format()),
            "updatedAt": .string(updatedAt.ISO8601Format()),
            "startedAt": startedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "completedAt": completedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "durationMs": durationMs.map(Value.int) ?? .null,
        ])
    }
}

private extension ReviewMCPProjection.Content {
    func structuredContent() -> Value {
        switch self {
        case .approval(let approval):
            return .object([
                "type": .string("approval"),
                "title": .string(approval.title),
                "detail": approval.detail.map(Value.string) ?? .null,
            ])
        case .command(let command):
            return .object([
                "type": .string("command"),
                "command": .string(command.command),
                "cwd": command.cwd.map(Value.string) ?? .null,
                "output": .string(command.output),
                "exitCode": command.exitCode.map(Value.int) ?? .null,
            ])
        case .contextCompaction(let contextCompaction):
            return .object([
                "type": .string("contextCompaction"),
                "title": .string(contextCompaction.title),
            ])
        case .diagnostic(let diagnostic):
            return .object([
                "type": .string("diagnostic"),
                "message": .string(diagnostic.message),
            ])
        case .fileChange(let fileChange):
            return .object([
                "type": .string("fileChange"),
                "title": .string(fileChange.title),
                "output": .string(fileChange.output),
            ])
        case .message(let message):
            return .object([
                "type": .string("message"),
                "text": .string(message.text),
            ])
        case .plan(let plan):
            return .object([
                "type": .string("plan"),
                "markdown": .string(plan.markdown),
            ])
        case .reasoning(let reasoning):
            return .object([
                "type": .string("reasoning"),
                "text": .string(reasoning.text),
                "style": .string(reasoning.style.rawValue),
            ])
        case .search(let search):
            return .object([
                "type": .string("search"),
                "query": .string(search.query),
                "result": search.result.map(Value.string) ?? .null,
            ])
        case .toolCall(let toolCall):
            return .object([
                "type": .string("toolCall"),
                "namespace": toolCall.namespace.map(Value.string) ?? .null,
                "server": toolCall.server.map(Value.string) ?? .null,
                "tool": toolCall.tool.map(Value.string) ?? .null,
                "arguments": toolCall.arguments.map(Value.string) ?? .null,
                "result": toolCall.result.map(Value.string) ?? .null,
                "error": toolCall.error.map(Value.string) ?? .null,
            ])
        case .unknown(let unknown):
            return .object([
                "type": .string("unknown"),
                "title": .string(unknown.title),
                "detail": unknown.detail.map(Value.string) ?? .null,
            ])
        }
    }
}

private extension UInt64 {
    func structuredRevisionValue() -> Value {
        if self <= UInt64(Int.max) {
            return .int(Int(self))
        }
        return .string(String(self))
    }
}

private extension CodexReviewAPI.Log.Page {
    var rangeDescription: String {
        guard returned > 0 else {
            return "0"
        }
        return "\(offset + 1)-\(offset + returned)"
    }

    func structuredContent() -> Value {
        .object([
            "total": .int(total),
            "offset": .int(offset),
            "limit": .int(limit),
            "returned": .int(returned),
            "hasMoreBefore": .bool(hasMoreBefore),
            "hasMoreAfter": .bool(hasMoreAfter),
            "previousOffset": previousOffset.map(Value.int) ?? .null,
            "nextOffset": nextOffset.map(Value.int) ?? .null,
        ])
    }
}

private extension CodexReviewAPI.Job.ListItem {
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

private extension CodexReviewAPI.List.Result {
    func structuredContent() -> Value {
        .object([
            "items": .array(items.map { $0.structuredContent() }),
        ])
    }
}

private extension CodexReviewAPI.Cancel.Outcome {
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

private extension ReviewJobCore.Run {
    func structuredContent() -> Value {
        .object([
            "reviewThreadId": reviewThreadID.map(Value.string) ?? .null,
            "threadId": threadID.map(Value.string) ?? .null,
            "turnId": turnID.map(Value.string) ?? .null,
            "model": model.map(Value.string) ?? .null,
        ])
    }
}

private extension ReviewJobCore.Lifecycle {
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

private extension ReviewJobCore.Output {
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

private extension ParsedReviewResult.Finding {
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

private extension ParsedReviewResult.Finding.Location {
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
