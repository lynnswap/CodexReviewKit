public enum CodexReviewServerState: Sendable, Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    public var isRestartAvailable: Bool {
        switch self {
        case .stopped, .starting, .failed:
            true
        case .running:
            false
        }
    }

    public var displayText: String {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .failed:
            "Failed"
        }
    }

    public var failureMessage: String? {
        guard case .failed(let message) = self else {
            return nil
        }
        return message
    }
}
