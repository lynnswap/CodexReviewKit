import Foundation

extension ReviewRunRecord {
    package static func makeForTesting(
        id: String = UUID().uuidString,
        sessionID: String = "session-1",
        cwd: String = "/tmp/repo",
        targetSummary: String,
        model: String? = "gpt-5",
        attemptID: String? = nil,
        threadID: String? = nil,
        reviewThreadID: String? = nil,
        turnID: String? = nil,
        status: ReviewRunState,
        cancellationRequested: Bool = false,
        cancellation: ReviewCancellation? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        summary: String,
        errorMessage: String? = nil,
        failure: ReviewBackendFailure? = nil,
        exitCode: Int? = nil
    ) -> ReviewRunRecord {
        let attempt = makeTestingAttempt(
            attemptID: attemptID,
            threadID: threadID,
            reviewThreadID: reviewThreadID,
            turnID: turnID,
            model: model
        )
        let core: ReviewRunCore
        switch status {
        case .queued:
            precondition(attempt == nil, "A queued test review cannot have an attempt.")
            core = .queued
        case .running:
            guard let attempt, let startedAt else {
                preconditionFailure("A running test review requires an attempt and startedAt.")
            }
            core = .running(attempt: attempt, startedAt: startedAt)
        case .succeeded:
            guard let attempt, let startedAt, let endedAt else {
                preconditionFailure("A succeeded test review requires an attempt, startedAt, and endedAt.")
            }
            core = .succeeded(attempt: attempt, startedAt: startedAt, endedAt: endedAt)
        case .failed:
            let resolvedFailure = failure ?? .protocolViolation(message: errorMessage ?? summary)
            guard let endedAt else {
                preconditionFailure("A failed test review requires endedAt.")
            }
            if let attempt {
                guard let startedAt else {
                    preconditionFailure("A failed test review attempt requires startedAt.")
                }
                core = .failed(
                    attempt: attempt,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    failure: resolvedFailure
                )
            } else {
                core = .startFailed(endedAt: endedAt, failure: resolvedFailure)
            }
        case .cancelled:
            let resolvedCancellation = cancellation ?? .system(message: summary)
            guard let endedAt else {
                preconditionFailure("A cancelled test review requires endedAt.")
            }
            if let attempt {
                guard let startedAt else {
                    preconditionFailure("A cancelled test review attempt requires startedAt.")
                }
                core = .cancelled(
                    attempt: attempt,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    cancellation: resolvedCancellation
                )
            } else {
                core = .cancelledBeforeStart(
                    endedAt: endedAt,
                    cancellation: resolvedCancellation
                )
            }
        }

        return ReviewRunRecord(
            id: makeTestingRunID(id),
            sessionID: sessionID,
            cwd: cwd,
            targetSummary: targetSummary,
            core: core,
            executionPhase: status == .queued ? .starting : (status == .running ? .running(attemptGeneration: 0) : nil),
            cancellationRequested: cancellationRequested,
            pendingCancellation: cancellationRequested ? cancellation : nil
        )
    }

    private static func makeTestingRunID(_ rawValue: String) -> ReviewRunID {
        do {
            return try ReviewRunID(validating: rawValue)
        } catch {
            preconditionFailure("Invalid explicit review run ID fixture: \(error)")
        }
    }

    package func updateStateForTesting(
        targetSummary: String? = nil,
        status: ReviewRunState? = nil,
        endedAt: Date? = nil,
        clearEndedAt: Bool = false,
        summary: String? = nil
    ) {
        if let targetSummary {
            self.targetSummary = targetSummary
        }
        if let status {
            core = testingState(
                status: status,
                endedAt: endedAt,
                clearEndedAt: clearEndedAt
            )
        }
        _ = summary
    }

    private func testingState(
        status: ReviewRunState,
        endedAt: Date?,
        clearEndedAt: Bool
    ) -> ReviewRunCore {
        let resolvedEndedAt = clearEndedAt ? nil : (endedAt ?? core.endedAt)
        switch status {
        case .queued:
            return .queued
        case .running:
            guard let attempt = core.attempt, let startedAt = core.startedAt else {
                preconditionFailure("A running test review requires an existing attempt.")
            }
            return .running(attempt: attempt, startedAt: startedAt)
        case .succeeded:
            guard let attempt = core.attempt,
                let startedAt = core.startedAt,
                let resolvedEndedAt
            else {
                preconditionFailure("A succeeded test review requires an attempt and timestamps.")
            }
            return .succeeded(attempt: attempt, startedAt: startedAt, endedAt: resolvedEndedAt)
        case .failed:
            let failure = core.failure ?? .protocolViolation(message: "Testing review failed.")
            guard let resolvedEndedAt else {
                preconditionFailure("A failed test review requires endedAt.")
            }
                if let attempt = core.attempt, let startedAt = core.startedAt {
                return .failed(
                    attempt: attempt,
                    startedAt: startedAt,
                    endedAt: resolvedEndedAt,
                    failure: failure
                )
            }
            return .startFailed(endedAt: resolvedEndedAt, failure: failure)
        case .cancelled:
            let cancellation = core.cancellation ?? .system(message: "Testing review cancelled.")
            guard let resolvedEndedAt else {
                preconditionFailure("A cancelled test review requires endedAt.")
            }
                if let attempt = core.attempt, let startedAt = core.startedAt {
                return .cancelled(
                    attempt: attempt,
                    startedAt: startedAt,
                    endedAt: resolvedEndedAt,
                    cancellation: cancellation
                )
            }
            return .cancelledBeforeStart(
                endedAt: resolvedEndedAt,
                cancellation: cancellation
            )
        }
    }
}

private func makeTestingAttempt(
    attemptID: String?,
    threadID: String?,
    reviewThreadID: String?,
    turnID: String?,
    model: String?
) -> ReviewAttempt? {
    let suppliedValues = [attemptID, threadID, turnID].compactMap { $0 }
    guard suppliedValues.isEmpty == false else {
        return nil
    }
    guard let attemptID, let threadID, let turnID else {
        preconditionFailure("A test review attempt requires attemptID, threadID, and turnID together.")
    }
    do {
        return try ReviewAttempt(
            validatingAttemptID: attemptID,
            sourceThreadID: threadID,
            activeTurnThreadID: reviewThreadID ?? threadID,
            turnID: turnID,
            model: model
        )
    } catch {
        preconditionFailure("Invalid test review attempt: \(error)")
    }
}
