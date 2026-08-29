import CodexReview
import Foundation
import SQLiteData
import Testing
@testable import CodexReviewPersistence

@Suite("Review history schema")
struct ReviewHistorySchemaTests {
    @Test("creates strict phase tables with foreign-key enforcement")
    func schemaConstraints() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        _ = try await database.load(retentionPolicy: .default)

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
        let tableNames = try await writer.read { db in
            try #sql(
                """
                SELECT name
                FROM pragma_table_list
                WHERE schema = 'main' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """,
                as: String.self
            )
            .fetchAll(db)
        }
        let workspaceColumns = try await writer.read { db in
            try #sql(
                "SELECT name FROM pragma_table_info('review_workspaces') ORDER BY cid",
                as: String.self
            )
            .fetchAll(db)
        }
        let recordColumns = try await writer.read { db in
            try #sql(
                "SELECT name FROM pragma_table_info('review_records') ORDER BY cid",
                as: String.self
            )
            .fetchAll(db)
        }
        let findingColumns = try await writer.read { db in
            try #sql(
                "SELECT name FROM pragma_table_info('review_findings') ORDER BY cid",
                as: String.self
            )
            .fetchAll(db)
        }
        #expect(strictTableCount == 3)
        #expect(foreignKeysEnabled == 1)
        #expect(tableNames == [
            "grdb_migrations",
            "review_findings",
            "review_records",
            "review_workspaces",
        ])
        #expect(workspaceColumns == ["cwd", "sortOrder"])
        #expect(recordColumns == [
            "id",
            "cwd",
            "sortOrder",
            "targetKind",
            "targetBranch",
            "targetCommitSHA",
            "targetCommitTitle",
            "targetInstructions",
            "startedModel",
            "startedAt",
            "phase",
            "terminalModel",
            "terminalKind",
            "interruptionKind",
            "cancellationSource",
            "cancellationMessage",
            "terminalMessage",
            "endedAt",
            "summary",
            "canonicalReview",
            "parsedState",
            "parsedFindingCount",
            "parsedSource",
            "parserVersion",
            "terminalCommittedAt",
            "createdAt",
            "updatedAt",
        ])
        #expect(findingColumns == [
            "id",
            "reviewID",
            "ordinal",
            "priority",
            "title",
            "body",
            "path",
            "startLine",
            "endLine",
        ])

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

    @Test("rejects NULL required variant fields instead of accepting UNKNOWN checks")
    func nullableRequiredVariantConstraints() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        let validActiveIDs = [
            "missing-terminal-kind",
            "missing-canonical-review",
            "missing-parser",
            "missing-interruption-kind",
            "missing-cancellation-source",
        ]
        for id in validActiveIDs {
            try await database.recordStarted(ReviewHistoryTestSupport.started(id: id))
        }

        for (id, targetKind) in [
            ("missing-base-branch", "baseBranch"),
            ("missing-commit-sha", "commit"),
            ("missing-custom-instructions", "custom"),
        ] {
            await #expect(throws: (any Error).self) {
                try await writer.write { db in
                    try #sql(
                        """
                        INSERT INTO review_records (
                          id, cwd, sortOrder, targetKind, startedAt, phase, createdAt, updatedAt
                        ) VALUES (
                          \(bind: id), \(bind: "/tmp/workspace"), 0, \(bind: targetKind),
                          0, 'active', 0, 0
                        )
                        """
                    )
                    .execute(db)
                }
            }
        }

        await #expect(throws: (any Error).self) {
            try await writer.write { db in
                try #sql(
                    """
                    UPDATE review_records
                    SET phase = 'terminal',
                        summary = 'Done',
                        terminalCommittedAt = 60,
                        updatedAt = 60
                    WHERE id = 'missing-terminal-kind'
                    """
                )
                .execute(db)
            }
        }
        await #expect(throws: (any Error).self) {
            try await writer.write { db in
                try #sql(
                    """
                    UPDATE review_records
                    SET phase = 'terminal',
                        terminalKind = 'completed',
                        endedAt = 60,
                        summary = 'Done',
                        parsedState = 'noFindings',
                        parsedFindingCount = 0,
                        parsedSource = 'parsedFinalReviewText',
                        parserVersion = 1,
                        terminalCommittedAt = 60,
                        updatedAt = 60
                    WHERE id = 'missing-canonical-review'
                    """
                )
                .execute(db)
            }
        }
        await #expect(throws: (any Error).self) {
            try await writer.write { db in
                try #sql(
                    """
                    UPDATE review_records
                    SET phase = 'terminal',
                        terminalKind = 'completed',
                        endedAt = 60,
                        summary = 'Done',
                        canonicalReview = 'No findings.',
                        terminalCommittedAt = 60,
                        updatedAt = 60
                    WHERE id = 'missing-parser'
                    """
                )
                .execute(db)
            }
        }
        await #expect(throws: (any Error).self) {
            try await writer.write { db in
                try #sql(
                    """
                    UPDATE review_records
                    SET phase = 'terminal',
                        terminalKind = 'interrupted',
                        endedAt = 60,
                        summary = 'Interrupted',
                        terminalCommittedAt = 60,
                        updatedAt = 60
                    WHERE id = 'missing-interruption-kind'
                    """
                )
                .execute(db)
            }
        }
        await #expect(throws: (any Error).self) {
            try await writer.write { db in
                try #sql(
                    """
                    UPDATE review_records
                    SET phase = 'terminal',
                        terminalKind = 'interrupted',
                        interruptionKind = 'requested',
                        cancellationMessage = 'Stop',
                        endedAt = 60,
                        summary = 'Interrupted',
                        terminalCommittedAt = 60,
                        updatedAt = 60
                    WHERE id = 'missing-cancellation-source'
                    """
                )
                .execute(db)
            }
        }
        await #expect(throws: (any Error).self) {
            try await writer.write { db in
                try #sql(
                    """
                    INSERT INTO review_findings (
                      id, reviewID, ordinal, title, body, path
                    ) VALUES (
                      'missing-location-lines', 'missing-terminal-kind', 0,
                      'Finding', 'Body', 'File.swift'
                    )
                    """
                )
                .execute(db)
            }
        }
    }

    @Test("deletes finding projections through the review foreign key")
    func cascadeDelete() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        let rawTextSentinel = "RAW-TEXT-SENTINEL-MUST-NOT-BE-DURABLE"
        let parsedResult = ParsedReviewResult(
            state: .hasFindings,
            findingCount: 1,
            findings: [
                .init(
                    title: "[P1] Finding",
                    body: "Body",
                    priority: 1,
                    location: .init(path: "File.swift", startLine: 1, endLine: 1),
                    rawText: rawTextSentinel
                )
            ],
            source: .parsedFinalReviewText
        )
        _ = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(id: "cascade"),
            terminal: ReviewHistoryTestSupport.completed(
                id: "cascade",
                finalReview: "Review result.",
                parsedResult: parsedResult
            ),
            in: database
        )

        let before = try findingCount(writer)
        let persistedSentinelCount = try await writer.read { db in
            try #sql(
                """
                SELECT count(*)
                FROM (
                  SELECT cwd AS value FROM review_workspaces
                  UNION ALL SELECT id FROM review_records
                  UNION ALL SELECT cwd FROM review_records
                  UNION ALL SELECT targetKind FROM review_records
                  UNION ALL SELECT targetBranch FROM review_records
                  UNION ALL SELECT targetCommitSHA FROM review_records
                  UNION ALL SELECT targetCommitTitle FROM review_records
                  UNION ALL SELECT targetInstructions FROM review_records
                  UNION ALL SELECT startedModel FROM review_records
                  UNION ALL SELECT phase FROM review_records
                  UNION ALL SELECT terminalModel FROM review_records
                  UNION ALL SELECT terminalKind FROM review_records
                  UNION ALL SELECT interruptionKind FROM review_records
                  UNION ALL SELECT cancellationSource FROM review_records
                  UNION ALL SELECT cancellationMessage FROM review_records
                  UNION ALL SELECT terminalMessage FROM review_records
                  UNION ALL SELECT summary FROM review_records
                  UNION ALL SELECT canonicalReview FROM review_records
                  UNION ALL SELECT parsedState FROM review_records
                  UNION ALL SELECT parsedSource FROM review_records
                  UNION ALL SELECT id FROM review_findings
                  UNION ALL SELECT reviewID FROM review_findings
                  UNION ALL SELECT title FROM review_findings
                  UNION ALL SELECT body FROM review_findings
                  UNION ALL SELECT path FROM review_findings
                )
                WHERE value = \(bind: rawTextSentinel)
                """,
                as: Int.self
            )
            .fetchOne(db)
        }
        _ = try await database.deleteTerminalReview(id: "cascade")
        let after = try findingCount(writer)
        #expect(before == 1)
        #expect(persistedSentinelCount == 0)
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
            started: ReviewHistoryTestSupport.started(id: "corrupt"),
            terminal: ReviewHistoryTestSupport.completed(
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
            _ = try await database.load(retentionPolicy: .default)
        }
        #expect(try findingCount(writer) == 1)
        let reviewCount = try await writer.read { db in
            try #sql("SELECT count(*) FROM review_records", as: Int.self).fetchOne(db)
        }
        #expect(reviewCount == 1)
    }

    @Test("reopens a temporary file database through the lazy URL owner")
    func temporaryFileRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "CodexReviewHistoryTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "review-history.sqlite")

        let first = ReviewHistoryDatabase(databaseURL: url)
        _ = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(id: "file-backed"),
            terminal: ReviewHistoryTestSupport.completed(id: "file-backed"),
            in: first
        )
        try await first.close()

        let second = ReviewHistoryDatabase(databaseURL: url)
        let restored = try await second.load(retentionPolicy: .default)
        #expect(restored.map(\.started.id) == ["file-backed"])
        try await second.close()
    }

    private func findingCount(_ writer: any DatabaseWriter) throws -> Int? {
        try writer.read { db in
            try #sql("SELECT count(*) FROM review_findings", as: Int.self).fetchOne(db)
        }
    }
}
