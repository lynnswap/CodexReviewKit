import Foundation
import SQLiteData

@Table("review_workspaces")
struct ReviewWorkspaceRow: Equatable, Sendable {
    @Column(primaryKey: true)
    var cwd: String
    var sortOrder: Double
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

    var reviewThreadID: String?
    var threadID: String?
    var turnID: String?
    var model: String?

    var status: String
    var exitCode: Int?
    var startedAt: Date
    var endedAt: Date?
    var cancellationSource: String?
    var cancellationMessage: String?
    var terminalKind: String?
    var interruptionKind: String?
    var terminalMessage: String?
    var errorMessage: String?

    var summary: String
    var hasFinalReview: Bool
    var canonicalFinalReview: String?
    var parsedState: String?
    var parsedFindingCount: Int?
    var parsedSource: String?
    var parserVersion: Int?

    var createdAt: Date
    var updatedAt: Date
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

                  "reviewThreadID" TEXT,
                  "threadID" TEXT,
                  "turnID" TEXT,
                  "model" TEXT,

                  "status" TEXT NOT NULL,
                  "exitCode" INTEGER,
                  "startedAt" TEXT NOT NULL,
                  "endedAt" TEXT,
                  "cancellationSource" TEXT,
                  "cancellationMessage" TEXT,
                  "terminalKind" TEXT,
                  "interruptionKind" TEXT,
                  "terminalMessage" TEXT,
                  "errorMessage" TEXT,

                  "summary" TEXT NOT NULL,
                  "hasFinalReview" INTEGER NOT NULL,
                  "canonicalFinalReview" TEXT,
                  "parsedState" TEXT,
                  "parsedFindingCount" INTEGER,
                  "parsedSource" TEXT,
                  "parserVersion" INTEGER,

                  "createdAt" TEXT NOT NULL,
                  "updatedAt" TEXT NOT NULL,

                  CHECK (
                    ("targetKind" = 'uncommittedChanges'
                      AND "targetBranch" IS NULL
                      AND "targetCommitSHA" IS NULL
                      AND "targetCommitTitle" IS NULL
                      AND "targetInstructions" IS NULL)
                    OR ("targetKind" = 'baseBranch'
                      AND length(trim("targetBranch")) > 0
                      AND "targetCommitSHA" IS NULL
                      AND "targetCommitTitle" IS NULL
                      AND "targetInstructions" IS NULL)
                    OR ("targetKind" = 'commit'
                      AND "targetBranch" IS NULL
                      AND length(trim("targetCommitSHA")) > 0
                      AND "targetInstructions" IS NULL)
                    OR ("targetKind" = 'custom'
                      AND "targetBranch" IS NULL
                      AND "targetCommitSHA" IS NULL
                      AND "targetCommitTitle" IS NULL
                      AND length(trim("targetInstructions")) > 0)
                  ),
                  CHECK ("hasFinalReview" IN (0, 1)),
                  CHECK (
                    ("status" IN ('queued', 'running')
                      AND "endedAt" IS NULL
                      AND "cancellationSource" IS NULL
                      AND "cancellationMessage" IS NULL
                      AND "terminalKind" IS NULL
                      AND "interruptionKind" IS NULL
                      AND "terminalMessage" IS NULL
                      AND "hasFinalReview" = 0
                      AND "canonicalFinalReview" IS NULL
                      AND "parsedState" IS NULL
                      AND "parsedFindingCount" IS NULL
                      AND "parsedSource" IS NULL
                      AND "parserVersion" IS NULL)
                    OR ("status" = 'succeeded'
                      AND "endedAt" IS NOT NULL
                      AND "cancellationSource" IS NULL
                      AND "cancellationMessage" IS NULL
                      AND "terminalKind" = 'completed'
                      AND "interruptionKind" IS NULL
                      AND "terminalMessage" IS NULL
                      AND "hasFinalReview" = 1
                      AND length(trim("canonicalFinalReview")) > 0
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
                    OR ("status" = 'cancelled'
                      AND "endedAt" IS NOT NULL
                      AND "cancellationSource" IN ('userInterface', 'mcpClient', 'sessionClosed', 'system')
                      AND length(trim("cancellationMessage")) > 0
                      AND "terminalKind" = 'interrupted'
                      AND "interruptionKind" = 'requested'
                      AND "terminalMessage" IS NULL
                      AND "hasFinalReview" = 0
                      AND "canonicalFinalReview" IS NULL
                      AND "parsedState" IS NULL
                      AND "parsedFindingCount" IS NULL
                      AND "parsedSource" IS NULL
                      AND "parserVersion" IS NULL)
                    OR ("status" = 'failed'
                      AND "cancellationSource" IS NULL
                      AND "cancellationMessage" IS NULL
                      AND "hasFinalReview" = 0
                      AND "canonicalFinalReview" IS NULL
                      AND "parsedState" IS NULL
                      AND "parsedFindingCount" IS NULL
                      AND "parsedSource" IS NULL
                      AND "parserVersion" IS NULL
                      AND (
                        ("terminalKind" = 'failed'
                          AND "endedAt" IS NOT NULL
                          AND "interruptionKind" IS NULL)
                        OR ("terminalKind" = 'interrupted'
                          AND "endedAt" IS NOT NULL
                          AND "interruptionKind" = 'server')
                        OR ("terminalKind" = 'interrupted'
                          AND "endedAt" IS NOT NULL
                          AND "interruptionKind" = 'transport'
                          AND length(trim("terminalMessage")) > 0)
                        OR ("terminalKind" = 'interrupted'
                          AND "endedAt" IS NULL
                          AND "interruptionKind" = 'previousProcessExit'
                          AND "terminalMessage" IS NULL)
                      ))
                  )
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
                  CHECK (
                    ("path" IS NULL AND "startLine" IS NULL AND "endLine" IS NULL)
                    OR (length(trim("path")) > 0
                      AND "startLine" > 0
                      AND "endLine" >= "startLine")
                  )
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
                ON "review_records" ("status", "endedAt", "createdAt", "id")
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
