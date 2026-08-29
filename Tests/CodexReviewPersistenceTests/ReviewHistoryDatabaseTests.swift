import CodexReview
import Foundation
import SQLiteData
import Testing
@testable import CodexReviewPersistence

@Suite("ReviewHistoryDatabase")
struct ReviewHistoryDatabaseTests {
    @Test("round trips every target variant")
    func targetRoundTrip() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        let targets: [CodexReviewAPI.Target] = [
            .uncommittedChanges,
            .baseBranch("main"),
            .commit(sha: "abc123", title: "Persistence"),
            .custom(instructions: "Review persistence boundaries."),
        ]

        for (index, target) in targets.enumerated() {
            let terminal = ReviewHistoryTestSupport.completed(
                id: "target-\(index)",
                cwd: "/tmp/target-\(index)",
                workspaceSortOrder: Double(index),
                sortOrder: Double(index),
                target: target
            )
            _ = try await ReviewHistoryTestSupport.record(terminal, in: database)
        }

        let restored = try await database.load()
        #expect(restored.map(\.target) == targets)
        #expect(restored.allSatisfy { $0.core.output.lastAgentMessage == "No findings." })
        #expect(restored.allSatisfy { $0.core.output.reviewResult?.state == .noFindings })
    }

    @Test("round trips terminal variants and materialized findings")
    func terminalRoundTrip() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        let cancellation = ReviewCancellation.userInterface(message: "Stopped by reviewer.")
        let findings = ParsedReviewResult(
            state: .hasFindings,
            findingCount: 2,
            findings: [
                .init(
                    title: "[P1] Preserve the canonical result",
                    body: "Do not persist the live transcript.",
                    priority: 1,
                    location: .init(path: "Sources/Store.swift", startLine: 10, endLine: 12),
                    rawText: "ignored storage projection"
                ),
                .init(
                    title: "[P2] Keep close explicit",
                    body: "Reject operations after close.",
                    priority: 2,
                    location: nil,
                    rawText: "ignored storage projection"
                ),
            ],
            source: .parsedFinalReviewText,
            parserVersion: 7
        )
        let terminals = [
            ReviewHistoryTestSupport.completed(
                id: "completed",
                finalReview: "Full review comments:\n- [P1] Preserve — Sources/Store.swift:10-12",
                parsedResult: findings
            ),
            ReviewHistoryTestSupport.failed(
                id: "failed",
                terminal: .failed(message: "Backend failed.")
            ),
            ReviewHistoryTestSupport.failed(
                id: "server",
                terminal: .interrupted(.server(message: nil)),
                errorMessage: nil,
                summary: "Server stopped."
            ),
            ReviewHistoryTestSupport.failed(
                id: "transport",
                terminal: .interrupted(.transport(message: "Connection lost.")),
                errorMessage: "Connection lost."
            ),
            ReviewHistoryTestSupport.failed(
                id: "cancelled",
                terminal: .interrupted(.requested(cancellation)),
                errorMessage: cancellation.message,
                summary: cancellation.message,
                cancellation: cancellation
            ),
        ]

        for terminal in terminals {
            _ = try await ReviewHistoryTestSupport.record(terminal, in: database)
        }

        let restored = try await database.load()
        let byID = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        #expect(byID["completed"]?.core.lifecycle.terminal == .completed)
        #expect(byID["failed"]?.core.lifecycle.terminal == .failed(message: "Backend failed."))
        #expect(byID["server"]?.core.lifecycle.terminal == .interrupted(.server(message: nil)))
        #expect(
            byID["transport"]?.core.lifecycle.terminal
                == .interrupted(.transport(message: "Connection lost."))
        )
        #expect(
            byID["cancelled"]?.core.lifecycle.terminal
                == .interrupted(.requested(cancellation))
        )
        #expect(byID["completed"]?.core.output.reviewResult?.parserVersion == 7)
        #expect(byID["completed"]?.core.output.reviewResult?.findings.count == 2)
        #expect(
            byID["completed"]?.core.output.reviewResult?.findings[0].rawText
                == "- [P1] Preserve the canonical result — Sources/Store.swift:10-12\n"
                    + "  Do not persist the live transcript."
        )
    }

    @Test("converts abandoned active rows without inventing an end time")
    func orphanConversion() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(id: "orphan"))

        let restored = try await database.load()
        let orphan = try #require(restored.first)
        #expect(orphan.id == "orphan")
        #expect(orphan.core.lifecycle.status == .failed)
        #expect(orphan.core.lifecycle.terminal == .interrupted(.previousProcessExit))
        #expect(orphan.core.lifecycle.endedAt == nil)
        #expect(orphan.core.lifecycle.startedAt == ReviewHistoryTestSupport.startedAt)
    }

    @Test("applies workspace and global retention and returns removed IDs")
    func retention() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        let policy = ReviewHistoryRetentionPolicy(
            maximumReviewsPerWorkspace: 2,
            maximumReviews: 3
        )

        for index in 0..<3 {
            let terminal = ReviewHistoryTestSupport.completed(
                id: "a-\(index)",
                cwd: "/tmp/a",
                startedAt: ReviewHistoryTestSupport.startedAt.addingTimeInterval(Double(index * 100))
            )
            let result = try await ReviewHistoryTestSupport.record(
                terminal,
                in: database,
                retentionPolicy: policy
            )
            #expect(result.removedReviewIDs == (index == 2 ? ["a-0"] : []))
        }

        for index in 0..<2 {
            let terminal = ReviewHistoryTestSupport.completed(
                id: "b-\(index)",
                cwd: "/tmp/b",
                startedAt: ReviewHistoryTestSupport.startedAt
                    .addingTimeInterval(Double(1_000 + index * 100))
            )
            let result = try await ReviewHistoryTestSupport.record(
                terminal,
                in: database,
                retentionPolicy: policy
            )
            #expect(result.removedReviewIDs == (index == 1 ? ["a-1"] : []))
        }

        let restored = try await database.load()
        #expect(Set(restored.map(\.id)) == ["a-2", "b-0", "b-1"])
        #expect(ReviewHistoryRetentionPolicy.default.maximumReviewsPerWorkspace == 50)
        #expect(ReviewHistoryRetentionPolicy.default.maximumReviews == 500)
    }

    @Test("persists ordering")
    func ordering() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        for (id, cwd) in [("one", "/tmp/one"), ("two", "/tmp/two")] {
            _ = try await ReviewHistoryTestSupport.record(
                ReviewHistoryTestSupport.completed(id: id, cwd: cwd),
                in: database
            )
        }

        try await database.saveOrdering(.init(
            workspaces: [
                .init(cwd: "/tmp/one", sortOrder: 20),
                .init(cwd: "/tmp/two", sortOrder: 10),
            ],
            reviews: [
                .init(id: "one", sortOrder: 2),
                .init(id: "two", sortOrder: 1),
            ]
        ))

        let restored = try await database.load()
        #expect(restored.map(\.id) == ["two", "one"])
        #expect(restored.map(\.workspaceSortOrder) == [10, 20])
        #expect(restored.map(\.sortOrder) == [1, 2])
    }

    @Test("deleteAll preserves active rows and individual deletion rejects them")
    func activeDeletionSemantics() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(id: "active"))
        _ = try await ReviewHistoryTestSupport.record(
            ReviewHistoryTestSupport.completed(id: "terminal", cwd: "/tmp/terminal"),
            in: database
        )

        await #expect(throws: ReviewHistoryDatabaseError.activeReviewCannotBeDeleted("active")) {
            try await database.deleteReview(id: "active")
        }
        try await database.deleteAll()

        let ids = try await writer.read { db in
            try #sql("SELECT id FROM review_records ORDER BY id", as: String.self).fetchAll(db)
        }
        #expect(ids == ["active"])
    }

    @Test("rejects partial output on a failed terminal without mutating the active row")
    func rejectsPartialFailedProjection() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(id: "partial"))
        let partial = ReviewHistoryTestSupport.failed(
            id: "partial",
            lastAgentMessage: "Partial streamed answer.",
            reviewResult: .notAvailable()
        )

        await #expect(throws: ReviewHistoryDatabaseError.self) {
            _ = try await database.recordTerminal(partial, retentionPolicy: .default)
        }
        let status = try await writer.read { db in
            try #sql(
                "SELECT status FROM review_records WHERE id = \(bind: "partial")",
                as: String.self
            )
            .fetchOne(db)
        }
        #expect(status == ReviewJobState.running.rawValue)
    }

    @Test("requires a known review start time")
    func rejectsMissingStartedAt() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        let missingStart = ReviewHistoryRecord(
            id: "missing-start",
            cwd: "/tmp/workspace",
            workspaceSortOrder: 0,
            sortOrder: 0,
            target: .uncommittedChanges,
            core: ReviewJobCore(
                lifecycle: .init(status: .running),
                output: .init(summary: "Review started.")
            )
        )

        await #expect(throws: ReviewHistoryDatabaseError.self) {
            try await database.recordStarted(missingStart)
        }
        let count = try await writer.read { db in
            try #sql("SELECT count(*) FROM review_records", as: Int.self).fetchOne(db)
        }
        #expect(count == 0)
    }

    @Test("rejects every operation after idempotent close")
    func close() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        try await database.close()
        try await database.close()

        await #expect(throws: ReviewHistoryDatabaseError.closed) {
            _ = try await database.load()
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
            try await database.deleteReview(id: "closed")
        }
        await #expect(throws: ReviewHistoryDatabaseError.closed) {
            try await database.deleteAll()
        }
    }
}
