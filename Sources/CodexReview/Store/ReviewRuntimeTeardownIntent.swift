import Foundation

package enum ReviewRuntimeTeardownIntent: Equatable, Sendable {
    package enum FinalState: Equatable, Sendable {
        case stopped
        case failed(String)
    }

    case explicitStop
    case unexpectedFailure(String)

    package var reviewCancellation: ReviewCancellation {
        .system(message: message)
    }

    package var finalState: FinalState {
        switch self {
        case .explicitStop:
            .stopped
        case .unexpectedFailure:
            .failed(message)
        }
    }

    package var diagnosticContext: String {
        switch self {
        case .explicitStop:
            "runtime stop"
        case .unexpectedFailure:
            "runtime failure"
        }
    }

    package var cleanupTimeoutWarning: String {
        switch self {
        case .explicitStop:
            "Timed out cleaning active reviews before stopping runtime"
        case .unexpectedFailure:
            "Timed out cleaning active reviews after runtime failure"
        }
    }

    package var supersedesConcurrentFinalState: Bool {
        self == .explicitStop
    }

    private var message: String {
        switch self {
        case .explicitStop:
            "Review runtime stopped."
        case .unexpectedFailure(let errorDescription):
            "Review runtime stopped unexpectedly: \(errorDescription)"
        }
    }
}
