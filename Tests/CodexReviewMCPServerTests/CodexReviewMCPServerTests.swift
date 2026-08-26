import Testing
@_spi(Testing) @testable import CodexReview
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

        guard case .reviewRead(let read) = resolved else {
            Issue.record("Expected reviewRead response")
            return
        }
        #expect(read.jobID == "job-1")
        #expect(read.core.lifecycle.status == .succeeded)
    }

    @Test func reviewReadDefaultHidesDeveloperLogsWhileAllRetainsThem() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .failed,
            summary: "Failed",
            logEntries: [
                .init(kind: .diagnostic, text: "Product diagnostic"),
                .init(kind: .diagnostic, text: "Developer diagnostic", audience: .developer),
            ]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )
        let server = CodexReviewMCPServer(store: store)

        let defaultResponse = try await server.handle(.reviewRead(
            sessionID: nil,
            jobID: job.id,
            logFilter: .defaultSetting,
            logPage: .default
        ))
        let allResponse = try await server.handle(.reviewRead(
            sessionID: nil,
            jobID: job.id,
            logFilter: .all,
            logPage: .default
        ))

        guard case .reviewRead(let defaultRead) = defaultResponse,
              case .reviewRead(let allRead) = allResponse else {
            Issue.record("Expected reviewRead responses")
            return
        }
        #expect(defaultRead.logs.map(\.audience) == [.product])
        #expect(allRead.logs.map(\.audience) == [.product, .developer])
        #expect(defaultRead.rawLogText == allRead.rawLogText)
    }
}
