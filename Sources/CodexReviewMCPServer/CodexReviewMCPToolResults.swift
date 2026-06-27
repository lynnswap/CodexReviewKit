import Foundation
import MCP
import CodexReviewKit

func toolResult(response: CodexReviewMCP.Tool.Response) throws -> CallTool.Result {
    let value: Value
    let text: String
    let isError: Bool
    switch response {
    case .reviewStart(let snapshot),
        .reviewAwait(let snapshot):
        value = snapshot.result.structuredContentForStartOrAwait(timeline: snapshot.timeline)
        text = snapshot.result.textContentForStartOrAwait()
        isError = snapshot.result.core.lifecycle.status == .failed
    case .reviewRead(let snapshot):
        value = snapshot.result.structuredContentForRead(timeline: snapshot.timeline)
        text = snapshot.result.textContentForRead()
        isError = snapshot.result.core.lifecycle.status == .failed
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

        var status = "Review \(core.lifecycle.status.rawValue)"
        if let elapsedSeconds {
            status += " for \(elapsedSeconds)s"
        }
        return "\(status)."
    }

    func structuredContentForStartOrAwait(timeline: ReviewMCPProjection) -> Value {
        structuredContent(
            includeDetails: false,
            includeNextAction: core.lifecycle.status.isTerminal == false,
            timeline: timeline
        )
    }

    func structuredContentForRead(timeline: ReviewMCPProjection) -> Value {
        structuredContent(
            includeDetails: true,
            includeNextAction: false,
            timeline: timeline
        )
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
        object["timeline"] =
            includeDetails
            ? timeline.structuredContentWithItems()
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

    func structuredContentWithItems() -> Value {
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
        let page = TimelineItemPage(
            total: items.count,
            offset: 0,
            limit: items.count,
            returned: items.count,
            hasMoreBefore: false,
            hasMoreAfter: false,
            previousOffset: nil,
            nextOffset: nil
        )
        object["items"] = .array(items.map { $0.structuredContent() })
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
            "items": .array(items.map { $0.structuredContent() })
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
