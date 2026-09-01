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
        #expect(workspaceColumns == [
            "cwd",
            "sortOrder",
            "repositoryIdentity",
            "displayTitle",
            "kind",
        ])
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

    @Test("normalizes workspace-local review order into one application-wide lane")
    func globalReviewOrderMigration() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        _ = try await database.load(retentionPolicy: .default)

        let legacyRows: [(id: String, cwd: String, workspaceSortOrder: Double, sortOrder: Double)] = [
            ("primary-first", "/tmp/primary", 1.0, 1.0),
            ("primary-second", "/tmp/primary", 1.0, 0.0),
            ("worktree-first", "/tmp/worktree", 0.0, 1.0),
            ("worktree-second", "/tmp/worktree", 0.0, 0.0),
        ]
        for (index, row) in legacyRows.enumerated() {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(
                    id: row.id,
                    cwd: row.cwd,
                    workspaceSortOrder: row.workspaceSortOrder,
                    sortOrder: Double(legacyRows.count - index - 1)
                ),
                terminal: ReviewHistoryTestSupport.completed(id: row.id),
                in: database
            )
        }

        try await writer.write { db in
            try #sql("DROP INDEX \"review_records_order\"").execute(db)
            try #sql(
                """
                CREATE INDEX "review_records_workspace_order"
                ON "review_records" ("cwd", "sortOrder", "id")
                """
            )
            .execute(db)
            try #sql(
                """
                DELETE FROM "grdb_migrations"
                WHERE "identifier" = 'v3_share_review_order_across_workspaces'
                """
            )
            .execute(db)
            try #sql(
                """
                UPDATE "review_records"
                SET "sortOrder" = CASE "id"
                  WHEN 'primary-first' THEN 1
                  WHEN 'primary-second' THEN 0
                  WHEN 'worktree-first' THEN 1
                  WHEN 'worktree-second' THEN 0
                END
                """
            )
            .execute(db)
        }

        try ReviewHistorySchema.migrate(writer)
        try ReviewHistorySchema.migrate(writer)

        let orderedIDs = try await writer.read { db in
            try #sql(
                """
                SELECT "id"
                FROM "review_records"
                ORDER BY "sortOrder" DESC, "id"
                """,
                as: String.self
            )
            .fetchAll(db)
        }
        #expect(orderedIDs == [
            "primary-first",
            "primary-second",
            "worktree-first",
            "worktree-second",
        ])

        let indexNames = try await writer.read { db in
            try #sql(
                """
                SELECT name
                FROM pragma_index_list('review_records')
                WHERE name LIKE 'review_records_%'
                ORDER BY name
                """,
                as: String.self
            )
            .fetchAll(db)
        }
        #expect(indexNames == [
            "review_records_order",
            "review_records_retention",
        ])
    }

    @Test("allows known process-exit time without losing v3 records or findings")
    func previousProcessExitEndTimeMigration() async throws {
        let writer = try DatabaseQueue()
        try ReviewHistorySchema.makeMigrator().migrate(
            writer,
            upTo: "v3_share_review_order_across_workspaces"
        )
        try await writer.write { db in
            try #sql(
                """
                INSERT INTO "review_workspaces" (
                  "cwd", "sortOrder", "repositoryIdentity", "displayTitle", "kind"
                ) VALUES (
                  '/tmp/migration', 4,
                  'git-common:/tmp/migration/.git', 'Migration Fixture', 'primaryCheckout'
                )
                """
            )
            .execute(db)
            try #sql(
                """
                INSERT INTO "review_records" (
                  "id", "cwd", "sortOrder",
                  "targetKind", "targetBranch", "targetCommitSHA", "targetCommitTitle",
                  "targetInstructions", "startedModel", "startedAt", "phase",
                  "terminalModel", "terminalKind", "interruptionKind",
                  "cancellationSource", "cancellationMessage", "terminalMessage", "endedAt",
                  "summary", "canonicalReview", "parsedState", "parsedFindingCount",
                  "parsedSource", "parserVersion", "terminalCommittedAt", "createdAt", "updatedAt"
                ) VALUES
                  (
                    'completed', '/tmp/migration', 3,
                    'commit', NULL, 'abc123', 'Preserve migration state',
                    NULL, 'started-model', 10, 'terminal',
                    'terminal-model', 'completed', NULL,
                    NULL, NULL, NULL, 20,
                    'Done', 'Review finding.', 'hasFindings', 1,
                    'parsedFinalReviewText', 1, 30, 10, 30
                  ),
                  (
                    'unknown-process-exit', '/tmp/migration', 2,
                    'uncommittedChanges', NULL, NULL, NULL,
                    NULL, 'started-model', 11, 'terminal',
                    'terminal-model', 'interrupted', 'previousProcessExit',
                    NULL, NULL, NULL, NULL,
                    'Interrupted', NULL, NULL, NULL,
                    NULL, NULL, 31, 11, 31
                  ),
                  (
                    'active', '/tmp/migration', 1,
                    'baseBranch', 'main', NULL, NULL,
                    NULL, 'started-model', 12, 'active',
                    NULL, NULL, NULL,
                    NULL, NULL, NULL, NULL,
                    NULL, NULL, NULL, NULL,
                    NULL, NULL, NULL, 12, 12
                  )
                """
            )
            .execute(db)
            try #sql(
                """
                INSERT INTO "review_findings" (
                  "id", "reviewID", "ordinal", "priority", "title", "body",
                  "path", "startLine", "endLine"
                ) VALUES (
                  'finding-1', 'completed', 0, 2, 'Preserve this finding',
                  'The migration must not rebuild the child table.',
                  'Sources/Store.swift', 10, 12
                )
                """
            )
            .execute(db)
        }

        let recordsBefore = try await writer.read { db in
            try ReviewRecordRow.fetchAll(db).sorted { $0.id < $1.id }
        }
        let findingsBefore = try await writer.read { db in
            try ReviewFindingRow.fetchAll(db).sorted { $0.id < $1.id }
        }

        try ReviewHistorySchema.migrate(writer)
        try ReviewHistorySchema.migrate(writer)

        let recordsAfter = try await writer.read { db in
            try ReviewRecordRow.fetchAll(db).sorted { $0.id < $1.id }
        }
        let findingsAfter = try await writer.read { db in
            try ReviewFindingRow.fetchAll(db).sorted { $0.id < $1.id }
        }
        #expect(recordsAfter == recordsBefore)
        #expect(findingsAfter == findingsBefore)

        try await writer.write { db in
            try #sql(
                """
                UPDATE "review_records"
                SET "endedAt" = 60
                WHERE "id" = 'unknown-process-exit'
                """
            )
            .execute(db)
        }
        await #expect(throws: (any Error).self) {
            try await writer.write { db in
                try #sql(
                    """
                    UPDATE "review_records"
                    SET "endedAt" = 60
                    WHERE "id" = 'active'
                    """
                )
                .execute(db)
            }
        }

        let integrity = try await writer.read { db in
            let foreignKeyViolations = try #sql(
                "SELECT count(*) FROM pragma_foreign_key_check",
                as: Int.self
            )
            .fetchOne(db)
            let findingParent = try #sql(
                "SELECT \"table\" FROM pragma_foreign_key_list('review_findings')",
                as: String.self
            )
            .fetchOne(db)
            let temporaryTableCount = try #sql(
                "SELECT count(*) FROM pragma_table_list WHERE name = 'review_records_v4'",
                as: Int.self
            )
            .fetchOne(db)
            let strict = try #sql(
                "SELECT strict FROM pragma_table_list WHERE name = 'review_records'",
                as: Int.self
            )
            .fetchOne(db)
            let indexes = try #sql(
                """
                SELECT name
                FROM pragma_index_list('review_records')
                WHERE name LIKE 'review_records_%'
                ORDER BY name
                """,
                as: String.self
            )
            .fetchAll(db)
            return (foreignKeyViolations, findingParent, temporaryTableCount, strict, indexes)
        }
        #expect(integrity.0 == 0)
        #expect(integrity.1 == "review_records")
        #expect(integrity.2 == 0)
        #expect(integrity.3 == 1)
        #expect(integrity.4 == ["review_records_order", "review_records_retention"])
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
        for (index, id) in validActiveIDs.enumerated() {
            try await database.recordStarted(ReviewHistoryTestSupport.started(
                id: id,
                sortOrder: Double(index)
            ))
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
        _ = try await database.deleteTerminalReviews(withIDs: ["cascade"])
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
        for (id, cwd, workspaceSortOrder, sortOrder) in [
            ("file-primary", "/tmp/file-primary", 1.0, 1.0),
            ("file-worktree", "/tmp/file-worktree", 0.0, 0.0),
        ] {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(
                    id: id,
                    cwd: cwd,
                    workspaceSortOrder: workspaceSortOrder,
                    sortOrder: sortOrder
                ),
                terminal: ReviewHistoryTestSupport.completed(id: id),
                in: first
            )
        }
        try await first.saveOrdering(.init(
            workspaces: [],
            reviews: [
                .init(id: "file-primary", sortOrder: 0),
                .init(id: "file-worktree", sortOrder: 1),
            ]
        ))
        try await first.close()

        let second = ReviewHistoryDatabase(databaseURL: url)
        let restored = try await second.load(retentionPolicy: .default)
        #expect(restored.sorted {
            $0.started.sortOrder > $1.started.sortOrder
        }.map(\.started.id) == [
            "file-worktree",
            "file-primary",
        ])
        #expect(restored.first(where: { $0.started.id == "file-primary" })?.started.cwd
            == "/tmp/file-primary")
        #expect(restored.first(where: { $0.started.id == "file-worktree" })?.started.cwd
            == "/tmp/file-worktree")
        try await second.close()
    }

    @Test("preserves a known process-exit time across a file-backed relaunch")
    func knownProcessExitFileRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "CodexReviewKnownProcessExitTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "review-history.sqlite")
        let endedAt = ReviewHistoryTestSupport.startedAt.addingTimeInterval(20)

        let first = ReviewHistoryDatabase(databaseURL: url)
        _ = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(id: "known-process-exit"),
            terminal: ReviewHistoryTestSupport.nonCompleted(
                id: "known-process-exit",
                terminal: .interrupted(.previousProcessExit),
                endedAt: endedAt,
                summary: "The review process exited."
            ),
            in: first
        )
        try await first.close()

        let second = ReviewHistoryDatabase(databaseURL: url)
        let restored = try #require(
            try await second.load(retentionPolicy: .default).first
        )
        #expect(restored.terminal.terminal == .interrupted(.previousProcessExit))
        #expect(restored.terminal.endedAt == endedAt)
        try await second.close()
    }

    @Test("URL owner excludes a second live database without orphaning its active review")
    func temporaryFileOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "CodexReviewHistoryOwnershipTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "review-history.sqlite")
        let started = try ReviewHistoryTestSupport.started(id: "live-review")

        let first = ReviewHistoryDatabase(databaseURL: url)
        try await first.recordStarted(started)
        let second = ReviewHistoryDatabase(databaseURL: url)
        await #expect(throws: ReviewHistoryDatabaseError.databaseInUse) {
            _ = try await second.load(retentionPolicy: .default)
        }

        _ = try await first.recordTerminal(
            ReviewHistoryTestSupport.completed(id: started.id),
            retentionPolicy: .default
        )
        try await first.close()
        try await second.close()

        let successor = ReviewHistoryDatabase(databaseURL: url)
        let restored = try await successor.load(retentionPolicy: .default)
        #expect(restored.map(\.started.id) == [started.id])
        #expect(restored.first?.terminal.terminal == .completed)
        try await successor.close()
    }

    private func findingCount(_ writer: any DatabaseWriter) throws -> Int? {
        try writer.read { db in
            try #sql("SELECT count(*) FROM review_findings", as: Int.self).fetchOne(db)
        }
    }
}
