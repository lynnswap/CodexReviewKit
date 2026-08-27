import Foundation

package final class ReviewStoreSessionCloseReceipt: Sendable {
    package let operationID: UUID
    private let cancellationPublication: ReviewStoreSessionCloseCancellationPublication
    private let task: Task<Void, Never>

    init(
        operationID: UUID,
        cancellationPublication: ReviewStoreSessionCloseCancellationPublication,
        task: Task<Void, Never>
    ) {
        self.operationID = operationID
        self.cancellationPublication = cancellationPublication
        self.task = task
    }

    package func waitUntilCancellationPublished() async {
        await cancellationPublication.wait()
    }

    package func waitUntilClosed() async {
        await task.value
    }
}

actor ReviewStoreSessionCloseCancellationPublication {
    private var isPublished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func publish() {
        guard isPublished == false else {
            return
        }
        isPublished = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        if isPublished {
            return
        }
        await withCheckedContinuation { continuation in
            if isPublished {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}
