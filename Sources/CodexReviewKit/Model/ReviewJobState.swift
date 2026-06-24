public enum ReviewJobState: String, Codable, Sendable, Hashable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .queued, .running:
            false
        case .succeeded, .failed, .cancelled:
            true
        }
    }

    public var displayText: String {
        switch self {
        case .queued:
            "Queued"
        case .running:
            "Running"
        case .succeeded:
            "Succeeded"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }
}
