import Foundation
import Testing
@testable import CodexReviewKit

@MainActor
@Suite("review observation awaiter")
struct ReviewObservationAwaiterTests {
    @Test func resumesWhenTimelineReachesTerminalState() async throws {
        let timeline = ReviewTimeline()
        timeline.apply(.itemStarted(.init(
            id: "cmd-1",
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(.init(command: "swift test"))
        )))

        let task = Task { @MainActor in
            await ReviewObservationAwaiter.waitUntilTerminal(
                timeline: timeline,
                timeout: .seconds(1)
            )
        }
        await Task.yield()

        timeline.apply(.reviewCompleted(summary: "Done", result: nil))

        let result = await task.value
        #expect(result)
    }

    @Test func resumesWhenTimelineCancellationReachesTerminalState() async throws {
        let timeline = ReviewTimeline()
        timeline.apply(.itemStarted(.init(
            id: "cmd-1",
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(.init(command: "swift test"))
        )))

        let task = Task { @MainActor in
            await ReviewObservationAwaiter.waitUntilTerminal(
                timeline: timeline,
                timeout: .seconds(1)
            )
        }
        await Task.yield()

        timeline.apply(.reviewCancelled("Stop"))

        let result = await task.value
        #expect(result)
    }

    @Test func returnsFalseOnTimeout() async throws {
        let timeline = ReviewTimeline()
        timeline.apply(.itemStarted(.init(
            id: "cmd-1",
            kind: .commandExecution,
            family: .command,
            phase: .running,
            content: .command(.init(command: "swift test"))
        )))

        let result = await ReviewObservationAwaiter.waitUntilTerminal(
            timeline: timeline,
            timeout: .milliseconds(10)
        )

        #expect(result == false)
    }
}
