import Foundation
import Testing
@testable import CodexReviewKit
@testable import CodexReviewMCPServer

@Suite("Review MCP projection")
struct ReviewMCPProjectionTests {
    @Test func runningResultProjectsSummaryAsActiveDiagnosticItem() throws {
        let projection = ReviewMCPProjection(result: .init(
            jobID: "job-1",
            core: .init(
                lifecycle: .init(status: .running),
                output: .init(summary: "Review started.")
            ),
            cancellable: true
        ))

        #expect(projection.orderedItemIDs == ["job-1:summary"])
        #expect(projection.activeItemIDs == ["job-1:summary"])
        #expect(projection.activeItemCount == 1)
        #expect(projection.latestActivityID == "job-1:summary")
        let item = try #require(projection.items.first)
        #expect(item.kind == "diagnostic")
        #expect(item.content.type == "diagnostic")
    }

    @Test func terminalResultProjectsFinalReviewText() throws {
        let projection = ReviewMCPProjection(result: .init(
            jobID: "job-2",
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

        #expect(projection.activeItemIDs == [])
        #expect(projection.activeItemCount == 0)
        #expect(projection.terminalSummary == "Done.")
        #expect(projection.terminalResult == "No findings.")
        let item = try #require(projection.items.first)
        #expect(item.id == "job-2:message")
        #expect(item.kind == "agentMessage")
        #expect(item.content.type == "message")
    }
}
