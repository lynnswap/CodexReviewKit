import Foundation
import Testing
@testable import CodexReviewDomain

@MainActor
@Suite("review timeline")
struct ReviewTimelineTests {
    @Test func typedIDsPreserveRawValue() throws {
        let id: ReviewTimelineItem.ID = "item-1"
        #expect(id.rawValue == "item-1")
        #expect(ReviewItemKind(rawValue: "futureItem").rawValue == "futureItem")
        #expect(ReviewWireEventKind(rawValue: "future/event").rawValue == "future/event")
    }

    @Test func commandOutputAggregatesIntoSameItemInstance() throws {
        let timeline = ReviewTimeline()
        let itemID: ReviewTimelineItem.ID = "cmd-1"

        timeline.apply(.itemStarted(.init(
            id: itemID,
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(.init(command: "swift test"))
        )))
        let item = try #require(timeline.item(for: itemID))
        let identity = ObjectIdentifier(item)

        timeline.apply(.textDelta(
            itemID: itemID,
            kind: .commandExecution,
            family: .command,
            content: .command(.init(command: "swift test")),
            delta: "first\n"
        ))
        timeline.apply(.textDelta(
            itemID: itemID,
            kind: .commandExecution,
            family: .command,
            content: .command(.init(command: "swift test")),
            delta: "second\n"
        ))

        let updated = try #require(timeline.item(for: itemID))
        #expect(ObjectIdentifier(updated) == identity)
        if case .command(let command) = updated.content {
            #expect(command.output == "first\nsecond\n")
        } else {
            Issue.record("expected command content")
        }
    }

    @Test func terminalEventClearsActiveItems() throws {
        let timeline = ReviewTimeline()
        timeline.apply(.itemStarted(.init(
            id: "tool-1",
            kind: .mcpToolCall,
            family: .tool,
            phase: .running,
            content: .toolCall(.init(server: "server", tool: "tool"))
        )))
        #expect(timeline.activeItemIDs == ["tool-1"])

        timeline.apply(.reviewFailed("failed"))

        #expect(timeline.activeItemIDs.isEmpty)
        #expect(timeline.terminalSummary == "failed")
    }
}
