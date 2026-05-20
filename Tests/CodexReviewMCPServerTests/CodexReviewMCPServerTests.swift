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
            request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
        ))
        await backend.waitForEventStream()
        await backend.yield(.completed(summary: "Done", result: "review"))
        let resolved = try await response

        guard case .reviewRead(let read) = resolved else {
            Issue.record("Expected reviewRead response")
            return
        }
        #expect(read.jobID == "job-1")
        #expect(read.core.lifecycle.status == .succeeded)
    }
}
