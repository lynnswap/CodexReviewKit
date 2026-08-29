import CodexReview
import Foundation
import SQLiteData
import Testing
@testable import CodexReviewPersistence

@Suite("Review history schema")
struct ReviewHistorySchemaTests {
    @Test("creates strict tables with foreign-key enforcement")
    func schemaConstraints() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        _ = try await database.load()

        let strictTableCount = try await writer.read { db in
            try #sql(
                """
                SELECT count(*)
                FROM pragma_table_list
                WHERE name IN ('review_workspaces', 'review_records', 'review_findings')
                  AND strict = 1
                """,
                as: Int.self
            )
            .fetchOne(db)
        }
        let foreignKeysEnabled = try await writer.read { db in
            try #sql("PRAGMA foreign_keys", as: Int.self).fetchOne(db)
        }
        #expect(strictTableCount == 3)
        #expect(foreignKeysEnabled == 1)

        await #expect(throws: (any Error).self) {
            try await writer.write { db in
                try #sql(
                    """
                    INSERT INTO review_workspaces (cwd, sortOrder)
                    VALUES (\(bind: "/tmp/invalid-strict"), \(bind: "not-a-real"))
                    """
                )
                .execute(db)
            }
        }
        await #expect(throws: (any Error).self) {
            try await writer.write { db in
                try #sql(
                    """
                    INSERT INTO review_findings
                      (id, reviewID, ordinal, title, body)
                    VALUES
                      (\(bind: "orphan-finding"), \(bind: "missing-review"), 0,
                       \(bind: "Missing parent"), \(bind: "Body"))
                    """
                )
                .execute(db)
            }
        }
    }

    @Test("deletes finding projections through the review foreign key")
    func cascadeDelete() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        let parsedResult = ParsedReviewResult(
            state: .hasFindings,
            findingCount: 1,
            findings: [
                .init(
                    title: "[P1] Finding",
                    body: "Body",
                    priority: 1,
                    location: .init(path: "File.swift", startLine: 1, endLine: 1),
                    rawText: "not persisted"
                )
            ],
            source: .parsedFinalReviewText
        )
        _ = try await ReviewHistoryTestSupport.record(
            ReviewHistoryTestSupport.completed(
                id: "cascade",
                finalReview: "Review result.",
                parsedResult: parsedResult
            ),
            in: database
        )

        let before = try findingCount(writer)
        try await database.deleteReview(id: "cascade")
        let after = try findingCount(writer)
        #expect(before == 1)
        #expect(after == 0)
    }

    @Test("invalid storage fails load without erasing rows")
    func invalidStorageFailsLoad() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        let parsedResult = ParsedReviewResult(
            state: .hasFindings,
            findingCount: 1,
            findings: [
                .init(
                    title: "[P2] Stable identity",
                    body: "Body",
                    priority: 2,
                    location: nil,
                    rawText: "not persisted"
                )
            ],
            source: .parsedFinalReviewText
        )
        _ = try await ReviewHistoryTestSupport.record(
            ReviewHistoryTestSupport.completed(
                id: "corrupt",
                finalReview: "Review result.",
                parsedResult: parsedResult
            ),
            in: database
        )
        try await writer.write { db in
            try #sql(
                """
                UPDATE review_findings
                SET id = \(bind: "wrong-stable-id")
                WHERE reviewID = \(bind: "corrupt")
                """
            )
            .execute(db)
        }

        await #expect(throws: ReviewHistoryDatabaseError.self) {
            _ = try await database.load()
        }
        #expect(try findingCount(writer) == 1)
        let reviewCount = try await writer.read { db in
            try #sql("SELECT count(*) FROM review_records", as: Int.self).fetchOne(db)
        }
        #expect(reviewCount == 1)
    }

    @Test("reopens a temporary file database")
    func temporaryFileRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CodexReviewHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "review-history.sqlite")

        let first = ReviewHistoryDatabase(databaseURL: url)
        _ = try await ReviewHistoryTestSupport.record(
            ReviewHistoryTestSupport.completed(id: "file-backed"),
            in: first
        )
        try await first.close()

        let second = ReviewHistoryDatabase(databaseURL: url)
        let restored = try await second.load()
        #expect(restored.map(\.id) == ["file-backed"])
        try await second.close()
    }

    private func findingCount(_ writer: any DatabaseWriter) throws -> Int? {
        try writer.read { db in
            try #sql("SELECT count(*) FROM review_findings", as: Int.self).fetchOne(db)
        }
    }
}
