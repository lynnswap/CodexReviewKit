import CodexReview
import Foundation
import SQLiteData
@testable import CodexReviewPersistence

enum ReviewHistoryTestSupport {
    static let startedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func database() throws -> (ReviewHistoryDatabase, DatabaseQueue) {
        let writer = try DatabaseQueue()
        return (ReviewHistoryDatabase(databaseWriter: writer), writer)
    }

    static func started(
        id: String,
        cwd: String = "/tmp/workspace",
        workspaceSortOrder: Double = 0,
        sortOrder: Double = 0,
        target: CodexReviewAPI.Target = .uncommittedChanges,
        startedAt: Date = startedAt
    ) -> ReviewHistoryRecord {
        ReviewHistoryRecord(
            id: id,
            cwd: cwd,
            workspaceSortOrder: workspaceSortOrder,
            sortOrder: sortOrder,
            target: target,
            core: ReviewJobCore(
                lifecycle: .init(status: .running, startedAt: startedAt),
                output: .init(summary: "Review started.")
            )
        )
    }

    static func completed(
        id: String,
        cwd: String = "/tmp/workspace",
        workspaceSortOrder: Double = 0,
        sortOrder: Double = 0,
        target: CodexReviewAPI.Target = .uncommittedChanges,
        startedAt: Date = startedAt,
        endedAt: Date? = nil,
        finalReview: String = "No findings.",
        parsedResult: ParsedReviewResult? = nil
    ) -> ReviewHistoryRecord {
        let end = endedAt ?? startedAt.addingTimeInterval(30)
        return ReviewHistoryRecord(
            id: id,
            cwd: cwd,
            workspaceSortOrder: workspaceSortOrder,
            sortOrder: sortOrder,
            target: target,
            core: ReviewJobCore(
                run: .init(
                    reviewThreadID: "review-thread-\(id)",
                    threadID: "thread-\(id)",
                    turnID: "turn-\(id)",
                    model: "gpt-5.6-sol"
                ),
                lifecycle: .init(
                    status: .succeeded,
                    exitCode: 0,
                    startedAt: startedAt,
                    endedAt: end,
                    terminal: .completed
                ),
                output: .init(
                    summary: "Review completed.",
                    hasFinalReview: true,
                    lastAgentMessage: finalReview,
                    reviewResult: parsedResult ?? .parse(finalReviewText: finalReview)
                )
            )
        )
    }

    static func failed(
        id: String,
        cwd: String = "/tmp/workspace",
        workspaceSortOrder: Double = 0,
        sortOrder: Double = 0,
        target: CodexReviewAPI.Target = .uncommittedChanges,
        startedAt: Date = startedAt,
        endedAt: Date? = nil,
        terminal: ReviewTerminalRecord = .failed(message: "Backend failed."),
        errorMessage: String? = "Backend failed.",
        summary: String = "Review failed.",
        cancellation: ReviewCancellation? = nil,
        lastAgentMessage: String? = nil,
        reviewResult: ParsedReviewResult? = nil
    ) -> ReviewHistoryRecord {
        let status: ReviewJobState = if case .interrupted(.requested) = terminal {
            .cancelled
        } else {
            .failed
        }
        return ReviewHistoryRecord(
            id: id,
            cwd: cwd,
            workspaceSortOrder: workspaceSortOrder,
            sortOrder: sortOrder,
            target: target,
            core: ReviewJobCore(
                lifecycle: .init(
                    status: status,
                    startedAt: startedAt,
                    endedAt: endedAt ?? startedAt.addingTimeInterval(15),
                    cancellation: cancellation,
                    errorMessage: errorMessage,
                    terminal: terminal
                ),
                output: .init(
                    summary: summary,
                    lastAgentMessage: lastAgentMessage,
                    reviewResult: reviewResult
                )
            )
        )
    }

    static func record(
        _ terminal: ReviewHistoryRecord,
        in database: ReviewHistoryDatabase,
        retentionPolicy: ReviewHistoryRetentionPolicy = .default
    ) async throws -> ReviewHistoryMutationResult {
        try await database.recordStarted(started(
            id: terminal.id,
            cwd: terminal.cwd,
            workspaceSortOrder: terminal.workspaceSortOrder,
            sortOrder: terminal.sortOrder,
            target: terminal.target,
            startedAt: terminal.core.lifecycle.startedAt ?? startedAt
        ))
        return try await database.recordTerminal(
            terminal,
            retentionPolicy: retentionPolicy
        )
    }
}
