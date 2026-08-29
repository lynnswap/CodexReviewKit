import Foundation
import SQLiteData

@Table("review_workspaces")
struct ReviewWorkspaceRow: Equatable, Sendable {
    @Column(primaryKey: true)
    var cwd: String
    var sortOrder: Double
    var repositoryIdentity: String?
    var displayTitle: String?
    var kind: String?
}

@Table("review_records")
struct ReviewRecordRow: Equatable, Sendable {
    @Column(primaryKey: true)
    var id: String
    var cwd: String
    var sortOrder: Double

    var targetKind: String
    var targetBranch: String?
    var targetCommitSHA: String?
    var targetCommitTitle: String?
    var targetInstructions: String?

    var startedModel: String?
    var startedAt: Double

    var phase: String
    var terminalModel: String?
    var terminalKind: String?
    var interruptionKind: String?
    var cancellationSource: String?
    var cancellationMessage: String?
    var terminalMessage: String?
    var endedAt: Double?
    var summary: String?
    var canonicalReview: String?
    var parsedState: String?
    var parsedFindingCount: Int?
    var parsedSource: String?
    var parserVersion: Int?
    var terminalCommittedAt: Double?

    var createdAt: Double
    var updatedAt: Double
}

@Table("review_findings")
struct ReviewFindingRow: Equatable, Sendable {
    @Column(primaryKey: true)
    var id: String
    var reviewID: String
    var ordinal: Int
    var priority: Int?
    var title: String
    var body: String
    var path: String?
    var startLine: Int?
    var endLine: Int?
}

enum ReviewHistorySchema {
    static func migrate(_ database: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_review_history") { db in
            try #sql(
                """
                CREATE TABLE "review_workspaces" (
                  "cwd" TEXT NOT NULL PRIMARY KEY,
                  "sortOrder" REAL NOT NULL
                ) STRICT
                """
            )
            .execute(db)

            try #sql(
                """
                CREATE TABLE "review_records" (
                  "id" TEXT NOT NULL PRIMARY KEY,
                  "cwd" TEXT NOT NULL REFERENCES "review_workspaces"("cwd") ON DELETE CASCADE,
                  "sortOrder" REAL NOT NULL,

                  "targetKind" TEXT NOT NULL,
                  "targetBranch" TEXT,
                  "targetCommitSHA" TEXT,
                  "targetCommitTitle" TEXT,
                  "targetInstructions" TEXT,

                  "startedModel" TEXT,
                  "startedAt" REAL NOT NULL,

                  "phase" TEXT NOT NULL,
                  "terminalModel" TEXT,
                  "terminalKind" TEXT,
                  "interruptionKind" TEXT,
                  "cancellationSource" TEXT,
                  "cancellationMessage" TEXT,
                  "terminalMessage" TEXT,
                  "endedAt" REAL,
                  "summary" TEXT,
                  "canonicalReview" TEXT,
                  "parsedState" TEXT,
                  "parsedFindingCount" INTEGER,
                  "parsedSource" TEXT,
                  "parserVersion" INTEGER,
                  "terminalCommittedAt" REAL,

                  "createdAt" REAL NOT NULL,
                  "updatedAt" REAL NOT NULL,

                  CHECK (COALESCE(
                    ("targetKind" = 'uncommittedChanges'
                      AND "targetBranch" IS NULL
                      AND "targetCommitSHA" IS NULL
                      AND "targetCommitTitle" IS NULL
                      AND "targetInstructions" IS NULL)
                    OR ("targetKind" = 'baseBranch'
                      AND "targetBranch" IS NOT NULL
                      AND length(trim("targetBranch")) > 0
                      AND "targetCommitSHA" IS NULL
                      AND "targetCommitTitle" IS NULL
                      AND "targetInstructions" IS NULL)
                    OR ("targetKind" = 'commit'
                      AND "targetBranch" IS NULL
                      AND "targetCommitSHA" IS NOT NULL
                      AND length(trim("targetCommitSHA")) > 0
                      AND "targetInstructions" IS NULL)
                    OR ("targetKind" = 'custom'
                      AND "targetBranch" IS NULL
                      AND "targetCommitSHA" IS NULL
                      AND "targetCommitTitle" IS NULL
                      AND "targetInstructions" IS NOT NULL
                      AND length(trim("targetInstructions")) > 0)
                  , 0)),
                  CHECK (COALESCE(
                    ("phase" = 'active'
                      AND "terminalModel" IS NULL
                      AND "terminalKind" IS NULL
                      AND "interruptionKind" IS NULL
                      AND "cancellationSource" IS NULL
                      AND "cancellationMessage" IS NULL
                      AND "terminalMessage" IS NULL
                      AND "endedAt" IS NULL
                      AND "summary" IS NULL
                      AND "canonicalReview" IS NULL
                      AND "parsedState" IS NULL
                      AND "parsedFindingCount" IS NULL
                      AND "parsedSource" IS NULL
                      AND "parserVersion" IS NULL
                      AND "terminalCommittedAt" IS NULL)
                    OR ("phase" = 'terminal'
                      AND "summary" IS NOT NULL
                      AND "terminalCommittedAt" IS NOT NULL
                      AND "terminalKind" IS NOT NULL
                      AND (
                        ("terminalKind" = 'completed'
                          AND "endedAt" IS NOT NULL
                          AND "interruptionKind" IS NULL
                          AND "cancellationSource" IS NULL
                          AND "cancellationMessage" IS NULL
                          AND "terminalMessage" IS NULL
                          AND "canonicalReview" IS NOT NULL
                          AND length(trim("canonicalReview")) > 0
                          AND "parsedState" IS NOT NULL
                          AND "parsedSource" IS NOT NULL
                          AND "parserVersion" IS NOT NULL
                          AND "parserVersion" > 0
                          AND (
                            ("parsedState" = 'hasFindings'
                              AND "parsedFindingCount" > 0
                              AND "parsedSource" = 'parsedFinalReviewText')
                            OR ("parsedState" = 'noFindings'
                              AND "parsedFindingCount" = 0
                              AND "parsedSource" = 'parsedFinalReviewText')
                            OR ("parsedState" = 'unknown'
                              AND "parsedFindingCount" IS NULL
                              AND "parsedSource" IN ('unrecognizedFindingBlock', 'notAvailable'))
                          ))
                        OR ("terminalKind" = 'interrupted'
                          AND "interruptionKind" = 'requested'
                          AND "endedAt" IS NOT NULL
                          AND "cancellationSource" IN
                            ('userInterface', 'mcpClient', 'sessionClosed', 'system')
                          AND "cancellationMessage" IS NOT NULL
                          AND "terminalMessage" IS NULL
                          AND "canonicalReview" IS NULL
                          AND "parsedState" IS NULL
                          AND "parsedFindingCount" IS NULL
                          AND "parsedSource" IS NULL
                          AND "parserVersion" IS NULL)
                        OR ("terminalKind" = 'interrupted'
                          AND "interruptionKind" = 'server'
                          AND "endedAt" IS NOT NULL
                          AND "cancellationSource" IS NULL
                          AND "cancellationMessage" IS NULL
                          AND "canonicalReview" IS NULL
                          AND "parsedState" IS NULL
                          AND "parsedFindingCount" IS NULL
                          AND "parsedSource" IS NULL
                          AND "parserVersion" IS NULL)
                        OR ("terminalKind" = 'interrupted'
                          AND "interruptionKind" = 'transport'
                          AND "endedAt" IS NOT NULL
                          AND "cancellationSource" IS NULL
                          AND "cancellationMessage" IS NULL
                          AND "terminalMessage" IS NOT NULL
                          AND "canonicalReview" IS NULL
                          AND "parsedState" IS NULL
                          AND "parsedFindingCount" IS NULL
                          AND "parsedSource" IS NULL
                          AND "parserVersion" IS NULL)
                        OR ("terminalKind" = 'interrupted'
                          AND "interruptionKind" = 'previousProcessExit'
                          AND "endedAt" IS NULL
                          AND "cancellationSource" IS NULL
                          AND "cancellationMessage" IS NULL
                          AND "terminalMessage" IS NULL
                          AND "canonicalReview" IS NULL
                          AND "parsedState" IS NULL
                          AND "parsedFindingCount" IS NULL
                          AND "parsedSource" IS NULL
                          AND "parserVersion" IS NULL)
                        OR ("terminalKind" = 'failed'
                          AND "endedAt" IS NOT NULL
                          AND "interruptionKind" IS NULL
                          AND "cancellationSource" IS NULL
                          AND "cancellationMessage" IS NULL
                          AND "canonicalReview" IS NULL
                          AND "parsedState" IS NULL
                          AND "parsedFindingCount" IS NULL
                          AND "parsedSource" IS NULL
                          AND "parserVersion" IS NULL)
                      ))
                  , 0))
                ) STRICT
                """
            )
            .execute(db)

            try #sql(
                """
                CREATE TABLE "review_findings" (
                  "id" TEXT NOT NULL PRIMARY KEY,
                  "reviewID" TEXT NOT NULL REFERENCES "review_records"("id") ON DELETE CASCADE,
                  "ordinal" INTEGER NOT NULL CHECK ("ordinal" >= 0),
                  "priority" INTEGER CHECK ("priority" BETWEEN 0 AND 3),
                  "title" TEXT NOT NULL CHECK (length(trim("title")) > 0),
                  "body" TEXT NOT NULL,
                  "path" TEXT,
                  "startLine" INTEGER,
                  "endLine" INTEGER,
                  UNIQUE ("reviewID", "ordinal"),
                  CHECK (COALESCE(
                    ("path" IS NULL AND "startLine" IS NULL AND "endLine" IS NULL)
                    OR ("path" IS NOT NULL
                      AND "startLine" IS NOT NULL
                      AND "endLine" IS NOT NULL
                      AND length(trim("path")) > 0
                      AND "startLine" > 0
                      AND "endLine" >= "startLine")
                  , 0))
                ) STRICT
                """
            )
            .execute(db)

            try #sql(
                """
                CREATE INDEX "review_records_workspace_order"
                ON "review_records" ("cwd", "sortOrder", "id")
                """
            )
            .execute(db)
            try #sql(
                """
                CREATE INDEX "review_records_retention"
                ON "review_records" ("phase", "terminalCommittedAt", "id")
                """
            )
            .execute(db)
        }

        migrator.registerMigration("v2_add_workspace_metadata") { db in
            try #sql(
                """
                ALTER TABLE "review_workspaces"
                ADD COLUMN "repositoryIdentity" TEXT
                """
            )
            .execute(db)
            try #sql(
                """
                ALTER TABLE "review_workspaces"
                ADD COLUMN "displayTitle" TEXT
                """
            )
            .execute(db)
            try #sql(
                """
                ALTER TABLE "review_workspaces"
                ADD COLUMN "kind" TEXT
                CHECK ("kind" IS NULL OR "kind" IN ('directory', 'primaryCheckout', 'linkedWorktree'))
                """
            )
            .execute(db)
        }

        migrator.registerMigration("v3_share_review_order_across_workspaces") { db in
            let workspaceSortOrders = Dictionary(uniqueKeysWithValues:
                try ReviewWorkspaceRow.fetchAll(db).map { ($0.cwd, $0.sortOrder) }
            )
            let orderedReviews = try ReviewRecordRow.fetchAll(db).map { review in
                guard let workspaceSortOrder = workspaceSortOrders[review.cwd] else {
                    throw ReviewHistoryDatabaseError.invalidRecord(
                        id: review.id,
                        reason: "workspace row is missing during review-order migration"
                    )
                }
                return (review: review, workspaceSortOrder: workspaceSortOrder)
            }.sorted { lhs, rhs in
                if lhs.workspaceSortOrder != rhs.workspaceSortOrder {
                    return lhs.workspaceSortOrder > rhs.workspaceSortOrder
                }
                if lhs.review.cwd != rhs.review.cwd {
                    return lhs.review.cwd < rhs.review.cwd
                }
                if lhs.review.sortOrder != rhs.review.sortOrder {
                    return lhs.review.sortOrder > rhs.review.sortOrder
                }
                return lhs.review.id < rhs.review.id
            }
            for (index, value) in orderedReviews.enumerated() {
                let sortOrder = Double(orderedReviews.count - index - 1)
                try ReviewRecordRow.find(value.review.id)
                    .update { $0.sortOrder = #bind(sortOrder) }
                    .execute(db)
            }

            try #sql("DROP INDEX \"review_records_workspace_order\"").execute(db)
            try #sql(
                """
                CREATE INDEX "review_records_order"
                ON "review_records" ("sortOrder", "id")
                """
            )
            .execute(db)
        }

        try migrator.migrate(database)
        let foreignKeysEnabled = try database.read { db in
            try #sql("PRAGMA foreign_keys", as: Int.self).fetchOne(db)
        }
        guard foreignKeysEnabled == 1 else {
            throw ReviewHistoryDatabaseError.foreignKeysDisabled
        }
    }
}
