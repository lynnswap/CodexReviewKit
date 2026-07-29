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

        run.updateStateForTesting(
            status: .succeeded,
            endedAt: Date(timeIntervalSince1970: 20),
            summary: "Done"
        )

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

        run.updateStateForTesting(
            status: .cancelled,
            endedAt: Date(timeIntervalSince1970: 20),
            summary: "Stop"
        )

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

    @Test func cancellationResumesWithoutWaitingForObservationOrTimeout() async {
        let run = makeRunningRun()
        let task = Task { @MainActor in
            await ReviewObservationAwaiter.waitUntilTerminal(
                run: run,
                timeout: .seconds(60)
            )
        }
        await Task.yield()

        task.cancel()

        #expect(await task.value == false)
    }

    private func makeRunningRun() -> ReviewRunRecord {
        ReviewRunRecord.makeForTesting(
            id: "run-awaiter",
            targetSummary: "Uncommitted changes",
            attemptID: "attempt-awaiter",
            threadID: "thread-awaiter",
            turnID: "turn-awaiter",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 10),
            summary: "Running review."
        )
    }
}
