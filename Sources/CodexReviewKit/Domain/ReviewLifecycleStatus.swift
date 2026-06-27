import Foundation

public enum ReviewLifecycleStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case incomplete

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .incomplete:
            true
        case .queued, .running:
            false
        }
    }
}
