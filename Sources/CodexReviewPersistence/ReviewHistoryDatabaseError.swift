import Foundation

package enum ReviewHistoryDatabaseError: LocalizedError, Equatable, Sendable {
    case closed
    case databaseInUse
    case foreignKeysDisabled
    case duplicateReview(String)
    case reviewNotFound(String)
    case closeFailed(String)
    case ownershipFailed(String)
    case invalidRecord(id: String, reason: String)

    package var errorDescription: String? {
        switch self {
        case .closed:
            "Review history database is closed."
        case .databaseInUse:
            "Review history database is already in use by another ReviewMonitor process."
        case .foreignKeysDisabled:
            "Review history database requires SQLite foreign-key enforcement."
        case .duplicateReview(let id):
            "Review history already contains review \(id)."
        case .reviewNotFound(let id):
            "Review history does not contain review \(id)."
        case .closeFailed(let message):
            "Review history database close failed: \(message)"
        case .ownershipFailed(let message):
            "Review history database ownership failed: \(message)"
        case .invalidRecord(let id, let reason):
            "Review history record \(id) is invalid: \(reason)"
        }
    }
}
