import Foundation
import Testing
@testable import CodexReviewKit

@MainActor
@Suite("review observation awaiter")
struct ReviewObservationAwaiterTests {
    @Test func resumesWhenRunReachesTerminalState() async throws {
        let run = makeRunningRun()

        let task = Task { @MainActor in
            await ReviewObservationAwaiter.waitUntilTerminal(
                run: run,
                timeout: .seconds(1)
            )
        }
        await Task.yield()

        run.updateStateForTesting(status: .succeeded, summary: "Done")

        let result = await task.value
        #expect(result)
    }

    @Test func resumesWhenRunCancellationReachesTerminalState() async throws {
        let run = makeRunningRun()

        let task = Task { @MainActor in
            await ReviewObservationAwaiter.waitUntilTerminal(
                run: run,
                timeout: .seconds(1)
            )
        }
        await Task.yield()

        run.updateStateForTesting(status: .cancelled, summary: "Stop")

        let result = await task.value
        #expect(result)
    }

    @Test func returnsFalseOnTimeout() async throws {
        let run = makeRunningRun()

        let result = await ReviewObservationAwaiter.waitUntilTerminal(
            run: run,
            timeout: .milliseconds(10)
        )

        #expect(result == false)
    }

    private func makeRunningRun() -> ReviewRunRecord {
        ReviewRunRecord.makeForTesting(
            id: "run-awaiter",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running review."
        )
    }
}
