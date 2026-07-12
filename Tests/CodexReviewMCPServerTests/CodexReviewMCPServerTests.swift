import Foundation
import Testing
import MCP
import CodexDataKit
@testable import CodexReviewKit
@testable import CodexReviewMCPServer
import CodexReviewTesting

@Suite("MCP server adapter")
@MainActor
struct CodexReviewMCPServerTests {
    @Test func exposesExpectedReviewTools() {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let server = CodexReviewMCPServer(store: store)

        #expect(server.tools.map(\.name) == [
            .reviewStart,
            .reviewAwait,
            .reviewRead,
            .reviewList,
            .reviewCancel,
        ])
    }

    @Test func reviewRunArgumentRejectsEmptyAndWhitespaceIDs() {
        for rawValue in ["", " \n\t "] {
            do {
                _ = try ReviewRunIDArgument.requiredValue(in: ["runId": .string(rawValue)])
                Issue.record("Expected invalid run ID \(rawValue.debugDescription)")
            } catch {
                #expect(error.localizedDescription == "runId must not be empty.")
            }
        }
    }

    @Test func reviewStartConvertsToSystemCommand() async throws {
        let attempt = makeReviewAttemptForTesting(
            attemptID: "attempt-review-start",
            sourceThreadID: "thread-review-start",
            activeTurnThreadID: "review-thread-review-start",
            turnID: "turn-1"
        )
        let backend = FakeCodexReviewBackend(plannedAttempt: attempt)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "run-1" })
        )
        let server = CodexReviewMCPServer(
            store: store,
            logProjectionProvider: { result in
                .available(ReviewMCPLogProjection(
                    result: result,
                    turnID: "turn-1",
                    threadItems: [],
                    reviewOutputText: "No issues found."
                ))
            }
        )

        async let response = server.handle(.reviewStart(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: nil
        ))
        await backend.yield(.completed(finalReview: "No issues found."), for: attempt)
        let resolved = try await response

        guard case .reviewStart(let snapshot) = resolved else {
            Issue.record("Expected reviewStart response")
            return
        }
        let read = snapshot.result
        let log = snapshot.log
        #expect(read.runID.rawValue == "run-1")
        #expect(read.presentation.status == .succeeded)
        #expect(log.finalLifecycleMessage == "Review completed.")
        #expect(log.finalResult == "No issues found.")
        #expect(log.items.isEmpty)
    }

    @Test func succeededRunRejectsUnavailableProjection() async throws {
        let runID = try ReviewRunID(validating: "run-succeeded")
        let store = succeededStore(runID: runID)
        let server = CodexReviewMCPServer(store: store)

        await #expect(throws: ReviewMCPError.projectionInvariantViolation(runID: runID)) {
            _ = try await server.handle(.reviewRead(sessionID: nil, runID: runID))
        }
    }

    @Test func succeededRunRejectsEmptyAndMismatchedProjection() async throws {
        let runID = try ReviewRunID(validating: "run-succeeded")
        let store = succeededStore(runID: runID)
        let emptyServer = CodexReviewMCPServer(
            store: store,
            logProjectionProvider: { result in
                .available(ReviewMCPLogProjection(
                    result: result,
                    turnID: "turn-1",
                    threadItems: [],
                    reviewOutputText: nil
                ))
            }
        )
        await #expect(throws: ReviewMCPError.projectionInvariantViolation(runID: runID)) {
            _ = try await emptyServer.handle(.reviewRead(sessionID: nil, runID: runID))
        }

        let mismatchedServer = CodexReviewMCPServer(
            store: store,
            logProjectionProvider: { result in
                .available(ReviewMCPLogProjection(
                    result: result,
                    turnID: "other-turn",
                    threadItems: [],
                    reviewOutputText: "No issues found."
                ))
            }
        )
        await #expect(throws: ReviewMCPError.projectionInvariantViolation(runID: runID)) {
            _ = try await mismatchedServer.handle(.reviewRead(sessionID: nil, runID: runID))
        }
    }

    @Test func projectionRefreshFailureRemainsTyped() async throws {
        let runID = try ReviewRunID(validating: "run-succeeded")
        let failure = CodexFetchFailure.validation(.negativeFetchLimit(-1))
        let server = CodexReviewMCPServer(
            store: succeededStore(runID: runID),
            logProjectionProvider: { _ in .refreshFailed(failure) }
        )

        await #expect(throws: ReviewMCPError.projectionRefreshFailed(runID: runID, failure: failure)) {
            _ = try await server.handle(.reviewRead(sessionID: nil, runID: runID))
        }
    }

    private func succeededStore(runID: ReviewRunID) -> CodexReviewStore {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )
        store.loadForTesting(
            serverState: .running,
            reviewRuns: [
                .makeForTesting(
                    id: runID.rawValue,
                    targetSummary: "Completed",
                    attemptID: "attempt-1",
                    threadID: "thread-1",
                    turnID: "turn-1",
                    status: .succeeded,
                    startedAt: Date(timeIntervalSince1970: 1_000),
                    endedAt: Date(timeIntervalSince1970: 1_001),
                    summary: "Done"
                )
            ]
        )
        return store
    }
}
