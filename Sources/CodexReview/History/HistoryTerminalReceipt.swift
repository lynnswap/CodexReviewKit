@MainActor
package final class HistoryTerminalReceipt {
    package let jobID: String
    private let mutation: ReviewHistoryMutationReceipt<ReviewHistoryMutationResult>

    package init(
        jobID: String,
        mutation: ReviewHistoryMutationReceipt<ReviewHistoryMutationResult>
    ) {
        self.jobID = jobID
        self.mutation = mutation
    }

    package var isResolved: Bool {
        mutation.isResolved
    }

    package func waitUntilResolved() async {
        _ = await mutation.wait()
    }
}
