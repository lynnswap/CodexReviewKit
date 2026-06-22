import Testing
@testable import CodexReviewMCPAdapter
import CodexReviewDomain

@MainActor
@Suite("review MCP projection")
struct ReviewMCPProjectionTests {
    @Test func capturesTimelineRevisionAndActivity() throws {
        let timeline = ReviewTimeline()
        timeline.apply(.itemStarted(.init(
            id: "tool-1",
            kind: .mcpToolCall,
            family: .tool,
            phase: .running,
            content: .toolCall(.init(server: "server", tool: "tool"))
        )))

        let projection = ReviewMCPProjection(timeline: timeline)

        #expect(projection.timelineRevision == timeline.revision)
        #expect(projection.activeItemCount == 1)
        #expect(projection.latestActivityID?.rawValue == "tool-1")
    }
}
