import CodexReview
import Foundation
import SQLiteData
import Testing
@testable import CodexReviewPersistence

@Suite("ReviewHistoryDatabase")
struct ReviewHistoryDatabaseTests {
    @Test("round trips every target through phase-specific records")
    func targetRoundTrip() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        let targets: [CodexReviewAPI.Target] = [
            .uncommittedChanges,
            .baseBranch("main"),
            .commit(sha: "abc123", title: "Persistence"),
            .custom(instructions: "Review persistence boundaries."),
        ]

        for (index, target) in targets.enumerated() {
            let id = "target-\(index)"
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(
                    id: id,
                    cwd: "/tmp/target-\(index)",
                    workspaceSortOrder: Double(index),
                    sortOrder: Double(index),
                    target: target,
                    model: "captured-model"
                ),
                terminal: ReviewHistoryTestSupport.completed(
                    id: id,
                    model: "effective-model"
                ),
                in: database
            )
        }

        let restored = try await database.load(retentionPolicy: .default)
        #expect(restored.map(\.started.target) == targets)
        #expect(restored.allSatisfy { $0.started.model == "captured-model" })
        #expect(restored.allSatisfy { $0.terminal.model == "effective-model" })
        #expect(restored.allSatisfy { $0.terminal.canonicalReview == "No findings." })
        #expect(restored.allSatisfy { $0.terminal.parsedResult?.state == .noFindings })
    }

    @Test("round trips every terminal variant and materialized findings")
    func terminalRoundTrip() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        let cancellation = ReviewCancellation.userInterface(message: "Stopped by reviewer.")
        let parsed = ParsedReviewResult(
            state: .hasFindings,
            findingCount: 2,
            findings: [
                .init(
                    title: "[P1] Preserve the canonical result",
                    body: "Do not persist the live transcript.",
                    priority: 1,
                    location: .init(path: "Sources/Store.swift", startLine: 10, endLine: 12),
                    rawText: "not persisted"
                ),
                .init(
                    title: "[P2] Keep close explicit",
                    body: "Reject operations after close.",
                    priority: 2,
                    location: nil,
                    rawText: "not persisted"
                ),
            ],
            source: .parsedFinalReviewText,
            parserVersion: 7
        )
        let terminals = [
            try ReviewHistoryTestSupport.completed(
                id: "completed",
                finalReview: "Full review comments.",
                parsedResult: parsed
            ),
            try ReviewHistoryTestSupport.nonCompleted(
                id: "failed",
                terminal: .failed(message: "Backend failed.")
            ),
            try ReviewHistoryTestSupport.nonCompleted(
                id: "server",
                terminal: .interrupted(.server(message: nil)),
                summary: "Server stopped."
            ),
            try ReviewHistoryTestSupport.nonCompleted(
                id: "transport",
                terminal: .interrupted(.transport(message: "Connection lost."))
            ),
            try ReviewHistoryTestSupport.nonCompleted(
                id: "cancelled",
                terminal: .interrupted(.requested(cancellation)),
                summary: cancellation.message
            ),
        ]

        for terminal in terminals {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(id: terminal.id),
                terminal: terminal,
                in: database
            )
        }

        let restored = try await database.load(retentionPolicy: .default)
        let byID = Dictionary(uniqueKeysWithValues: restored.map { ($0.started.id, $0) })
        #expect(byID["completed"]?.terminal.terminal == .completed)
        #expect(byID["failed"]?.terminal.terminal == .failed(message: "Backend failed."))
        #expect(byID["server"]?.terminal.terminal == .interrupted(.server(message: nil)))
        #expect(
            byID["transport"]?.terminal.terminal
                == .interrupted(.transport(message: "Connection lost."))
        )
        #expect(
            byID["cancelled"]?.terminal.terminal
                == .interrupted(.requested(cancellation))
        )
        #expect(byID["completed"]?.terminal.parsedResult?.parserVersion == 7)
        #expect(byID["completed"]?.terminal.parsedResult?.findings.count == 2)
        #expect(byID["completed"]?.terminal.parsedResult?.findings[0].ordinal == 0)
        #expect(byID["completed"]?.terminal.parsedResult?.findings[1].location == nil)
    }

    @Test("converts abandoned active rows without inventing an end time")
    func orphanConversion() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(id: "orphan"))

        let restored = try await database.load(retentionPolicy: .default)
        let orphan = try #require(restored.first)
        #expect(orphan.started.id == "orphan")
        #expect(orphan.terminal.terminal == .interrupted(.previousProcessExit))
        #expect(orphan.terminal.endedAt == nil)
        #expect(orphan.started.startedAt == ReviewHistoryTestSupport.startedAt)
    }

    @Test("applies workspace and global retention and returns exact removed IDs")
    func retention() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database(
            now: ReviewHistoryTestSupport.committedAt
        )
        let policy = ReviewHistoryRetentionPolicy(
            maximumReviewsPerWorkspace: 2,
            maximumReviews: 3
        )

        for index in 0..<3 {
            let id = "a-\(index)"
            let result = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(id: id, cwd: "/tmp/a"),
                terminal: ReviewHistoryTestSupport.completed(id: id),
                in: database,
                retentionPolicy: policy
            )
            #expect(result.removedReviewIDs == (index == 2 ? ["a-0"] : []))
        }

        for index in 0..<2 {
            let id = "b-\(index)"
            let result = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(id: id, cwd: "/tmp/b"),
                terminal: ReviewHistoryTestSupport.completed(id: id),
                in: database,
                retentionPolicy: policy
            )
            #expect(result.removedReviewIDs == (index == 1 ? ["a-1"] : []))
        }

        let restored = try await database.load(retentionPolicy: policy)
        #expect(Set(restored.map(\.started.id)) == ["a-2", "b-0", "b-1"])
    }

    @Test("protects the current terminal ID when retention timestamps tie")
    func retentionProtectsCurrentID() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database(
            now: ReviewHistoryTestSupport.committedAt
        )
        let policy = ReviewHistoryRetentionPolicy(
            maximumReviewsPerWorkspace: 1,
            maximumReviews: 1
        )
        _ = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(id: "z-existing"),
            terminal: ReviewHistoryTestSupport.completed(id: "z-existing"),
            in: database,
            retentionPolicy: policy
        )
        let result = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(id: "a-current"),
            terminal: ReviewHistoryTestSupport.completed(id: "a-current"),
            in: database,
            retentionPolicy: policy
        )

        #expect(result.removedReviewIDs == ["z-existing"])
        let restored = try await database.load(retentionPolicy: policy)
        #expect(restored.map(\.started.id) == ["a-current"])
    }

    @Test("breaks startup retention timestamp ties by ID")
    func startupRetentionTieBreak() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database(
            now: ReviewHistoryTestSupport.committedAt
        )
        let widePolicy = ReviewHistoryRetentionPolicy(
            maximumReviewsPerWorkspace: 10,
            maximumReviews: 10
        )
        for id in ["c", "a", "b"] {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(id: id),
                terminal: ReviewHistoryTestSupport.completed(id: id),
                in: database,
                retentionPolicy: widePolicy
            )
        }

        let restored = try await database.load(retentionPolicy: .init(
            maximumReviewsPerWorkspace: 2,
            maximumReviews: 2
        ))
        #expect(Set(restored.map(\.started.id)) == ["b", "c"])
    }

    @Test("terminal commit preserves admission identity and latest manual order")
    func terminalPreservesStartedFields() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(
            id: "ordered",
            cwd: "/tmp/original",
            workspaceSortOrder: 1,
            sortOrder: 2,
            target: .baseBranch("main")
        ))
        try await database.saveOrdering(.init(
            workspaces: [.init(cwd: "/tmp/original", sortOrder: 20)],
            reviews: [.init(id: "ordered", sortOrder: 30)]
        ))
        _ = try await database.recordTerminal(
            ReviewHistoryTestSupport.completed(id: "ordered"),
            retentionPolicy: .default
        )

        let restored = try #require(
            try await database.load(retentionPolicy: .default).first
        )
        #expect(restored.started.cwd == "/tmp/original")
        #expect(restored.started.target == .baseBranch("main"))
        #expect(restored.started.workspaceSortOrder == 20)
        #expect(restored.started.sortOrder == 30)
    }

    @Test("terminal-only deletes preserve active rows and return exact membership")
    func terminalDeletionSemantics() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(
            id: "active",
            cwd: "/tmp/active"
        ))
        _ = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(
                id: "terminal",
                cwd: "/tmp/terminal"
            ),
            terminal: ReviewHistoryTestSupport.completed(id: "terminal"),
            in: database
        )

        #expect(
            try await database.deleteTerminalReview(id: "active").removedReviewIDs == []
        )
        #expect(
            try await database.deleteTerminalReview(id: "missing").removedReviewIDs == []
        )
        #expect(
            try await database.deleteTerminalReview(id: "terminal").removedReviewIDs
                == ["terminal"]
        )

        let reviewIDs = try await writer.read { db in
            try #sql("SELECT id FROM review_records ORDER BY id", as: String.self).fetchAll(db)
        }
        let workspaceIDs = try await writer.read { db in
            try #sql("SELECT cwd FROM review_workspaces ORDER BY cwd", as: String.self).fetchAll(db)
        }
        #expect(reviewIDs == ["active"])
        #expect(workspaceIDs == ["/tmp/active"])
    }

    @Test("delete-all removes only terminal rows and reports every removed ID")
    func deleteAllTerminalReviews() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(id: "active"))
        for id in ["terminal-1", "terminal-2"] {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(id: id, cwd: "/tmp/terminal"),
                terminal: ReviewHistoryTestSupport.completed(id: id),
                in: database
            )
        }

        let result = try await database.deleteAllTerminalReviews()
        #expect(result.removedReviewIDs == ["terminal-1", "terminal-2"])
        let ids = try await writer.read { db in
            try #sql("SELECT id FROM review_records", as: String.self).fetchAll(db)
        }
        #expect(ids == ["active"])
    }

    @Test("rejects every operation after idempotent close")
    func close() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        try await database.close()
        try await database.close()

        await #expect(throws: ReviewHistoryDatabaseError.closed) {
            _ = try await database.load(retentionPolicy: .default)
        }
        await #expect(throws: ReviewHistoryDatabaseError.closed) {
            try await database.recordStarted(ReviewHistoryTestSupport.started(id: "closed"))
        }
        await #expect(throws: ReviewHistoryDatabaseError.closed) {
            _ = try await database.recordTerminal(
                ReviewHistoryTestSupport.completed(id: "closed"),
                retentionPolicy: .default
            )
        }
        await #expect(throws: ReviewHistoryDatabaseError.closed) {
            try await database.saveOrdering(.init(workspaces: [], reviews: []))
        }
        await #expect(throws: ReviewHistoryDatabaseError.closed) {
            _ = try await database.deleteTerminalReview(id: "closed")
        }
        await #expect(throws: ReviewHistoryDatabaseError.closed) {
            _ = try await database.deleteAllTerminalReviews()
        }
    }
}
