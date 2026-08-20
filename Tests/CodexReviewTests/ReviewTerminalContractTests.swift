import Foundation
import Testing
@testable import CodexReview
import CodexReviewTesting

@Suite("review terminal contract")
@MainActor
struct ReviewTerminalContractTests {
    @Test func oldLifecycleInitializerKeepsItsExactFunctionReferenceShape() {
        let initializer: (
            ReviewJobState,
            Int?,
            Date?,
            Date?,
            ReviewCancellation?,
            String?
        ) -> ReviewJobCore.Lifecycle = ReviewJobCore.Lifecycle.init(
            status:exitCode:startedAt:endedAt:cancellation:errorMessage:
        )

        let lifecycle = initializer(.failed, 1, nil, nil, nil, "old failure")
        #expect(lifecycle.status == .failed)
        #expect(lifecycle.errorMessage == "old failure")
        #expect(lifecycle.terminal == nil)
    }

    @Test func oldLifecyclePayloadWithoutTerminalDecodesToNil() throws {
        let payload = Data(#"{"status":"succeeded","exitCode":0,"errorMessage":null}"#.utf8)

        let lifecycle = try JSONDecoder().decode(
            ReviewJobCore.Lifecycle.self,
            from: payload
        )

        #expect(lifecycle.status == .succeeded)
        #expect(lifecycle.terminal == nil)
    }

    @Test func lifecycleRejectsNewTerminalAndLegacyStatusMismatch() throws {
        let lifecycle = ReviewJobCore.Lifecycle(
            status: .succeeded,
            terminal: .completed
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(lifecycle)) as? [String: Any]
        )
        object["status"] = ReviewJobState.failed.rawValue
        let mismatched = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ReviewJobCore.Lifecycle.self, from: mismatched)
        }
    }

    @Test func terminalKindsRemainTyped() {
        let cancellation = ReviewCancellation.mcpClient(message: "Stop")
        let values: [ReviewTerminalRecord] = [
            .completed,
            .interrupted(.requested(cancellation)),
            .interrupted(.server(message: nil)),
            .interrupted(.transport(message: "Disconnected")),
            .interrupted(.previousProcessExit),
            .failed(message: nil),
        ]

        #expect(values.map(\.kind) == [
            .completed,
            .interrupted,
            .interrupted,
            .interrupted,
            .interrupted,
            .failed,
        ])
    }

    @Test func explicitCompletedResultCommitsOneTypedTerminal() async throws {
        let (store, backend) = makeStore()
        async let started = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForStartReview()
        await backend.yield(.completed(summary: "Succeeded.", result: "No findings."))

        let result = try await started
        #expect(result.core.lifecycle.status == .succeeded)
        #expect(result.core.lifecycle.terminal == .completed)
        #expect(result.core.reviewText == "No findings.")
        #expect(result.core.output.hasFinalReview)
    }

    @Test func fullMarkerSuppressesTypedAssistantCompanionToOneVisibleFinalRow() async throws {
        let (store, backend) = makeStore()
        async let started = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForStartReview()
        await backend.yield(.logEntry(
            kind: .agentMessage,
            text: "Complete non-final message",
            groupID: "non-final",
            replacesGroup: true
        ))
        await backend.yield(.logEntry(
            kind: .agentMessage,
            text: "Partial final",
            groupID: "assistant-final",
            replacesGroup: true
        ))
        await backend.yield(.logEntry(
            kind: .agentMessage,
            text: "Complete final",
            groupID: "assistant-final",
            replacesGroup: true
        ))
        await backend.yield(.logEntry(
            kind: .agentMessage,
            text: "No findings.",
            groupID: "review-result",
            replacesGroup: true,
            metadata: .init(sourceType: "exitedReviewMode")
        ))
        await backend.yield(.logEntry(
            kind: .agentMessage,
            text: "",
            groupID: "assistant-final",
            replacesGroup: true,
            metadata: .init(sourceType: "suppressedFinalReviewCompanion")
        ))
        await backend.yield(.completed(summary: "Succeeded.", result: "No findings."))

        let result = try await started
        let visibleAgentRows = result.logs.filter { $0.kind == .agentMessage }
        #expect(visibleAgentRows.map(\.groupID) == ["non-final", "review-result"])
        #expect(visibleAgentRows.map(\.text) == ["Complete non-final message", "No findings."])
        #expect(visibleAgentRows.contains { $0.groupID == "assistant-final" } == false)
    }

    @Test func sparseSummaryPromotesItsExistingRowWithoutAppendingAnotherFinalRow() async throws {
        let (store, backend) = makeStore()
        async let started = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForStartReview()
        await backend.yield(.messageDelta("No findings.", itemID: "assistant-final"))
        await backend.yield(.logEntry(
            kind: .agentMessage,
            text: "No findings.",
            groupID: "assistant-final",
            replacesGroup: true,
            metadata: .init(sourceType: "canonicalReviewResult")
        ))
        await backend.yield(.completed(summary: "Succeeded.", result: "No findings."))

        let result = try await started
        let visibleFinalRows = result.logs.filter { $0.kind == .agentMessage }
        #expect(visibleFinalRows.count == 1)
        #expect(visibleFinalRows.first?.groupID == "assistant-final")
        #expect(visibleFinalRows.first?.text == "No findings.")
    }

    @Test func completedWithoutExplicitResultFailsInsteadOfUsingLastMessageOrEOF() async throws {
        let (store, backend) = makeStore()
        async let started = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForStartReview()
        await backend.yield(.message("arbitrary last message"))
        await backend.yield(.completed(summary: "Succeeded.", result: nil))

        let result = try await started
        #expect(result.core.lifecycle.status == .failed)
        #expect(result.core.lifecycle.terminal?.kind == .failed)
        #expect(result.core.lifecycle.errorMessage?.contains("canonical final review") == true)
        #expect(result.core.output.hasFinalReview == false)
        #expect(result.core.reviewText.contains("canonical final review"))
        #expect(result.core.reviewText != "arbitrary last message")
    }

    @Test func streamEOFUsesTypedTransportInterruptionWithoutCanonicalTerminal() async throws {
        let (store, backend) = makeStore()
        async let started = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForStartReview()
        await backend.finishEvents()

        let result = try await started
        #expect(result.core.lifecycle.status == .failed)
        #expect(result.core.lifecycle.terminal?.kind == .interrupted)
        guard case .interrupted(.transport(let message)) = result.core.lifecycle.terminal else {
            Issue.record("Expected a typed transport interruption.")
            return
        }
        #expect(message.contains("authoritative terminal"))
        #expect(result.core.lifecycle.errorMessage?.contains("authoritative terminal") == true)
    }

    @Test func spontaneousInterruptionMapsToLegacyFailedAndRetainsCause() async throws {
        let (store, backend) = makeStore()
        async let started = store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        )
        await backend.waitForStartReview()
        await backend.yield(.cancelled("Server stopped the review"))

        let result = try await started
        #expect(result.core.lifecycle.status == .failed)
        #expect(result.core.lifecycle.cancellation == nil)
        #expect(result.core.lifecycle.terminal == .interrupted(
            .server(message: "Server stopped the review")
        ))
    }

    @Test func requestedInterruptionMapsToLegacyCancelledAndRetainsAuthority() async throws {
        let (store, backend) = makeStore()
        let running = try await store.startReview(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: .zero
        )
        await backend.waitForStartReview()
        let cancellation = ReviewCancellation.mcpClient(message: "Stop")

        try store.completeCancellationLocally(
            jobID: running.jobID,
            sessionID: "session-1",
            cancellation: cancellation
        )
        let result = try store.readReview(sessionID: "session-1", jobID: running.jobID)

        #expect(result.core.lifecycle.status == .cancelled)
        #expect(result.core.lifecycle.terminal == .interrupted(.requested(cancellation)))
        await store.cancelAndDrainReviewWorkersForTesting()
    }

    private func makeStore() -> (CodexReviewStore, FakeCodexReviewBackend) {
        let backend = FakeCodexReviewBackend()
        let storeBackend = TestingCodexReviewStoreBackend(reviewBackend: backend)
        let store = CodexReviewStore.makeTestingStore(
            backend: storeBackend,
            idGenerator: .init(next: { "job-1" })
        )
        return (store, backend)
    }
}
