import Testing
@testable import CodexReview
import CodexReviewMCPServer
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

    @Test func reviewStartConvertsToSystemCommand() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        let server = CodexReviewMCPServer(store: store)

        async let response = server.handle(.reviewStart(
            sessionID: "session-1",
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
            waitTimeout: nil
        ))
        await backend.yield(.completed(summary: "Done", result: "review"))
        let resolved = try await response

        guard case .reviewStart(let read, let timeline) = resolved else {
            Issue.record("Expected reviewStart response")
            return
        }
        #expect(read.jobID == "job-1")
        #expect(read.core.lifecycle.status == .succeeded)
        #expect(timeline.terminalSummary == "Done")
        #expect(timeline.terminalResult == "review")
    }
}
