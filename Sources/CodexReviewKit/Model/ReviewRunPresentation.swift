import Foundation

package enum ReviewExecutionPhase: Equatable, Sendable {
    case starting
    case running(attemptGeneration: UInt64)
    case preparingRestart
    case waitingForNetwork(since: Date)
    case restarting
    case cancelling(ReviewCancellation)
}

package enum ReviewLifecyclePresentation: Codable, Hashable, Sendable {
    case queued
    case starting
    case running
    case waitingForNetwork(since: Date)
    case preparingRestart
    case restarting
    case cancelling(ReviewCancellation)
    case succeeded
    case failed(ReviewBackendFailure)
    case cancelled(ReviewCancellation)

    package var message: String {
        switch self {
        case .queued:
            "Queued."
        case .starting:
            "Starting review."
        case .running:
            "Review started."
        case .waitingForNetwork:
            "Network unavailable; waiting to reconnect."
        case .preparingRestart:
            "Preparing review restart."
        case .restarting:
            "Network restored; restarting review."
        case .cancelling(let cancellation), .cancelled(let cancellation):
            cancellation.message
        case .succeeded:
            "Review completed."
        case .failed(let failure):
            failure.message
        }
    }
}

package struct ReviewRunPresentation: Codable, Hashable, Sendable {
    package let status: ReviewRunState
    package let lifecycle: ReviewLifecyclePresentation
    package let isCancellable: Bool

    package init(core: ReviewRunCore, executionPhase: ReviewExecutionPhase?) {
        status = core.status
        switch (core, executionPhase) {
        case (.queued, .some(.starting)):
            lifecycle = .starting
            isCancellable = true
        case (.queued, .some(.cancelling(let cancellation))):
            lifecycle = .cancelling(cancellation)
            isCancellable = false
        case (.queued, nil):
            lifecycle = .queued
            isCancellable = true
        case (.running, .some(.running)):
            lifecycle = .running
            isCancellable = true
        case (.running, .some(.preparingRestart)):
            lifecycle = .preparingRestart
            isCancellable = true
        case (.running, .some(.waitingForNetwork(let since))):
            lifecycle = .waitingForNetwork(since: since)
            isCancellable = true
        case (.running, .some(.restarting)):
            lifecycle = .restarting
            isCancellable = true
        case (.running, .some(.cancelling(let cancellation))):
            lifecycle = .cancelling(cancellation)
            isCancellable = false
        case (.succeeded, nil):
            lifecycle = .succeeded
            isCancellable = false
        case (.startFailed(_, let failure), nil), (.failed(_, _, _, let failure), nil):
            lifecycle = .failed(failure)
            isCancellable = false
        case (.cancelledBeforeStart(_, let cancellation), nil),
            (.cancelled(_, _, _, let cancellation), nil):
            lifecycle = .cancelled(cancellation)
            isCancellable = false
        default:
            preconditionFailure("Invalid review core and execution phase product.")
        }
    }
}
