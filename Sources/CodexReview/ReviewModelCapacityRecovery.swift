import Foundation

package struct CodexReviewModelCapacityRecoveryPolicy: Sendable {
    package var initialRetryDelay: Duration
    package var secondRetryDelay: Duration
    package var maximumRetryDelay: Duration
    package var sleep: @Sendable (Duration) async throws -> Void

    package init(
        initialRetryDelay: Duration = .seconds(15),
        secondRetryDelay: Duration = .seconds(30),
        maximumRetryDelay: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.initialRetryDelay = initialRetryDelay
        self.secondRetryDelay = secondRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
        self.sleep = sleep
    }

    package static var `default`: Self {
        .init()
    }

    func retryDelay(forAttempt attempt: UInt) -> Duration {
        switch attempt {
        case 0:
            initialRetryDelay
        case 1:
            secondRetryDelay
        default:
            maximumRetryDelay
        }
    }
}

struct ReviewModelCapacityRetryState {
    private(set) var attempt: UInt = 0

    mutating func nextDelay(
        using policy: CodexReviewModelCapacityRecoveryPolicy
    ) -> Duration {
        let delay = policy.retryDelay(forAttempt: attempt)
        if attempt < UInt.max {
            attempt += 1
        }
        return delay
    }

    mutating func reset() {
        attempt = 0
    }
}
