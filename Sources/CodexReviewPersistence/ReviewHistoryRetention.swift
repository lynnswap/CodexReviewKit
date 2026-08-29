import CodexReview
import Foundation
import SQLiteData

enum ReviewHistoryRetention {
    static func prune(
        in db: Database,
        policy: ReviewHistoryRetentionPolicy
    ) throws -> Set<String> {
        let terminalRows = try ReviewRecordRow.fetchAll(db).filter(\.isTerminal)
        var removedIDs = Set<String>()

        let rowsByWorkspace = Dictionary(grouping: terminalRows, by: \.cwd)
        for cwd in rowsByWorkspace.keys.sorted() {
            guard let rows = rowsByWorkspace[cwd],
                  rows.count > policy.maximumReviewsPerWorkspace
            else {
                continue
            }
            let excess = rows.count - policy.maximumReviewsPerWorkspace
            removedIDs.formUnion(rows.sortedByOldest.prefix(excess).map(\.id))
        }

        let globallyRemaining = terminalRows.filter { removedIDs.contains($0.id) == false }
        if globallyRemaining.count > policy.maximumReviews {
            let excess = globallyRemaining.count - policy.maximumReviews
            removedIDs.formUnion(globallyRemaining.sortedByOldest.prefix(excess).map(\.id))
        }

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
}

private extension ReviewRecordRow {
    var isTerminal: Bool {
        switch status {
        case ReviewJobState.queued.rawValue, ReviewJobState.running.rawValue:
            false
        default:
            true
        }
    }

    var retentionDate: Date {
        endedAt ?? startedAt
    }
}

private extension Array where Element == ReviewRecordRow {
    var sortedByOldest: [ReviewRecordRow] {
        sorted { lhs, rhs in
            if lhs.retentionDate != rhs.retentionDate {
                return lhs.retentionDate < rhs.retentionDate
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }
}
