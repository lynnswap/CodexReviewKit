import CodexReview
import Foundation
import SQLiteData

enum ReviewHistoryRetention {
    static func prune(
        in db: Database,
        policy: ReviewHistoryRetentionPolicy,
        protecting protectedReviewID: String?
    ) throws -> Set<String> {
        let terminalRows = try ReviewRecordRow.fetchAll(db).filter {
            $0.phase == "terminal"
        }
        for row in terminalRows where row.terminalCommittedAt == nil {
            throw ReviewHistoryDatabaseError.invalidRecord(
                id: row.id,
                reason: "terminal row is missing its retention timestamp"
            )
        }

        var removedIDs = Set<String>()
        let rowsByWorkspace = Dictionary(grouping: terminalRows, by: \.cwd)
        for cwd in rowsByWorkspace.keys.sorted() {
            guard let rows = rowsByWorkspace[cwd] else {
                continue
            }
            removedIDs.formUnion(removals(
                from: rows,
                maximumCount: policy.maximumReviewsPerWorkspace,
                protecting: protectedReviewID
            ))
        }

        let globallyRemaining = terminalRows.filter { removedIDs.contains($0.id) == false }
        removedIDs.formUnion(removals(
            from: globallyRemaining,
            maximumCount: policy.maximumReviews,
            protecting: protectedReviewID
        ))

        for id in removedIDs.sorted() {
            try ReviewRecordRow.find(id).delete().execute(db)
            guard db.changesCount == 1 else {
                throw ReviewHistoryDatabaseError.reviewNotFound(id)
            }
        }
        return removedIDs
    }

    static func deleteEmptyWorkspaces(in db: Database) throws {
        let referencedCWDs = Set(try ReviewRecordRow.fetchAll(db).map(\.cwd))
        for workspace in try ReviewWorkspaceRow.fetchAll(db)
        where referencedCWDs.contains(workspace.cwd) == false {
            try ReviewWorkspaceRow.find(workspace.cwd).delete().execute(db)
        }
    }

    private static func removals(
        from rows: [ReviewRecordRow],
        maximumCount: Int,
        protecting protectedReviewID: String?
    ) -> Set<String> {
        let excess = max(0, rows.count - maximumCount)
        guard excess > 0 else {
            return []
        }
        return Set(
            rows.sortedByOldest
                .lazy
                .filter { $0.id != protectedReviewID }
                .prefix(excess)
                .map(\.id)
        )
    }
}

private extension Array where Element == ReviewRecordRow {
    var sortedByOldest: [ReviewRecordRow] {
        sorted { lhs, rhs in
            guard let lhsCommittedAt = lhs.terminalCommittedAt,
                  let rhsCommittedAt = rhs.terminalCommittedAt
            else {
                return lhs.id < rhs.id
            }
            if lhsCommittedAt != rhsCommittedAt {
                return lhsCommittedAt < rhsCommittedAt
            }
            return lhs.id < rhs.id
        }
    }
}
