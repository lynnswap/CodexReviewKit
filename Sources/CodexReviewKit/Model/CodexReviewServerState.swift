package enum CodexReviewServerState: Sendable, Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    package var isRestartAvailable: Bool {
        switch self {
        case .stopped, .starting, .failed:
            true
        case .running:
            false
        }
    }

    package var displayText: String {
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

    package var failureMessage: String? {
        guard case .failed(let message) = self else {
            return nil
        }
        return message
    }
}
