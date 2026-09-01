import Foundation
import Testing
@testable import CodexReview

@Suite("review history records")
@MainActor
struct ReviewHistoryRecordTests {
    @Test func phaseSpecificRecordsRejectIncompatiblePayloads() throws {
        #expect(throws: ReviewHistoryRecordError.self) {
            try StartedReviewRecord(
                id: "",
                cwd: "/tmp/project",
                workspaceSortOrder: 0,
                sortOrder: 0,
                target: .uncommittedChanges,
                model: nil,
                startedAt: Date(timeIntervalSince1970: 1)
            )
        }

        #expect(throws: ReviewHistoryRecordError.self) {
            try TerminalReviewRecord(
                id: "review-1",
                model: "gpt-5",
                terminal: .completed,
                endedAt: Date(timeIntervalSince1970: 2),
                summary: "Done",
                canonicalReview: nil,
                parsedResult: nil
            )
        }

        #expect(throws: ReviewHistoryRecordError.self) {
            try TerminalReviewRecord(
                id: "review-1",
                model: "gpt-5",
                terminal: .failed(message: "Failed"),
                endedAt: Date(timeIntervalSince1970: 2),
                summary: "Failed",
                canonicalReview: "partial output",
                parsedResult: nil
            )
        }
    }

    @Test func previousProcessExitAcceptsKnownAndUnknownEndButRejectsFinalResult() throws {
        for endedAt in [nil, Date(timeIntervalSince1970: 2)] {
            _ = try TerminalReviewRecord(
                id: "review-1",
                model: "gpt-5",
                terminal: .interrupted(.previousProcessExit),
                endedAt: endedAt,
                summary: "Interrupted",
                canonicalReview: nil,
                parsedResult: nil
            )
        }
        #expect(throws: ReviewHistoryRecordError.self) {
            try TerminalReviewRecord(
                id: "review-1",
                model: "gpt-5",
                terminal: .interrupted(.previousProcessExit),
                endedAt: Date(timeIntervalSince1970: 2),
                summary: "Interrupted",
                canonicalReview: "partial output",
                parsedResult: nil
            )
        }
        #expect(throws: ReviewHistoryRecordError.self) {
            try TerminalReviewRecord(
                id: "review-1",
                model: "gpt-5",
                terminal: .interrupted(.previousProcessExit),
                endedAt: nil,
                summary: "Interrupted",
                canonicalReview: nil,
                parsedResult: PersistedParsedReviewResult(.init(
                    state: .noFindings,
                    findingCount: 0,
                    findings: [],
                    source: .parsedFinalReviewText
                ))
            )
        }
    }

    @Test func restoredSuccessBuildsOneCanonicalDetailWithoutSessionAuthority() throws {
        let startedAt = Date(timeIntervalSince1970: 1)
        let endedAt = Date(timeIntervalSince1970: 2)
        let parsed = ParsedReviewResult.parse(finalReviewText: "No findings.")
        let restored = try RestoredReviewRecord(
            started: StartedReviewRecord(
                id: "review-1",
                cwd: "/tmp/project",
                workspaceSortOrder: 3,
                sortOrder: 4,
                target: .baseBranch("main"),
                model: "gpt-5",
                startedAt: startedAt
            ),
            terminal: TerminalReviewRecord(
                id: "review-1",
                model: "gpt-5",
                terminal: .completed,
                endedAt: endedAt,
                summary: "Done",
                canonicalReview: "No findings.",
                parsedResult: PersistedParsedReviewResult(parsed)
            )
        )

        let job = restored.makeRestoredJob()

        #expect(job.origin == .restoredHistory)
        #expect(job.belongs(toLiveSession: "history:review-1") == false)
        #expect(job.target == .baseBranch("main"))
        #expect(job.core.lifecycle.terminal == .completed)
        #expect(job.core.output.reviewResult == parsed)
        #expect(job.logEntries.count == 1)
        #expect(job.logEntries[0].kind == .agentMessage)
        #expect(job.logEntries[0].text == "No findings.")
        #expect(job.logEntries[0].timestamp == endedAt)
    }

    @Test func previousProcessExitRestoresUnknownEndWithoutLiveTimerState() throws {
        let startedAt = Date(timeIntervalSince1970: 1)
        let restored = try RestoredReviewRecord(
            started: StartedReviewRecord(
                id: "review-1",
                cwd: "/tmp/project",
                workspaceSortOrder: 0,
                sortOrder: 0,
                target: .uncommittedChanges,
                model: nil,
                startedAt: startedAt
            ),
            terminal: TerminalReviewRecord(
                id: "review-1",
                model: nil,
                terminal: .interrupted(.previousProcessExit),
                endedAt: nil,
                summary: "Interrupted",
                canonicalReview: nil,
                parsedResult: nil
            )
        )

        let job = restored.makeRestoredJob()

        #expect(job.core.lifecycle.status == .failed)
        #expect(job.core.lifecycle.endedAt == nil)
        #expect(job.isTerminal)
        #expect(job.logEntries.map(\.kind) == [.error])
        #expect(job.logEntries.first?.timestamp == startedAt)
    }

    @Test func requestedCancellationRestoresTypedTerminalWithoutSyntheticLog() throws {
        let cancellation = ReviewCancellation.mcpClient(message: "Stop review.")
        let restored = try RestoredReviewRecord(
            started: StartedReviewRecord(
                id: "review-1",
                cwd: "/tmp/project",
                workspaceSortOrder: 0,
                sortOrder: 0,
                target: .uncommittedChanges,
                model: nil,
                startedAt: Date(timeIntervalSince1970: 1)
            ),
            terminal: TerminalReviewRecord(
                id: "review-1",
                model: nil,
                terminal: .interrupted(.requested(cancellation)),
                endedAt: Date(timeIntervalSince1970: 2),
                summary: cancellation.message,
                canonicalReview: nil,
                parsedResult: nil
            )
        )

        let job = restored.makeRestoredJob()

        #expect(job.core.lifecycle.terminal == .interrupted(.requested(cancellation)))
        #expect(job.core.lifecycle.cancellation == cancellation)
        #expect(job.logEntries.isEmpty)
        #expect(job.rawLogText.isEmpty)
    }
}
