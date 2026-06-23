import Foundation
import MCP
import CodexReview
import CodexReviewMCPAdapter

func toolResult(response: CodexReviewMCP.Tool.Response) throws -> CallTool.Result {
    let value: Value
    let text: String
    let isError: Bool
    switch response {
    case .reviewStart(let result, let timeline),
         .reviewAwait(let result, let timeline):
        value = result.structuredContentForStartOrAwait(timeline: timeline)
        text = result.textContentForStartOrAwait()
        isError = result.core.lifecycle.status == .failed
    case .reviewRead(let result, let timeline, let timelinePage):
        value = result.structuredContentForRead(timeline: timeline, timelinePage: timelinePage)
        text = result.textContentForRead()
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

    func structuredContentForRead(
        timeline: ReviewMCPProjection,
        timelinePage: CodexReviewAPI.Log.PageRequest?
    ) -> Value {
        structuredContent(
            includeDetails: true,
            includeNextAction: false,
            timeline: timeline,
            timelinePage: timelinePage ?? .default
        )
    }

    func structuredContent(
        includeDetails: Bool,
        includeNextAction: Bool,
        timeline: ReviewMCPProjection,
        timelinePage: CodexReviewAPI.Log.PageRequest? = nil
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
        object["timeline"] = includeDetails
            ? timeline.structuredContent(pageRequest: timelinePage ?? .default)
            : timeline.structuredContent()
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
        var truncatedFields: [String] = []
        var object: [String: Value] = [
            "revision": timelineRevision.rawValue.structuredRevisionValue(),
            "orderedItemIds": .array(orderedItemIDs.map { .string($0.rawValue) }),
            "activeItemIds": .array(activeItemIDs.map { .string($0.rawValue) }),
            "activeItemCount": .int(activeItemCount),
            "latestActivityId": latestActivityID.map { .string($0.rawValue) } ?? .null,
            "terminalSummary": boundedTimelineString(
                terminalSummary,
                field: "terminalSummary",
                truncatedFields: &truncatedFields
            ),
            "terminalResult": boundedTimelineString(
                terminalResult,
                field: "terminalResult",
                truncatedFields: &truncatedFields
            ),
        ]
        let page = TimelineItemPage.unreturned(total: items.count)
        object["items"] = .array([])
        object["itemsPage"] = page.structuredContent()
        object["truncatedFields"] = .array(truncatedFields.map(Value.string))
        return .object(object)
    }

    func structuredContent(pageRequest: CodexReviewAPI.Log.PageRequest) -> Value {
        var truncatedFields: [String] = []
        var object: [String: Value] = [
            "revision": timelineRevision.rawValue.structuredRevisionValue(),
            "orderedItemIds": .array(orderedItemIDs.map { .string($0.rawValue) }),
            "activeItemIds": .array(activeItemIDs.map { .string($0.rawValue) }),
            "activeItemCount": .int(activeItemCount),
            "latestActivityId": latestActivityID.map { .string($0.rawValue) } ?? .null,
            "terminalSummary": boundedTimelineString(
                terminalSummary,
                field: "terminalSummary",
                truncatedFields: &truncatedFields
            ),
            "terminalResult": boundedTimelineString(
                terminalResult,
                field: "terminalResult",
                truncatedFields: &truncatedFields
            ),
        ]
        let page = TimelineItemPage(pageRequest: pageRequest, total: items.count)
        object["items"] = .array(items[page.range].map { $0.structuredContent() })
        object["itemsPage"] = page.structuredContent()
        object["truncatedFields"] = .array(truncatedFields.map(Value.string))
        return .object(object)
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
            var truncatedFields: [String] = []
            return .object([
                "type": .string("approval"),
                "title": boundedTimelineString(
                    approval.title,
                    field: "title",
                    truncatedFields: &truncatedFields
                ),
                "detail": boundedTimelineString(
                    approval.detail,
                    field: "detail",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .command(let command):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("command"),
                "command": boundedTimelineString(
                    command.command,
                    field: "command",
                    truncatedFields: &truncatedFields
                ),
                "cwd": boundedTimelineString(
                    command.cwd,
                    field: "cwd",
                    truncatedFields: &truncatedFields
                ),
                "output": boundedTimelineString(
                    command.output,
                    field: "output",
                    truncatedFields: &truncatedFields
                ),
                "exitCode": command.exitCode.map(Value.int) ?? .null,
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .contextCompaction(let contextCompaction):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("contextCompaction"),
                "title": boundedTimelineString(
                    contextCompaction.title,
                    field: "title",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .diagnostic(let diagnostic):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("diagnostic"),
                "message": boundedTimelineString(
                    diagnostic.message,
                    field: "message",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .fileChange(let fileChange):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("fileChange"),
                "title": boundedTimelineString(
                    fileChange.title,
                    field: "title",
                    truncatedFields: &truncatedFields
                ),
                "output": boundedTimelineString(
                    fileChange.output,
                    field: "output",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .message(let message):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("message"),
                "text": boundedTimelineString(
                    message.text,
                    field: "text",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .plan(let plan):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("plan"),
                "markdown": boundedTimelineString(
                    plan.markdown,
                    field: "markdown",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .reasoning(let reasoning):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("reasoning"),
                "text": boundedTimelineString(
                    reasoning.text,
                    field: "text",
                    truncatedFields: &truncatedFields
                ),
                "style": .string(reasoning.style.rawValue),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .search(let search):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("search"),
                "query": boundedTimelineString(
                    search.query,
                    field: "query",
                    truncatedFields: &truncatedFields
                ),
                "result": boundedTimelineString(
                    search.result,
                    field: "result",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .toolCall(let toolCall):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("toolCall"),
                "namespace": boundedTimelineString(
                    toolCall.namespace,
                    field: "namespace",
                    truncatedFields: &truncatedFields
                ),
                "server": boundedTimelineString(
                    toolCall.server,
                    field: "server",
                    truncatedFields: &truncatedFields
                ),
                "tool": boundedTimelineString(
                    toolCall.tool,
                    field: "tool",
                    truncatedFields: &truncatedFields
                ),
                "arguments": boundedTimelineString(
                    toolCall.arguments,
                    field: "arguments",
                    truncatedFields: &truncatedFields
                ),
                "progress": boundedTimelineString(
                    toolCall.progress,
                    field: "progress",
                    truncatedFields: &truncatedFields
                ),
                "result": boundedTimelineString(
                    toolCall.result,
                    field: "result",
                    truncatedFields: &truncatedFields
                ),
                "error": boundedTimelineString(
                    toolCall.error,
                    field: "error",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .unknown(let unknown):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("unknown"),
                "title": boundedTimelineString(
                    unknown.title,
                    field: "title",
                    truncatedFields: &truncatedFields
                ),
                "detail": boundedTimelineString(
                    unknown.detail,
                    field: "detail",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        }
    }
}

private struct TimelineItemPage {
    var total: Int
    var offset: Int
    var limit: Int
    var returned: Int
    var hasMoreBefore: Bool
    var hasMoreAfter: Bool
    var previousOffset: Int?
    var nextOffset: Int?

    var range: Range<Int> {
        offset..<offset + returned
    }

    init(
        total: Int,
        offset: Int,
        limit: Int,
        returned: Int,
        hasMoreBefore: Bool,
        hasMoreAfter: Bool,
        previousOffset: Int?,
        nextOffset: Int?
    ) {
        self.total = total
        self.offset = offset
        self.limit = limit
        self.returned = returned
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.previousOffset = previousOffset
        self.nextOffset = nextOffset
    }

    static func unreturned(total: Int) -> TimelineItemPage {
        TimelineItemPage(
            total: total,
            offset: 0,
            limit: 0,
            returned: 0,
            hasMoreBefore: false,
            hasMoreAfter: total > 0,
            previousOffset: nil,
            nextOffset: total > 0 ? 0 : nil
        )
    }

    init(pageRequest: CodexReviewAPI.Log.PageRequest, total: Int) {
        let limit = pageRequest.limit
        let offset = min(pageRequest.offset ?? max(0, total - limit), total)
        let returned = min(limit, max(0, total - offset))
        self.total = total
        self.offset = offset
        self.limit = limit
        self.returned = returned
        self.hasMoreBefore = offset > 0
        self.hasMoreAfter = offset + returned < total
        self.previousOffset = hasMoreBefore ? max(0, offset - limit) : nil
        self.nextOffset = hasMoreAfter ? offset + returned : nil
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

private func boundedTimelineString(
    _ value: String?,
    field: String,
    truncatedFields: inout [String]
) -> Value {
    guard let value else {
        return .null
    }
    return boundedTimelineString(value, field: field, truncatedFields: &truncatedFields)
}

private func boundedTimelineString(
    _ value: String,
    field: String,
    truncatedFields: inout [String]
) -> Value {
    let bounded = value.boundedTimelineString()
    if bounded.wasTruncated {
        truncatedFields.append(field)
    }
    return .string(bounded.value)
}

private extension String {
    func boundedTimelineString() -> (value: String, wasTruncated: Bool) {
        let limit = 4096
        guard count > limit else {
            return (self, false)
        }
        let end = index(startIndex, offsetBy: limit)
        return (String(self[..<end]) + "...", true)
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
