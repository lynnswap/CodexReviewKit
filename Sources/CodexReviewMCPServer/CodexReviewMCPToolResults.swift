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
        log.finalResult?.nilIfEmpty ?? core.finalReview ?? core.displayLifecycleMessage
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
            includeLog: true,
            includeDetails: false,
            includeNextAction: core.lifecycle.status.isTerminal == false,
            log: log
        )
    }

    func structuredContentForRead(log: ReviewMCPLogProjection) -> Value {
        structuredContent(
            includeLog: true,
            includeDetails: true,
            includeNextAction: false,
            log: log
        )
    }

    func structuredContent(
        includeLog: Bool,
        includeDetails: Bool,
        includeNextAction: Bool,
        log: ReviewMCPLogProjection
    ) -> Value {
        var object: [String: Value] = [
            "runId": .string(runID),
            "run": core.run.structuredContent(),
            "lifecycle": core.structuredLifecycleContent(
                elapsedSeconds: elapsedSeconds,
                cancellable: cancellable
            ),
            "review": core.structuredReviewContent(
                resolvedFinalReview: log.finalResult?.nilIfEmpty ?? core.finalReview
            ),
        ]
        if includeLog {
            object["log"] =
                includeDetails
                ? log.structuredContentWithItems()
                : log.structuredContent()
        }
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
        let orderedEntryIDs = Array(self.orderedEntryIDs.suffix(Self.compactEntryIDLimit))
        let activeEntryIDs = Array(self.activeEntryIDs.suffix(Self.compactEntryIDLimit))
        if orderedEntryIDs.count < self.orderedEntryIDs.count {
            truncatedFields.append("orderedEntryIds")
        }
        if activeEntryIDs.count < self.activeEntryIDs.count {
            truncatedFields.append("activeEntryIds")
        }
        var object: [String: Value] = [
            "revision": .string(revision),
            "orderedEntryIds": .array(orderedEntryIDs.map(Value.string)),
            "activeEntryIds": .array(activeEntryIDs.map(Value.string)),
            "activeEntryCount": .int(activeEntryCount),
            "latestEntryId": latestEntryID.map(Value.string) ?? .null,
            "finalLifecycleMessage": boundedLogString(
                finalLifecycleMessage,
                field: "finalLifecycleMessage",
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
        // Long reviews can accumulate huge transcripts; detailed reads return
        // a bounded tail page so MCP responses stay small, with the page
        // metadata pointing at the omitted head. The entry id arrays are
        // bounded to the same window so no field scales with the full
        // transcript.
        let limit = Self.detailedItemsLimit
        let total = items.count
        let pageItems = Array(items.suffix(limit))
        let returned = pageItems.count
        let offset = total - returned
        let pageItemIDs = Set(pageItems.map(\.id))
        let page = LogEntryPage(
            total: total,
            offset: offset,
            limit: limit,
            returned: returned,
            hasMoreBefore: offset > 0,
            hasMoreAfter: false,
            previousOffset: offset > 0 ? max(0, offset - limit) : nil,
            nextOffset: nil
        )
        var truncatedFields: [String] = []
        var object: [String: Value] = [
            "revision": .string(revision),
            "orderedEntryIds": .array(
                orderedEntryIDs.filter(pageItemIDs.contains).map(Value.string)
            ),
            "activeEntryIds": .array(
                activeEntryIDs.filter(pageItemIDs.contains).map(Value.string)
            ),
            "activeEntryCount": .int(activeEntryCount),
            "latestEntryId": latestEntryID.map(Value.string) ?? .null,
            "finalLifecycleMessage": boundedLogString(
                finalLifecycleMessage,
                field: "finalLifecycleMessage",
                truncatedFields: &truncatedFields
            ),
            "finalResult": boundedLogString(
                finalResult,
                field: "finalResult",
                truncatedFields: &truncatedFields
            ),
        ]
        object["items"] = .array(pageItems.map { $0.structuredContent() })
        object["itemsPage"] = page.structuredContent()
        object["truncatedFields"] = .array(truncatedFields.map(Value.string))
        return .object(object)
    }

    private static var compactEntryIDLimit: Int { 100 }
    private static var detailedItemsLimit: Int { 100 }
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
            "lifecycle": core.structuredLifecycleContent(
                elapsedSeconds: elapsedSeconds,
                cancellable: cancellable
            ),
            "review": core.structuredReviewContent(),
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
            "lifecycle": core.structuredLifecycleContent(
                elapsedSeconds: nil,
                cancellable: false
            ),
            "review": core.structuredReviewContent(),
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
        cancellable: Bool,
        message: String
    ) -> Value {
        .object([
            "status": .string(status.rawValue),
            "message": .string(message),
            "exitCode": exitCode.map(Value.int) ?? .null,
            "startedAt": startedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "endedAt": endedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "elapsedSeconds": elapsedSeconds.map(Value.int) ?? .null,
            "cancellable": .bool(cancellable),
            "cancellation": cancellation.map { $0.structuredContent() } ?? .null,
            "errorMessage": errorMessage.map(Value.string) ?? .null,
            "failure": failure.map { $0.structuredContent() } ?? .null,
        ])
    }
}

private extension ReviewBackendFailure {
    func structuredContent() -> Value {
        var object: [String: Value] = [
            "message": .string(message),
        ]
        switch self {
        case .message:
            object["kind"] = .string("message")
        case .missingReviewOutput(let turnID):
            object["kind"] = .string("missingReviewOutput")
            object["turnId"] = .string(turnID)
        case .invalidTerminalStatus(let rawStatus, let turnID, let turnFailure):
            object["kind"] = .string("invalidTerminalStatus")
            object["rawStatus"] = .string(rawStatus)
            object["turnId"] = .string(turnID)
            object["turnFailure"] = turnFailure.map { $0.structuredContent() } ?? .null
        case .turnFailed(let turnFailure):
            object["kind"] = .string("turnFailed")
            object["turnFailure"] = turnFailure.structuredContent()
        case .interruptedByBackend(let backendMessage):
            object["kind"] = .string("interruptedByBackend")
            object["backendMessage"] = backendMessage.map(Value.string) ?? .null
        }
        return .object(object)
    }
}

private extension ReviewTurnFailure {
    func structuredContent() -> Value {
        .object([
            "message": .string(message),
            "code": code.map { $0.structuredContent() } ?? .null,
            "additionalDetails": additionalDetails.map(Value.string) ?? .null,
        ])
    }
}

private extension ReviewTurnFailure.Code {
    func structuredContent() -> Value {
        var object: [String: Value] = [:]
        switch self {
        case .contextWindowExceeded:
            object["name"] = .string("contextWindowExceeded")
        case .sessionBudgetExceeded:
            object["name"] = .string("sessionBudgetExceeded")
        case .usageLimitExceeded:
            object["name"] = .string("usageLimitExceeded")
        case .serverOverloaded:
            object["name"] = .string("serverOverloaded")
        case .cyberPolicy:
            object["name"] = .string("cyberPolicy")
        case .httpConnectionFailed(let status):
            object["name"] = .string("httpConnectionFailed")
            object["status"] = status.map { .int(Int($0)) } ?? .null
        case .responseStreamConnectionFailed(let status):
            object["name"] = .string("responseStreamConnectionFailed")
            object["status"] = status.map { .int(Int($0)) } ?? .null
        case .internalServerError:
            object["name"] = .string("internalServerError")
        case .unauthorized:
            object["name"] = .string("unauthorized")
        case .badRequest:
            object["name"] = .string("badRequest")
        case .threadRollbackFailed:
            object["name"] = .string("threadRollbackFailed")
        case .sandboxError:
            object["name"] = .string("sandboxError")
        case .responseStreamDisconnected(let status):
            object["name"] = .string("responseStreamDisconnected")
            object["status"] = status.map { .int(Int($0)) } ?? .null
        case .responseTooManyFailedAttempts(let status):
            object["name"] = .string("responseTooManyFailedAttempts")
            object["status"] = status.map { .int(Int($0)) } ?? .null
        case .activeTurnNotSteerable(let kind):
            object["name"] = .string("activeTurnNotSteerable")
            object["kind"] = .string(kind)
        case .other:
            object["name"] = .string("other")
        case .unknown(let rawValue):
            object["name"] = .string("unknown")
            object["rawValue"] = .string(rawValue)
        }
        return .object(object)
    }
}

private extension ReviewRunCore {
    var displayLifecycleMessage: String {
        lifecycle.errorMessage?.nilIfEmpty ?? lifecycleMessage.nilIfEmpty ?? lifecycle.status.rawValue
    }

    func structuredLifecycleContent(
        elapsedSeconds: Int?,
        cancellable: Bool
    ) -> Value {
        lifecycle.structuredContent(
            elapsedSeconds: elapsedSeconds,
            cancellable: cancellable,
            message: displayLifecycleMessage
        )
    }

    // The run record is not the transcript's source of truth; read paths that
    // hold a log projection pass the resolved final review so structured
    // fields match the text content.
    func structuredReviewContent(resolvedFinalReview: String? = nil) -> Value {
        let finalReview = (resolvedFinalReview ?? self.finalReview)?.nilIfEmpty
        return .object([
            "hasFinalReview": .bool(finalReview != nil),
            "finalReview": finalReview.map(Value.string) ?? .null,
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
