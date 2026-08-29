@MainActor
package final class ReviewHistoryMutationReceipt<Value: Sendable> {
    package let ordinal: UInt64
    private var result: Result<Value, ReviewHistoryOperationFailure>?
    private var waiters: [CheckedContinuation<Result<Value, ReviewHistoryOperationFailure>, Never>] = []

    package init(ordinal: UInt64) {
        self.ordinal = ordinal
    }

    package init(
        ordinal: UInt64,
        result: Result<Value, ReviewHistoryOperationFailure>
    ) {
        self.ordinal = ordinal
        self.result = result
    }

    package var isResolved: Bool {
        result != nil
    }

    package func resolve(
        _ result: Result<Value, ReviewHistoryOperationFailure>
    ) {
        guard self.result == nil else {
            return
        }
        self.result = result
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    package func wait() async -> Result<Value, ReviewHistoryOperationFailure> {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
            }
        }
    }
}
