import Foundation

package enum ReviewHistoryDatabaseError: LocalizedError, Equatable, Sendable {
    case closed
    case foreignKeysDisabled
    case duplicateReview(String)
    case reviewNotFound(String)
    case closeFailed(String)
    case invalidRecord(id: String, reason: String)

    package var errorDescription: String? {
        switch self {
        case .closed:
            "Review history database is closed."
        case .foreignKeysDisabled:
            "Review history database requires SQLite foreign-key enforcement."
        case .duplicateReview(let id):
            "Review history already contains review \(id)."
        case .reviewNotFound(let id):
            "Review history does not contain review \(id)."
        case .closeFailed(let message):
            "Review history database close failed: \(message)"
        case .invalidRecord(let id, let reason):
            "Review history record \(id) is invalid: \(reason)"
        }
    }
}
