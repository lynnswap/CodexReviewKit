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
        isError = snapshot.result.presentation.status == .failed
    case .reviewRead(let snapshot):
        value = snapshot.result.structuredContentForRead(log: snapshot.log)
        text = snapshot.result.textContentForRead(log: snapshot.log)
        isError = snapshot.result.presentation.status == .failed
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
        log.finalResult?.nilIfEmpty ?? presentation.lifecycle.message
    }

    func textContentForStartOrAwait(log: ReviewMCPLogProjection) -> String {
        if presentation.status.isTerminal {
            return textContent(log: log)
        }

        var status = "Review \(presentation.status.rawValue)"
        if let elapsedSeconds {
            status += " for \(elapsedSeconds)s"
        }
        return "\(status). runId: \(runID.rawValue). Call `review_await` with this runId to continue waiting."
    }

    func textContentForRead(log: ReviewMCPLogProjection) -> String {
        if presentation.status.isTerminal {
            return textContent(log: log)
        }

        var status = "Review \(presentation.status.rawValue)"
        if let elapsedSeconds {
            status += " for \(elapsedSeconds)s"
        }
        return "\(status)."
    }

    func structuredContentForStartOrAwait(log: ReviewMCPLogProjection) -> Value {
        structuredContent(
            includeDetailedLog: false,
            includeNextAction: presentation.status.isTerminal == false,
            log: log
        )
    }

    func structuredContentForRead(log: ReviewMCPLogProjection) -> Value {
        structuredContent(
            includeDetailedLog: true,
            includeNextAction: false,
            log: log
        )
    }

    func structuredContent(
        includeDetailedLog: Bool,
        includeNextAction: Bool,
        log: ReviewMCPLogProjection
    ) -> Value {
        var object: [String: Value] = [
            "runId": .string(runID.rawValue),
            "run": core.structuredRunContent(),
            "lifecycle": presentation.structuredLifecycleContent(
                core: core,
                elapsedSeconds: elapsedSeconds,
                cancellable: presentation.isCancellable
            ),
            "review": core.structuredReviewContent(
                resolvedFinalReview: log.finalResult
            ),
        ]
        if includeDetailedLog {
            object["log"] = log.structuredContentWithItems()
        }
        if includeNextAction {
            object["nextAction"] = .object([
                "tool": .string(CodexReviewMCP.Tool.Name.reviewAwait.rawValue),
                "runId": .string(runID.rawValue),
            ])
        }
        return .object(object)
    }
}

private extension ReviewMCPLogProjection {
    func structuredContentWithItems() -> Value {
        // Long reviews can accumulate huge transcripts; detailed reads return
        // a bounded tail page so MCP responses stay small, with the page
        // metadata pointing at the omitted head.
        let limit = Self.detailedItemsLimit
        let total = items.count
        let pageItems = Array(items.suffix(limit))
        let returned = pageItems.count
        let offset = total - returned
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
        return .object([
            "items": .array(pageItems.map { $0.structuredContent() }),
            "itemsPage": page.structuredContent(),
        ])
    }

    private static var detailedItemsLimit: Int { 100 }
}

private extension ReviewMCPLogProjection.Item {
    func structuredContent() -> Value {
        return .object([
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
            "runId": .string(runID.rawValue),
            "cwd": .string(cwd),
            "targetSummary": .string(targetSummary),
            "run": core.structuredRunContent(),
            "lifecycle": presentation.structuredLifecycleContent(
                core: core,
                elapsedSeconds: elapsedSeconds,
                cancellable: presentation.isCancellable
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
            presentation.cancellation?.message ?? "Review cancelled."
        } else {
            "Review was already finished."
        }
    }

    func structuredContent() -> Value {
        return .object([
            "runId": .string(runID.rawValue),
            "cancelled": .bool(cancelled),
            "run": core.structuredRunContent(),
            "lifecycle": presentation.structuredLifecycleContent(
                core: core,
                elapsedSeconds: nil,
                cancellable: presentation.isCancellable
            ),
            "review": core.structuredReviewContent(),
        ])
    }
}

private extension ReviewAttempt {
    func structuredContent() -> Value {
        .object([
            "attemptId": .string(attemptID.rawValue),
            "reviewThreadId": .string(threadIdentity.activeTurnThreadID.rawValue),
            "threadId": .string(threadIdentity.sourceThreadID.rawValue),
            "turnId": .string(turnID.rawValue),
            "model": model.map(Value.string) ?? .null,
        ])
    }
}

private extension ReviewRunPresentation {
    func structuredContent(
        core: ReviewRunCore,
        elapsedSeconds: Int?,
        cancellable: Bool
    ) -> Value {
        let failure: ReviewBackendFailure?
        let cancellation: ReviewCancellation?
        switch lifecycle {
        case .failed(let value):
            failure = value
            cancellation = nil
        case .cancelling(let value), .cancelled(let value):
            failure = nil
            cancellation = value
        case .queued, .starting, .running, .waitingForNetwork, .preparingRestart,
            .restarting, .succeeded:
            failure = nil
            cancellation = nil
        }
        var object: [String: Value] = [
            "status": .string(status.rawValue),
            "message": .string(lifecycle.message),
            "exitCode": .null,
            "startedAt": core.startedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "endedAt": core.endedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "elapsedSeconds": elapsedSeconds.map(Value.int) ?? .null,
            "cancellable": .bool(cancellable),
        ]
        object["cancellation"] = cancellation.map { $0.structuredContent() } ?? .null
        object["errorMessage"] = failure.map { .string($0.message) } ?? .null
        object["failure"] = failure.map { $0.structuredContent() } ?? .null
        return .object(object)
    }
}

private extension ReviewBackendFailure {
    func structuredContent() -> Value {
        var object: [String: Value] = [
            "message": .string(message),
        ]
        switch self {
        case .operation(let failure):
            object["kind"] = .string("operation")
            object["operation"] = failure.structuredContent()
        case .missingReviewOutput(let turnID):
            object["kind"] = .string("missingReviewOutput")
            object["turnId"] = .string(turnID.rawValue)
        case .outputPublication(let failure):
            object["kind"] = .string("outputPublication")
            object["outputPublication"] = failure.structuredContent()
        case .invalidTerminalStatus(let rawStatus, let turnID, let turnFailure):
            object["kind"] = .string("invalidTerminalStatus")
            object["rawStatus"] = .string(rawStatus)
            object["turnId"] = .string(turnID.rawValue)
            object["turnFailure"] = turnFailure.map { $0.structuredContent() } ?? .null
        case .turnFailed(let turnFailure):
            object["kind"] = .string("turnFailed")
            object["turnFailure"] = turnFailure.structuredContent()
        case .interruptedByBackend(let backendMessage):
            object["kind"] = .string("interruptedByBackend")
            object["backendMessage"] = backendMessage.map(Value.string) ?? .null
        case .connectionTerminated(let termination):
            object["kind"] = .string("connectionTerminated")
            object["connectionTermination"] = termination.structuredContent()
        case .retentionJournal:
            object["kind"] = .string("retentionJournal")
        case .connectivityObservationEnded:
            object["kind"] = .string("connectivityObservationEnded")
        case .prepareRestartCancelledUnexpectedly:
            object["kind"] = .string("prepareRestartCancelledUnexpectedly")
        case .restartCancelledUnexpectedly:
            object["kind"] = .string("restartCancelledUnexpectedly")
        case .protocolViolation:
            object["kind"] = .string("protocolViolation")
        }
        return .object(object)
    }
}

private extension ReviewBackendOperationFailure {
    func structuredContent() -> Value {
        .object([
            "operation": .string(operation.rawValue),
            "message": .string(message),
            "reason": reason.structuredContent(),
        ])
    }
}

private extension ReviewBackendOperationFailure.Reason {
    func structuredContent() -> Value {
        var object: [String: Value] = [:]
        switch self {
        case .launch(let kind):
            object["kind"] = .string("launch")
            object["launchKind"] = .string(kind.rawValue)
        case .request(let requestID, let method, let kind):
            object["kind"] = .string("request")
            object["requestId"] = .int(requestID)
            object["method"] = .string(method)
            object["requestFailure"] = kind.structuredContent()
        case .connectionTerminated(let termination):
            object["kind"] = .string("connectionTerminated")
            object["connectionTermination"] = termination.structuredContent()
        case .turnDeadlineExceeded(let turnID, let duration):
            object["kind"] = .string("turnDeadlineExceeded")
            object["turnId"] = .string(turnID.rawValue)
            object["duration"] = .string(String(describing: duration))
        case .malformedNotification(let method):
            object["kind"] = .string("malformedNotification")
            object["method"] = .string(method)
        case .reviewRestartUnavailable:
            object["kind"] = .string("reviewRestartUnavailable")
        }
        return .object(object)
    }
}

private extension ReviewBackendOperationFailure.RequestKind {
    func structuredContent() -> Value {
        var object: [String: Value] = [:]
        switch self {
        case .encode:
            object["kind"] = .string("encode")
        case .write:
            object["kind"] = .string("write")
        case .transport:
            object["kind"] = .string("transport")
        case .server(let code, let turnFailure):
            object["kind"] = .string("server")
            object["code"] = .int(code)
            object["turnFailure"] = turnFailure.map { $0.structuredContent() } ?? .null
        case .invalidResponse(let expectedType):
            object["kind"] = .string("invalidResponse")
            object["expectedType"] = .string(expectedType)
        case .deadlineExceeded:
            object["kind"] = .string("deadlineExceeded")
        case .overloadRetryExhausted(let lastCode, let lastTurnFailure, let attempts):
            object["kind"] = .string("overloadRetryExhausted")
            object["lastCode"] = .int(lastCode)
            object["lastTurnFailure"] = lastTurnFailure.map { $0.structuredContent() } ?? .null
            object["attempts"] = .int(attempts)
        }
        return .object(object)
    }
}

private extension ReviewOutputPublicationFailure {
    func structuredContent() -> Value {
        var object: [String: Value] = ["message": .string(message)]
        switch self {
        case .refreshFailed(let turnID, _):
            object["kind"] = .string("refreshFailed")
            object["turnId"] = .string(turnID.rawValue)
        case .unavailable(let turnID):
            object["kind"] = .string("unavailable")
            object["turnId"] = .string(turnID.rawValue)
        case .empty(let turnID):
            object["kind"] = .string("empty")
            object["turnId"] = .string(turnID.rawValue)
        case .mismatched(let turnID):
            object["kind"] = .string("mismatched")
            object["turnId"] = .string(turnID.rawValue)
        }
        return .object(object)
    }
}

private extension ReviewBackendConnectionTermination {
    func structuredContent() -> Value {
        switch self {
        case .closed:
            .object(["kind": .string("closed")])
        case .transport(let message):
            .object([
                "kind": .string("transport"),
                "message": .string(message),
            ])
        case .processExited(let status):
            .object([
                "kind": .string("processExited"),
                "status": status.map { .int(Int($0)) } ?? .null,
            ])
        }
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
    func structuredRunContent() -> Value {
        attempt?.structuredContent()
            ?? .object([
                "attemptId": .null,
                "reviewThreadId": .null,
                "threadId": .null,
                "turnId": .null,
                "model": .null,
            ])
    }

}

private extension ReviewRunPresentation {
    var cancellation: ReviewCancellation? {
        switch lifecycle {
        case .cancelling(let cancellation), .cancelled(let cancellation):
            cancellation
        case .queued, .starting, .running, .waitingForNetwork, .preparingRestart,
            .restarting, .succeeded, .failed:
            nil
        }
    }

    func structuredLifecycleContent(
        core: ReviewRunCore,
        elapsedSeconds: Int?,
        cancellable: Bool
    ) -> Value {
        structuredContent(
            core: core,
            elapsedSeconds: elapsedSeconds,
            cancellable: cancellable
        )
    }
}

private extension ReviewRunCore {
    // The run record is not the transcript's source of truth; read paths that
    // hold a log projection pass the resolved final review so structured
    // fields match the text content.
    func structuredReviewContent(resolvedFinalReview: String? = nil) -> Value {
        let finalReview = resolvedFinalReview.flatMap { value -> String? in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
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
