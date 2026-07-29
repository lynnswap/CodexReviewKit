import Foundation

package struct ReviewWorkerClock: Sendable {
    package typealias Instant = ContinuousClock.Instant

    private let nowValue: @Sendable () -> Instant
    private let sleepValue: @Sendable (Duration) async throws -> Void

    package init(
        now: @escaping @Sendable () -> Instant,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        nowValue = now
        sleepValue = sleep
    }

    package var now: Instant {
        nowValue()
    }

    package func sleep(for duration: Duration) async throws {
        try await sleepValue(duration)
    }

    package static let continuous: Self = {
        let clock = ContinuousClock()
        return .init(
            now: { clock.now },
            sleep: { try await clock.sleep(for: $0) }
        )
    }()
}
