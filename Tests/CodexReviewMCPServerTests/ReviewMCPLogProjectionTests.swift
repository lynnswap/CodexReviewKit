import Foundation
import Testing
@testable import CodexReviewKit
@testable import CodexReviewMCPServer

@Suite("Review MCP log projection")
struct ReviewMCPLogProjectionTests {
    @Test func runningResultProjectsSummaryAsActiveDiagnosticItem() throws {
        let projection = ReviewMCPLogProjection(result: .init(
            runID: "job-1",
            core: .init(
                lifecycle: .init(status: .running),
                output: .init(summary: "Review started.")
            ),
            cancellable: true
        ))

        #expect(projection.orderedEntryIDs == ["job-1:summary"])
        #expect(projection.activeEntryIDs == ["job-1:summary"])
        #expect(projection.activeEntryCount == 1)
        #expect(projection.latestEntryID == "job-1:summary")
        let item = try #require(projection.items.first)
        #expect(item.kind == "diagnostic")
        #expect(item.content.type == "diagnostic")
    }

    @Test func finalResultProjectsFinalReviewText() throws {
        let projection = ReviewMCPLogProjection(result: .init(
            runID: "job-2",
            core: .init(
                lifecycle: .init(status: .succeeded, endedAt: Date(timeIntervalSince1970: 1_234)),
                output: .init(
                    summary: "Done.",
                    hasFinalReview: true,
                    lastAgentMessage: "No findings."
                )
            ),
            cancellable: false
        ))

        #expect(projection.activeEntryIDs == [])
        #expect(projection.activeEntryCount == 0)
        #expect(projection.finalSummary == "Done.")
        #expect(projection.finalResult == "No findings.")
        let item = try #require(projection.items.first)
        #expect(item.id == "job-2:message")
        #expect(item.kind == "agentMessage")
        #expect(item.content.type == "message")
    }
}
