import Foundation
import Testing
@testable import CodexReviewKit

@MainActor
@Suite("review observation awaiter")
struct ReviewObservationAwaiterTests {
    @Test func resumesWhenJobReachesTerminalState() async throws {
        let job = makeRunningJob()

        let task = Task { @MainActor in
            await ReviewObservationAwaiter.waitUntilTerminal(
                job: job,
                timeout: .seconds(1)
            )
        }
        await Task.yield()

        job.updateStateForTesting(status: .succeeded, summary: "Done")

        let result = await task.value
        #expect(result)
    }

    @Test func resumesWhenJobCancellationReachesTerminalState() async throws {
        let job = makeRunningJob()

        let task = Task { @MainActor in
            await ReviewObservationAwaiter.waitUntilTerminal(
                job: job,
                timeout: .seconds(1)
            )
        }
        await Task.yield()

        job.updateStateForTesting(status: .cancelled, summary: "Stop")

        let result = await task.value
        #expect(result)
    }

    @Test func returnsFalseOnTimeout() async throws {
        let job = makeRunningJob()

        let result = await ReviewObservationAwaiter.waitUntilTerminal(
            job: job,
            timeout: .milliseconds(10)
        )

        #expect(result == false)
    }

    private func makeRunningJob() -> ReviewRunRecord {
        ReviewRunRecord.makeForTesting(
            id: "job-awaiter",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running review."
        )
    }
}
