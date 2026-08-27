import Foundation
import Testing
@testable import CodexReview
import CodexReviewTesting

@MainActor
struct CodexReviewAuthenticationSessionReceiptTests {
    @Test func cancellingPassiveWaiterDoesNotCancelSharedAuthenticationOwner() async {
        let terminalGate = AsyncGate()
        let ownerTask = Task {
            await terminalGate.waitIgnoringCancellation()
            return CodexReviewAuthenticationSessionTerminal.succeeded
        }
        let receipt = CodexReviewAuthenticationSessionReceipt(
            operationID: UUID(),
            task: ownerTask
        )
        let cancelledWaiter = Task {
            await receipt.waitUntilTerminal()
        }
        let concurrentWaiter = Task {
            await receipt.waitUntilTerminal()
        }

        cancelledWaiter.cancel()
        #expect(receipt.isCancellationRequested == false)
        await terminalGate.open()

        #expect(await cancelledWaiter.value == .succeeded)
        #expect(await concurrentWaiter.value == .succeeded)
        #expect(receipt.isCancellationRequested == false)
    }
}
