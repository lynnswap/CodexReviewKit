import CodexReview
import Foundation
import SQLiteData
@testable import CodexReviewPersistence

enum ReviewHistoryTestSupport {
    static let startedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let committedAt = Date(timeIntervalSinceReferenceDate: 800_001_000)

    static func database(
        now: Date? = nil
    ) throws -> (ReviewHistoryDatabase, DatabaseQueue) {
        let writer = try DatabaseQueue()
        if let now {
            return (
                ReviewHistoryDatabase(databaseWriter: writer, now: { now }),
                writer
            )
        }
        return (ReviewHistoryDatabase(databaseWriter: writer), writer)
    }

    static func started(
        id: String,
        cwd: String = "/tmp/workspace",
        workspaceMetadata: ReviewWorkspaceMetadata? = nil,
        workspaceSortOrder: Double = 0,
        sortOrder: Double = 0,
        target: CodexReviewAPI.Target = .uncommittedChanges,
        model: String? = "gpt-5.6-sol",
        startedAt: Date = startedAt
    ) throws -> StartedReviewRecord {
        try StartedReviewRecord(
            id: id,
            cwd: cwd,
            workspaceMetadata: workspaceMetadata,
            workspaceSortOrder: workspaceSortOrder,
            sortOrder: sortOrder,
            target: target,
            model: model,
            startedAt: startedAt
        )
    }

    static func completed(
        id: String,
        model: String? = "gpt-5.6-sol",
        endedAt: Date? = nil,
        finalReview: String = "No findings.",
        parsedResult: ParsedReviewResult? = nil
    ) throws -> TerminalReviewRecord {
        try TerminalReviewRecord(
            id: id,
            model: model,
            terminal: .completed,
            endedAt: endedAt ?? startedAt.addingTimeInterval(30),
            summary: "Review completed.",
            canonicalReview: finalReview,
            parsedResult: PersistedParsedReviewResult(
                parsedResult ?? .parse(finalReviewText: finalReview)
            )
        )
    }

    static func nonCompleted(
        id: String,
        model: String? = "gpt-5.6-sol",
        terminal: ReviewTerminalRecord = .failed(message: "Backend failed."),
        endedAt: Date? = nil,
        summary: String = "Review failed."
    ) throws -> TerminalReviewRecord {
        let resolvedEnd: Date? = if case .interrupted(.previousProcessExit) = terminal {
            endedAt
        } else {
            endedAt ?? startedAt.addingTimeInterval(15)
        }
        return try TerminalReviewRecord(
            id: id,
            model: model,
            terminal: terminal,
            endedAt: resolvedEnd,
            summary: summary,
            canonicalReview: nil,
            parsedResult: nil
        )
    }

    static func record(
        started: StartedReviewRecord,
        terminal: TerminalReviewRecord,
        in database: ReviewHistoryDatabase,
        retentionPolicy: ReviewHistoryRetentionPolicy = .default
    ) async throws -> ReviewHistoryMutationResult {
        try await database.recordStarted(started)
        return try await database.recordTerminal(
            terminal,
            retentionPolicy: retentionPolicy
        )
    }
}
