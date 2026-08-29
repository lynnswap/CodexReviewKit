import Testing
import CodexReviewTesting

@Suite("test support")
struct TestSupportTests {
    @Test func boundedGateWaitTimesOutAndRemovesItsWaiter() async throws {
        let gate = AsyncGate()
        let timeout = TestSynchronizationTimeout(operation: "a gate that stays closed")

        await #expect(throws: timeout) {
            try await gate.wait(
                timeout: .milliseconds(10),
                operation: timeout.operation
            )
        }

        await gate.open()
        try await gate.wait(
            timeout: .seconds(1),
            operation: "an open gate"
        )
    }

    @Test func boundedGateWaitPreservesCallerCancellation() async {
        let gate = AsyncGate()
        let waiter = Task {
            try await gate.wait(
                timeout: .seconds(1),
                operation: "a cancelled gate wait"
            )
        }

        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
    }
}
