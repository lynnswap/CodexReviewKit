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
            try ReviewHistoryTestSupport.nonCompleted(
                id: "known-process-exit",
                terminal: .interrupted(.previousProcessExit),
                endedAt: ReviewHistoryTestSupport.startedAt.addingTimeInterval(20),
                summary: "The review process exited."
            ),
            try ReviewHistoryTestSupport.nonCompleted(
                id: "unknown-process-exit",
                terminal: .interrupted(.previousProcessExit),
                summary: "The previous review process exited."
            ),
        ]

        for (index, terminal) in terminals.enumerated() {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(
                    id: terminal.id,
                    sortOrder: Double(index)
                ),
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
        #expect(
            byID["known-process-exit"]?.terminal.endedAt
                == ReviewHistoryTestSupport.startedAt.addingTimeInterval(20)
        )
        #expect(byID["unknown-process-exit"]?.terminal.endedAt == nil)
        #expect(byID["completed"]?.terminal.parsedResult?.parserVersion == 7)
        #expect(byID["completed"]?.terminal.parsedResult?.findings.count == 2)
        #expect(byID["completed"]?.terminal.parsedResult?.findings[0].ordinal == 0)
        #expect(byID["completed"]?.terminal.parsedResult?.findings[1].location == nil)
    }

    @Test("round trips the current review-agent finding contract")
    func currentReviewAgentFindingRoundTrip() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        let finalReview = """
        [P0] Restore token validation — AccessGate.swift:3

        Reject a supplied token that does not equal the expected token.

        Overall assessment: this authorization bypass blocks the change.
        """
        let parsedResult = ParsedReviewResult.parse(finalReviewText: finalReview)

        _ = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(id: "current-review-agent"),
            terminal: ReviewHistoryTestSupport.completed(
                id: "current-review-agent",
                finalReview: finalReview,
                parsedResult: parsedResult
            ),
            in: database
        )

        let restored = try #require(
            try await database.load(retentionPolicy: .default).first
        )
        #expect(restored.terminal.parsedResult?.state == .hasFindings)
        #expect(restored.terminal.parsedResult?.parserVersion == ParsedReviewResult.currentParserVersion)
        #expect(restored.terminal.parsedResult?.findings.first?.location == .init(
            path: "AccessGate.swift",
            startLine: 3,
            endLine: 3
        ))
    }

    @Test("upgrades a stale parsed projection from its canonical review")
    func staleParsedResultUpgrade() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        let finalReview = """
        [P0] Restore token validation — AccessGate.swift:3

        Reject a supplied token that does not equal the expected token.
        """
        let staleResult = ParsedReviewResult(
            state: .noFindings,
            findingCount: 0,
            findings: [],
            source: .parsedFinalReviewText,
            parserVersion: 1
        )
        _ = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(id: "stale-parser"),
            terminal: ReviewHistoryTestSupport.completed(
                id: "stale-parser",
                finalReview: finalReview,
                parsedResult: staleResult
            ),
            in: database
        )

        let restored = try #require(
            try await database.load(retentionPolicy: .default).first
        )
        #expect(restored.terminal.parsedResult?.state == .hasFindings)
        #expect(restored.terminal.parsedResult?.parserVersion == ParsedReviewResult.currentParserVersion)
        #expect(restored.terminal.parsedResult?.findings.first?.location == .init(
            path: "AccessGate.swift",
            startLine: 3,
            endLine: 3
        ))

        let persisted = try await writer.read { db in
            (
                parserVersion: try ReviewRecordRow.find("stale-parser")
                    .fetchOne(db)?.parserVersion,
                findings: try ReviewFindingRow
                    .where { $0.reviewID.eq("stale-parser") }
                    .fetchAll(db)
            )
        }
        #expect(persisted.parserVersion == ParsedReviewResult.currentParserVersion)
        #expect(persisted.findings.count == 1)
        #expect(persisted.findings.first?.startLine == 3)
        #expect(persisted.findings.first?.endLine == 3)
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

    @Test("rejects duplicate application-wide order on start insertion")
    func duplicateStartOrder() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(
            id: "first",
            cwd: "/tmp/first",
            sortOrder: 0
        ))

        await #expect(throws: ReviewHistoryDatabaseError.self) {
            try await database.recordStarted(ReviewHistoryTestSupport.started(
                id: "duplicate",
                cwd: "/tmp/duplicate",
                sortOrder: 0
            ))
        }

        let reviewIDs = try await writer.read { db in
            try #sql("SELECT id FROM review_records", as: String.self).fetchAll(db)
        }
        #expect(reviewIDs == ["first"])
    }

    @Test("partial ordering collision rolls back every review update")
    func partialOrderingCollision() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        for (id, sortOrder) in [("first", 1.0), ("second", 0.0)] {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(
                    id: id,
                    cwd: "/tmp/\(id)",
                    sortOrder: sortOrder
                ),
                terminal: ReviewHistoryTestSupport.completed(id: id),
                in: database
            )
        }

        await #expect(throws: ReviewHistoryDatabaseError.self) {
            try await database.saveOrdering(.init(
                workspaces: [],
                reviews: [.init(id: "first", sortOrder: 0)]
            ))
        }

        let restored = try await database.load(retentionPolicy: .default)
        let sortOrders = Dictionary(uniqueKeysWithValues:
            restored.map { ($0.started.id, $0.started.sortOrder) }
        )
        #expect(sortOrders == ["first": 1, "second": 0])
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
                started: ReviewHistoryTestSupport.started(
                    id: id,
                    cwd: "/tmp/a",
                    sortOrder: Double(index)
                ),
                terminal: ReviewHistoryTestSupport.completed(id: id),
                in: database,
                retentionPolicy: policy
            )
            #expect(result.removedReviewIDs == (index == 2 ? ["a-0"] : []))
        }

        for index in 0..<2 {
            let id = "b-\(index)"
            let result = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(
                    id: id,
                    cwd: "/tmp/b",
                    sortOrder: Double(index + 3)
                ),
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
            started: ReviewHistoryTestSupport.started(id: "z-existing", sortOrder: 0),
            terminal: ReviewHistoryTestSupport.completed(id: "z-existing"),
            in: database,
            retentionPolicy: policy
        )
        let result = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(id: "a-current", sortOrder: 1),
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
        for (index, id) in ["c", "a", "b"].enumerated() {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(id: id, sortOrder: Double(index)),
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

    @Test("recording a start preserves current workspace order")
    func startPreservesWorkspaceOrder() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(
            id: "existing",
            cwd: "/tmp/shared",
            workspaceSortOrder: 1,
            sortOrder: 0
        ))
        try await database.saveOrdering(.init(
            workspaces: [.init(cwd: "/tmp/shared", sortOrder: 20)],
            reviews: [.init(id: "existing", sortOrder: 30)]
        ))

        try await database.recordStarted(ReviewHistoryTestSupport.started(
            id: "new-shared",
            cwd: "/tmp/shared",
            workspaceSortOrder: 1,
            sortOrder: 31
        ))
        try await database.recordStarted(ReviewHistoryTestSupport.started(
            id: "new-workspace",
            cwd: "/tmp/new",
            workspaceSortOrder: 40,
            sortOrder: 0
        ))

        let workspaceOrders = try await writer.read { db in
            Dictionary(uniqueKeysWithValues:
                try ReviewWorkspaceRow.fetchAll(db).map { ($0.cwd, $0.sortOrder) }
            )
        }
        let reviewOrders = try await writer.read { db in
            Dictionary(uniqueKeysWithValues:
                try ReviewRecordRow.fetchAll(db).map { ($0.id, $0.sortOrder) }
            )
        }

        #expect(workspaceOrders == ["/tmp/shared": 20, "/tmp/new": 40])
        #expect(reviewOrders == ["existing": 30, "new-shared": 31, "new-workspace": 0])
    }

    @Test("workspace repository metadata survives after a linked worktree is removed")
    func workspaceMetadataRoundTrip() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        let metadata = ReviewWorkspaceMetadata(
            repositoryIdentity: "git-common:/tmp/CodexReviewKit/.git",
            displayTitle: "CodexReviewKit",
            kind: .linkedWorktree
        )
        _ = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(
                id: "removed-worktree",
                cwd: "/tmp/worktrees/73d5/CodexReviewKit",
                workspaceMetadata: metadata
            ),
            terminal: ReviewHistoryTestSupport.completed(id: "removed-worktree"),
            in: database
        )

        let restored = try #require(
            try await database.load(retentionPolicy: .default).first
        )

        #expect(restored.started.workspaceMetadata == metadata)
    }

    @Test("loading v1 history backfills a live linked worktree before it is removed")
    func legacyWorkspaceMetadataBackfill() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexReviewHistoryBackfill-\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("CodexReviewKit", isDirectory: true)
        let commonDirURL = repositoryURL.appendingPathComponent(".git", isDirectory: true)
        let worktreeURL = rootURL
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("825b", isDirectory: true)
            .appendingPathComponent("CodexReviewKit", isDirectory: true)
        let gitDirURL = commonDirURL
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("825b", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirURL, withIntermediateDirectories: true)
        try "gitdir: \(gitDirURL.path)\n".write(
            to: worktreeURL.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "../..\n".write(
            to: gitDirURL.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        let (database, _) = try ReviewHistoryTestSupport.database()
        _ = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(
                id: "legacy-live-worktree",
                cwd: worktreeURL.path,
                workspaceMetadata: nil
            ),
            terminal: ReviewHistoryTestSupport.completed(id: "legacy-live-worktree"),
            in: database
        )

        let backfilled = try #require(
            try await database.load(retentionPolicy: .default).first
        )
        #expect(backfilled.started.workspaceMetadata?.kind == .linkedWorktree)
        #expect(
            backfilled.started.workspaceMetadata?.repositoryIdentity
                == "git-common:\(commonDirURL.path)"
        )

        try FileManager.default.removeItem(at: rootURL)
        let restoredAfterRemoval = try #require(
            try await database.load(retentionPolicy: .default).first
        )
        #expect(restoredAfterRemoval.started.workspaceMetadata == backfilled.started.workspaceMetadata)
    }

    @Test("a new review replaces stale repository metadata at a reused workspace path")
    func workspaceMetadataFollowsCurrentAdmission() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        let oldMetadata = ReviewWorkspaceMetadata(
            repositoryIdentity: "git-common:/tmp/old/.git",
            displayTitle: "Old",
            kind: .primaryCheckout
        )
        let newMetadata = ReviewWorkspaceMetadata(
            repositoryIdentity: "git-common:/tmp/new/.git",
            displayTitle: "New",
            kind: .linkedWorktree
        )
        try await database.recordStarted(ReviewHistoryTestSupport.started(
            id: "old-generation",
            cwd: "/tmp/reused",
            workspaceMetadata: oldMetadata,
            workspaceSortOrder: 20
        ))
        try await database.recordStarted(ReviewHistoryTestSupport.started(
            id: "new-generation",
            cwd: "/tmp/reused",
            workspaceMetadata: newMetadata,
            workspaceSortOrder: 0,
            sortOrder: 1
        ))

        let workspace = try #require(
            try await writer.read { db in
                try ReviewWorkspaceRow.find("/tmp/reused").fetchOne(db)
            }
        )

        #expect(workspace.sortOrder == 20)
        #expect(
            try ReviewHistoryRecordCodec.decodeWorkspaceMetadata(
                workspace,
                reviewID: "new-generation"
            ) == newMetadata
        )
    }

    @Test("round trips a terminal timestamp from a backwards wall clock")
    func backwardsClockRoundTrip() async throws {
        let (database, _) = try ReviewHistoryTestSupport.database()
        let startedAt = Date(timeIntervalSinceReferenceDate: 100.123_456_789)
        let endedAt = Date(timeIntervalSinceReferenceDate: 99.987_654_321)
        _ = try await ReviewHistoryTestSupport.record(
            started: ReviewHistoryTestSupport.started(
                id: "backwards-clock",
                startedAt: startedAt
            ),
            terminal: ReviewHistoryTestSupport.nonCompleted(
                id: "backwards-clock",
                endedAt: endedAt
            ),
            in: database
        )

        let restored = try #require(
            try await database.load(retentionPolicy: .default).first
        )
        #expect(restored.started.startedAt == startedAt)
        #expect(restored.terminal.endedAt == endedAt)
    }

    @Test("terminal-only batch deletes preserve active rows and return exact membership")
    func terminalDeletionSemantics() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(
            id: "active",
            cwd: "/tmp/active",
            sortOrder: 0
        ))
        for (index, id) in ["terminal-1", "terminal-2", "terminal-3"].enumerated() {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(
                    id: id,
                    cwd: "/tmp/terminal",
                    sortOrder: Double(index + 1)
                ),
                terminal: ReviewHistoryTestSupport.completed(id: id),
                in: database
            )
        }

        let result = try await database.deleteTerminalReviews(withIDs: [
            "active",
            "missing",
            "terminal-1",
            "terminal-2",
        ])
        #expect(result.removedReviewIDs == ["terminal-1", "terminal-2"])

        let reviewIDs = try await writer.read { db in
            try #sql("SELECT id FROM review_records ORDER BY id", as: String.self).fetchAll(db)
        }
        let workspaceIDs = try await writer.read { db in
            try #sql("SELECT cwd FROM review_workspaces ORDER BY cwd", as: String.self).fetchAll(db)
        }
        #expect(reviewIDs == ["active", "terminal-3"])
        #expect(workspaceIDs == ["/tmp/active", "/tmp/terminal"])
    }

    @Test("batch deletion rolls back every row when one selected record is invalid")
    func terminalDeletionRollback() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        for (index, id) in ["a", "b"].enumerated() {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(
                    id: id,
                    cwd: "/tmp/\(id)",
                    sortOrder: Double(index)
                ),
                terminal: ReviewHistoryTestSupport.completed(id: id),
                in: database
            )
        }
        try await writer.write { db in
            try #sql(
                """
                UPDATE "review_workspaces"
                SET "repositoryIdentity" = 'incomplete'
                WHERE "cwd" = '/tmp/b'
                """
            )
            .execute(db)
        }

        await #expect(throws: ReviewHistoryDatabaseError.self) {
            _ = try await database.deleteTerminalReviews(withIDs: ["a", "b"])
        }

        let reviewIDs = try await writer.read { db in
            try #sql("SELECT id FROM review_records ORDER BY id", as: String.self).fetchAll(db)
        }
        #expect(reviewIDs == ["a", "b"])
    }

    @Test("delete-all removes only terminal rows and reports every removed ID")
    func deleteAllTerminalReviews() async throws {
        let (database, writer) = try ReviewHistoryTestSupport.database()
        try await database.recordStarted(ReviewHistoryTestSupport.started(
            id: "active",
            sortOrder: 0
        ))
        for (index, id) in ["terminal-1", "terminal-2"].enumerated() {
            _ = try await ReviewHistoryTestSupport.record(
                started: ReviewHistoryTestSupport.started(
                    id: id,
                    cwd: "/tmp/terminal",
                    sortOrder: Double(index + 1)
                ),
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
            _ = try await database.deleteTerminalReviews(withIDs: ["closed"])
        }
        await #expect(throws: ReviewHistoryDatabaseError.closed) {
            _ = try await database.deleteAllTerminalReviews()
        }
    }
}
