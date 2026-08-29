@MainActor
package final class HistoryStartReceipt {
    package let ordinal: UInt64
    package let sessionID: String
    package let started: StartedReviewRecord
    package let workAdmission: ReviewStoreWorkRegistry.Admission

    private(set) var cancellation: ReviewCancellation?
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init(
        ordinal: UInt64,
        sessionID: String,
        started: StartedReviewRecord,
        workAdmission: ReviewStoreWorkRegistry.Admission
    ) {
        self.ordinal = ordinal
        self.sessionID = sessionID
        self.started = started
        self.workAdmission = workAdmission
    }

    package func requestCancellation(_ cancellation: ReviewCancellation) {
        if self.cancellation == nil {
            self.cancellation = cancellation
        }
    }

    package func finish() {
        guard isFinished == false else {
            return
        }
        isFinished = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    package func waitUntilFinished() async {
        if isFinished {
            return
        }
        await withCheckedContinuation { continuation in
            if isFinished {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}
