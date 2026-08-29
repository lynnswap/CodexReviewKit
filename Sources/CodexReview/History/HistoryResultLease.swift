import Foundation

package struct HistoryResultLease: Hashable, Sendable {
    package let id: UUID
    package let jobID: String

    package init(jobID: String) {
        self.id = UUID()
        self.jobID = jobID
    }
}
