import Foundation

package enum CodexReviewAuthenticationSessionTerminal: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(String)
}

package final class CodexReviewAuthenticationSessionReceipt: Sendable {
    package let operationID: UUID
    private let task: Task<CodexReviewAuthenticationSessionTerminal, Never>

    package init(
        operationID: UUID,
        task: Task<CodexReviewAuthenticationSessionTerminal, Never>
    ) {
        self.operationID = operationID
        self.task = task
    }

    package static func completed(_ terminal: CodexReviewAuthenticationSessionTerminal) -> CodexReviewAuthenticationSessionReceipt {
        CodexReviewAuthenticationSessionReceipt(
            operationID: UUID(),
            task: Task { terminal }
        )
    }

    package var isCancellationRequested: Bool {
        task.isCancelled
    }

    package func cancel() {
        task.cancel()
    }
    package func waitUntilTerminal() async -> CodexReviewAuthenticationSessionTerminal {
        await task.value
    }

    package func cancelAndWait() async -> CodexReviewAuthenticationSessionTerminal {
        task.cancel()
        return await task.value
    }
}
