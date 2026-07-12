import Foundation
import CodexAppServerKit
import CodexDataKit
import CodexReviewKit

package enum CodexReviewMCP {
    package enum Tool {}
}

package typealias ReviewMCPLogProjectionProvider = @MainActor @Sendable (
    CodexReviewAPI.Read.Result
) async throws -> ReviewChatProjectionLookup

package extension CodexReviewMCP.Tool {
    enum Name: String, Codable, Equatable, Sendable, CaseIterable {
        case reviewStart = "review_start"
        case reviewAwait = "review_await"
        case reviewRead = "review_read"
        case reviewList = "review_list"
        case reviewCancel = "review_cancel"
    }
}

package extension CodexReviewMCP.Tool {
    struct Descriptor: Codable, Equatable, Sendable {
        package var name: CodexReviewMCP.Tool.Name
        package var description: String

        package init(name: CodexReviewMCP.Tool.Name, description: String) {
            self.name = name
            self.description = description
        }
    }
}

package extension CodexReviewMCP.Tool {
    enum Request: Equatable, Sendable {
        case reviewStart(sessionID: String, request: CodexReviewAPI.Start.Request, waitTimeout: Duration?)
        case reviewAwait(sessionID: String?, runID: ReviewRunID, waitTimeout: Duration)
        case reviewRead(sessionID: String?, runID: ReviewRunID)
        case reviewList(sessionID: String?, cwd: String?, statuses: [ReviewRunState]?, limit: Int?)
        case reviewCancel(sessionID: String?, selector: CodexReviewAPI.Run.Selector, reason: ReviewCancellation)
    }
}

package extension CodexReviewMCP.Tool {
    internal struct ReviewSnapshot: Equatable, Sendable {
        var result: CodexReviewAPI.Read.Result
        var log: ReviewMCPLogProjection

        init(result: CodexReviewAPI.Read.Result, log: ReviewMCPLogProjection) {
            self.result = result
            self.log = log
        }
    }
}

package extension CodexReviewMCP.Tool {
    internal enum Response: Equatable, Sendable {
        case reviewStart(ReviewSnapshot)
        case reviewAwait(ReviewSnapshot)
        case reviewRead(ReviewSnapshot)
        case reviewList(CodexReviewAPI.List.Result)
        case reviewCancel(CodexReviewAPI.Cancel.Outcome)
    }
}

@MainActor
package final class CodexReviewMCPServer {
    private let store: CodexReviewStore
    private let logProjectionProvider: ReviewMCPLogProjectionProvider?

    package init(
        store: CodexReviewStore,
        logProjectionProvider: ReviewMCPLogProjectionProvider? = nil
    ) {
        self.store = store
        self.logProjectionProvider = logProjectionProvider
    }

    package var tools: [CodexReviewMCP.Tool.Descriptor] {
        [
            .init(name: .reviewStart, description: "Start a Codex review."),
            .init(name: .reviewAwait, description: "Wait for a running Codex review run."),
            .init(name: .reviewRead, description: "Read a Codex review run."),
            .init(name: .reviewList, description: "List Codex review runs."),
            .init(name: .reviewCancel, description: "Cancel a Codex review run."),
        ]
    }

    func handle(
        _ request: CodexReviewMCP.Tool.Request,
        allowedRunIDs: Set<ReviewRunID>? = nil
    ) async throws -> CodexReviewMCP.Tool.Response {
        switch request {
        case .reviewStart(let sessionID, let reviewRequest, let waitTimeout):
            let runID = try await beginReview(
                sessionID: sessionID,
                request: reviewRequest
            )
            return try await finishReviewStart(
                sessionID: sessionID,
                runID: runID,
                waitTimeout: waitTimeout
            )
        case .reviewAwait(let sessionID, let runID, let waitTimeout):
            try requireAllowed(runID, allowedRunIDs: allowedRunIDs)
            let snapshot = try await reviewSnapshot(
                try await store.awaitReview(
                    sessionID: sessionID,
                    runID: runID,
                    timeout: waitTimeout
                ),
                sessionID: sessionID
            )
            return .reviewAwait(snapshot)
        case .reviewRead(let sessionID, let runID):
            try requireAllowed(runID, allowedRunIDs: allowedRunIDs)
            let snapshot = try await reviewSnapshot(
                try store.readReview(
                    sessionID: sessionID,
                    runID: runID
                ),
                sessionID: sessionID
            )
            return .reviewRead(snapshot)
        case .reviewList(let sessionID, let cwd, let statuses, let limit):
            return .reviewList(store.listReviews(
                sessionID: sessionID,
                cwd: cwd,
                statuses: statuses,
                limit: limit,
                allowedRunIDs: allowedRunIDs
            ))
        case .reviewCancel(let sessionID, let selector, let reason):
            let runRecord = try store.resolveRun(
                sessionID: sessionID,
                selector: selector.defaultingToActiveStatusesForCancellation(),
                allowedRunIDs: allowedRunIDs
            )
            return .reviewCancel(try await store.cancelReview(
                runID: runRecord.id,
                cancellation: reason
            ))
        }
    }

    func beginReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) async throws -> ReviewRunID {
        try await store.beginReview(sessionID: sessionID, request: request)
    }

    func finishReviewStart(
        sessionID: String,
        runID: ReviewRunID,
        waitTimeout: Duration?
    ) async throws -> CodexReviewMCP.Tool.Response {
        let result = try await store.awaitReview(
            sessionID: sessionID,
            runID: runID,
            timeout: waitTimeout
        )
        return .reviewStart(try await reviewSnapshot(result, sessionID: sessionID))
    }

    private func requireAllowed(
        _ runID: ReviewRunID,
        allowedRunIDs: Set<ReviewRunID>?
    ) throws {
        guard let allowedRunIDs else {
            return
        }
        guard allowedRunIDs.contains(runID) else {
            throw MCPReviewSessionRegistryError.runNotFound(runID)
        }
    }

    private func reviewSnapshot(
        _ result: CodexReviewAPI.Read.Result,
        sessionID: String?
    ) async throws -> CodexReviewMCP.Tool.ReviewSnapshot {
        if let sessionID {
            _ = try store.resolveRun(sessionID: sessionID, selector: .init(runID: result.runID))
        }
        let lookup = try await logProjectionProvider?(result) ?? .unavailable
        let log = try resolvedLogProjection(lookup, for: result)
        return .init(result: result, log: log)
    }

    private func resolvedLogProjection(
        _ lookup: ReviewChatProjectionLookup,
        for result: CodexReviewAPI.Read.Result
    ) throws -> ReviewMCPLogProjection {
        switch lookup {
        case .available(let projection):
            guard let attempt = result.core.attempt,
                  projection.turnID?.rawValue == attempt.turnID.rawValue else {
                throw ReviewMCPError.projectionInvariantViolation(runID: result.runID)
            }
            if result.presentation.status == .succeeded,
               projection.finalResult?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw ReviewMCPError.projectionInvariantViolation(runID: result.runID)
            }
            return projection
        case .unavailable:
            guard result.presentation.status != .succeeded else {
                throw ReviewMCPError.projectionInvariantViolation(runID: result.runID)
            }
            return .unavailable(result: result)
        case .refreshFailed(let failure):
            throw ReviewMCPError.projectionRefreshFailed(
                runID: result.runID,
                failure: failure
            )
        }
    }

    package func closeSession(
        _ sessionID: String
    ) async -> MCPReviewSessionStoreCloseResult {
        let result = await store.closeSession(sessionID)
        return .init(
            terminalAndDrainedRunIDs: result.terminalAndDrainedRunIDs,
            failedRunIDs: result.failedRunIDs
        )
    }

    package func releaseClosedSession(_ sessionID: String) {
        store.releaseClosedSession(sessionID)
    }

    package func hasActiveReviews(in sessionID: String) -> Bool {
        store.activeReviewRunIDs(for: sessionID).isEmpty == false
    }
}

package extension CodexReviewMCPServer {
    static func chatLogProjectionProvider(
        modelContext: CodexModelContext
    ) -> ReviewMCPLogProjectionProvider {
        { result in
            guard let attempt = result.core.attempt else {
                return .unavailable
            }
            let turnID = attempt.turnID.rawValue
            let threadID = attempt.threadIdentity.activeTurnThreadID.rawValue

            let chat = modelContext.model(for: CodexThreadID(rawValue: threadID))
            do {
                try await modelContext.refresh(chat, includeTurns: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as CodexFetchFailure {
                return .refreshFailed(failure)
            } catch let failure as CodexAppServerError {
                return .refreshFailed(.appServer(failure))
            } catch {
                preconditionFailure("CodexDataKit refresh threw an unsupported error: \(error)")
            }
            let codexTurnID = CodexTurnID(rawValue: turnID)
            guard chat.turn(id: codexTurnID) != nil else {
                return .unavailable
            }
            let transcript = chat.transcript(in: codexTurnID)
            return .available(ReviewMCPLogProjection(
                result: result,
                turnID: codexTurnID,
                threadItems: transcript.items,
                reviewOutputText: transcript.reviewOutputText
            ))
        }
    }
}

private extension CodexReviewAPI.Run.Selector {
    func defaultingToActiveStatusesForCancellation() -> CodexReviewAPI.Run.Selector {
        guard runID == nil, statuses == nil else {
            return self
        }
        return .init(runID: runID, cwd: cwd, statuses: [.queued, .running])
    }
}
