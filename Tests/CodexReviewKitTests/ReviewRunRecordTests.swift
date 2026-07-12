import Foundation
import Testing
@testable import CodexReviewKit

@Suite("Review run core")
@MainActor
struct ReviewRunCoreTests {
    @Test func coreOwnsTypedTerminalFactsWithoutStoredPresentationText() throws {
        let attempt = makeAttempt()
        let startedAt = Date(timeIntervalSince1970: 10)
        let endedAt = Date(timeIntervalSince1970: 20)
        let succeeded = ReviewRunCore.succeeded(
            attempt: attempt,
            startedAt: startedAt,
            endedAt: endedAt
        )
        #expect(succeeded.status == .succeeded)
        #expect(succeeded.failure == nil)

        let failed = ReviewRunCore.failed(
            attempt: attempt,
            startedAt: startedAt,
            endedAt: endedAt,
            failure: .protocolViolation(message: "Backend failed.")
        )
        #expect(failed.status == .failed)
        #expect(failed.failure?.message == "Backend failed.")

        let cancelled = ReviewRunCore.cancelled(
            attempt: attempt,
            startedAt: startedAt,
            endedAt: endedAt,
            cancellation: .mcpClient(message: "Session closed.")
        )
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.cancellation?.message == "Session closed.")

        let encoded = String(decoding: try JSONEncoder().encode(failed), as: UTF8.self)
        #expect(encoded.contains("lifecycleMessage") == false)
        #expect(encoded.contains("errorMessage") == false)
        #expect(encoded.contains("finalReview") == false)
    }

    @Test func attemptIdentityValidationRejectsEmptyAndWhitespaceValues() {
        #expect(throws: ReviewIdentityValidationError.empty(field: "runID")) {
            try ReviewRunID(validating: " \n ")
        }
        #expect(throws: ReviewIdentityValidationError.empty(field: "attemptID")) {
            try ReviewAttemptID(validating: " \n ")
        }
        #expect(throws: ReviewIdentityValidationError.empty(field: "threadID")) {
            try ReviewThreadID(validating: "")
        }
        #expect(throws: ReviewIdentityValidationError.empty(field: "turnID")) {
            try ReviewTurnID(validating: "\t")
        }
    }

    @Test func identityValidationPreservesAcceptedRawValue() throws {
        let rawValue = " attempt-1 "
        #expect(try ReviewAttemptID(validating: rawValue).rawValue == rawValue)
        #expect(try ReviewRunID(validating: rawValue).rawValue == rawValue)
    }

    @Test func identityDecodingUsesTheValidatingInitializer() {
        let data = Data(#""   ""#.utf8)
        #expect(throws: ReviewIdentityValidationError.empty(field: "runID")) {
            try JSONDecoder().decode(ReviewRunID.self, from: data)
        }
        #expect(throws: ReviewIdentityValidationError.empty(field: "attemptID")) {
            try JSONDecoder().decode(ReviewAttemptID.self, from: data)
        }
    }

    @Test func onlyPreAttemptStatesCanOmitAttemptIdentity() {
        let endedAt = Date(timeIntervalSince1970: 20)
        let queued = ReviewRunCore.queued
        let startFailed = ReviewRunCore.startFailed(
            endedAt: endedAt,
            failure: .protocolViolation(message: "Failed.")
        )
        let cancelledBeforeStart = ReviewRunCore.cancelledBeforeStart(
            endedAt: endedAt,
            cancellation: .system(message: "Cancelled.")
        )
        let running = ReviewRunCore.running(
            attempt: makeAttempt(),
            startedAt: Date(timeIntervalSince1970: 10)
        )

        #expect(queued.attempt == nil)
        #expect(startFailed.attempt == nil)
        #expect(cancelledBeforeStart.attempt == nil)
        #expect(running.attempt == makeAttempt())
    }
}

private func makeAttempt() -> ReviewAttempt {
    do {
        return try ReviewAttempt(
            validatingAttemptID: "attempt-1",
            sourceThreadID: "thread-1",
            activeTurnThreadID: "review-thread-1",
            turnID: "turn-1",
            model: "gpt-5"
        )
    } catch {
        preconditionFailure("Invalid explicit review attempt fixture: \(error)")
    }
}
