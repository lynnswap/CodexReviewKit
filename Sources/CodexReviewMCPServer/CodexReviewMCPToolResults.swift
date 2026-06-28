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
        value = snapshot.result.structuredContentForStartOrAwait(log: snapshot.log)
        text = snapshot.result.textContentForStartOrAwait(log: snapshot.log)
        isError = snapshot.result.core.lifecycle.status == .failed
    case .reviewRead(let snapshot):
        value = snapshot.result.structuredContentForRead(log: snapshot.log)
        text = snapshot.result.textContentForRead(log: snapshot.log)
        isError = snapshot.result.core.lifecycle.status == .failed
    case .reviewList(let result):
        value = result.structuredContent()
        text = "Listed \(result.items.count) review run(s)."
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
    func textContent(log: ReviewMCPLogProjection) -> String {
        log.finalResult?.nilIfEmpty ?? core.reviewText.nilIfEmpty ?? core.lifecycle.status.rawValue
    }

    func textContentForStartOrAwait(log: ReviewMCPLogProjection) -> String {
        if core.lifecycle.status.isTerminal {
            return textContent(log: log)
        }

        var status = "Review \(core.lifecycle.status.rawValue)"
        if let elapsedSeconds {
            status += " for \(elapsedSeconds)s"
        }
        return "\(status). runId: \(runID). Call `review_await` with this runId to continue waiting."
    }

    func textContentForRead(log: ReviewMCPLogProjection) -> String {
        if core.lifecycle.status.isTerminal {
            return textContent(log: log)
        }

        var status = "Review \(core.lifecycle.status.rawValue)"
        if let elapsedSeconds {
            status += " for \(elapsedSeconds)s"
        }
        return "\(status)."
    }

    func structuredContentForStartOrAwait(log: ReviewMCPLogProjection) -> Value {
        structuredContent(
            includeDetails: false,
            includeNextAction: core.lifecycle.status.isTerminal == false,
            log: log
        )
    }

    func structuredContentForRead(log: ReviewMCPLogProjection) -> Value {
        structuredContent(
            includeDetails: true,
            includeNextAction: false,
            log: log
        )
    }

    func structuredContent(
        includeDetails: Bool,
        includeNextAction: Bool,
        log: ReviewMCPLogProjection
    ) -> Value {
        var object: [String: Value] = [
            "runId": .string(runID),
            "run": core.run.structuredContent(),
            "lifecycle": core.lifecycle.structuredContent(
                elapsedSeconds: elapsedSeconds,
                cancellable: cancellable
            ),
            "output": core.output.structuredContent(
                review: log.finalResult?.nilIfEmpty ?? core.reviewText,
                finalReview: log.finalResult?.nilIfEmpty
            ),
        ]
        object["log"] =
            includeDetails
            ? log.structuredContentWithItems()
            : log.structuredContent()
        if includeNextAction {
            object["nextAction"] = .object([
                "tool": .string(CodexReviewMCP.Tool.Name.reviewAwait.rawValue),
                "runId": .string(runID),
            ])
        }
        return .object(object)
    }
}

private extension ReviewMCPLogProjection {
    func structuredContent() -> Value {
        var truncatedFields: [String] = []
        var object: [String: Value] = [
            "revision": .string(revision),
            "orderedEntryIds": .array(orderedEntryIDs.map(Value.string)),
            "activeEntryIds": .array(activeEntryIDs.map(Value.string)),
            "activeEntryCount": .int(activeEntryCount),
            "latestEntryId": latestEntryID.map(Value.string) ?? .null,
            "finalSummary": boundedLogString(
                finalSummary,
                field: "finalSummary",
                truncatedFields: &truncatedFields
            ),
            "finalResult": boundedLogString(
                finalResult,
                field: "finalResult",
                truncatedFields: &truncatedFields
            ),
        ]
        let page = LogEntryPage.unreturned(total: items.count)
        object["items"] = .array([])
        object["itemsPage"] = page.structuredContent()
        object["truncatedFields"] = .array(truncatedFields.map(Value.string))
        return .object(object)
    }

    func structuredContentWithItems() -> Value {
        var truncatedFields: [String] = []
        var object: [String: Value] = [
            "revision": .string(revision),
            "orderedEntryIds": .array(orderedEntryIDs.map(Value.string)),
            "activeEntryIds": .array(activeEntryIDs.map(Value.string)),
            "activeEntryCount": .int(activeEntryCount),
            "latestEntryId": latestEntryID.map(Value.string) ?? .null,
            "finalSummary": boundedLogString(
                finalSummary,
                field: "finalSummary",
                truncatedFields: &truncatedFields
            ),
            "finalResult": boundedLogString(
                finalResult,
                field: "finalResult",
                truncatedFields: &truncatedFields
            ),
        ]
        let page = LogEntryPage(
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

private extension ReviewMCPLogProjection.Item {
    func structuredContent() -> Value {
        .object([
            "id": .string(id),
            "kind": .string(kind),
            "content": content.structuredContent(),
        ])
    }
}

private extension ReviewMCPLogProjection.Content {
    func structuredContent() -> Value {
        switch self {
        case .diagnostic(let message):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("diagnostic"),
                "message": boundedLogString(
                    message,
                    field: "message",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .message(let text):
            var truncatedFields: [String] = []
            return .object([
                "type": .string("message"),
                "text": boundedLogString(
                    text,
                    field: "text",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        case .entry(let type, let text):
            var truncatedFields: [String] = []
            return .object([
                "type": .string(type),
                "text": boundedLogString(
                    text,
                    field: "text",
                    truncatedFields: &truncatedFields
                ),
                "truncatedFields": .array(truncatedFields.map(Value.string)),
            ])
        }
    }
}

private struct LogEntryPage {
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

    static func unreturned(total: Int) -> LogEntryPage {
        LogEntryPage(
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

private func boundedLogString(
    _ value: String?,
    field: String,
    truncatedFields: inout [String]
) -> Value {
    guard let value else {
        return .null
    }
    return boundedLogString(value, field: field, truncatedFields: &truncatedFields)
}

private func boundedLogString(
    _ value: String,
    field: String,
    truncatedFields: inout [String]
) -> Value {
    let bounded = value.boundedLogString()
    if bounded.wasTruncated {
        truncatedFields.append(field)
    }
    return .string(bounded.value)
}

private extension String {
    func boundedLogString() -> (value: String, wasTruncated: Bool) {
        let limit = 4096
        guard count > limit else {
            return (self, false)
        }
        let end = index(startIndex, offsetBy: limit)
        return (String(self[..<end]) + "...", true)
    }
}

private extension CodexReviewAPI.Run.ListItem {
    func structuredContent() -> Value {
        .object([
            "runId": .string(runID),
            "cwd": .string(cwd),
            "targetSummary": .string(targetSummary),
            "run": core.run.structuredContent(),
            "lifecycle": core.lifecycle.structuredContent(
                elapsedSeconds: elapsedSeconds,
                cancellable: cancellable
            ),
            "output": core.output.structuredContent(
                review: core.reviewText,
                finalReview: core.finalReviewText
            ),
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
            "runId": .string(runID),
            "cancelled": .bool(cancelled),
            "run": core.run.structuredContent(),
            "lifecycle": core.lifecycle.structuredContent(
                elapsedSeconds: nil,
                cancellable: false
            ),
            "output": core.output.structuredContent(
                review: core.reviewText,
                finalReview: core.finalReviewText
            ),
        ])
    }
}

private extension ReviewRunCore.Run {
    func structuredContent() -> Value {
        .object([
            "reviewThreadId": reviewThreadID.map(Value.string) ?? .null,
            "threadId": threadID.map(Value.string) ?? .null,
            "turnId": turnID.map(Value.string) ?? .null,
            "model": model.map(Value.string) ?? .null,
        ])
    }
}

private extension ReviewRunCore.Lifecycle {
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

private extension ReviewRunCore {
    var finalReviewText: String? {
        guard lifecycle.status == .succeeded else {
            return nil
        }
        return reviewText.nilIfEmpty
    }
}

private extension ReviewRunCore.Output {
    func structuredContent(review: String, finalReview: String?) -> Value {
        let finalReview = finalReview?.nilIfEmpty
        return .object([
            "summary": .string(summary),
            "review": .string(review),
            "hasFinalReview": .bool(finalReview != nil),
            "lastAgentMessage": finalReview.map(Value.string) ?? .null,
            "reviewResult": ParsedReviewResult.parse(finalReviewText: finalReview).structuredContent(),
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
