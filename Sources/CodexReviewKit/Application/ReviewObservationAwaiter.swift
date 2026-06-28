import Foundation
import ObservationBridge

@MainActor
package enum ReviewObservationAwaiter {
    package static func waitUntilTerminal(
        run: ReviewRunRecord,
        timeout: Duration? = nil
    ) async -> Bool {
        if run.isTerminal {
            return true
        }

        let waiter = ReviewTerminalObservationWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.begin(
                    run: run,
                    timeout: timeout,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor in
                waiter.cancel()
            }
        }
    }
}

@MainActor
private final class ReviewTerminalObservationWaiter {
    private var token: PortableObservationTracking.Token?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var isResolved = false

    func begin(
        run: ReviewRunRecord,
        timeout: Duration?,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        self.continuation = continuation
        token = withPortableContinuousObservation { [weak self, run] event in
            _ = run.core.lifecycle.status
            guard run.isTerminal else {
                return
            }
            event.cancel()
            self?.resolve(true)
        }
        if let timeout {
            timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.resolve(false)
            }
        }
    }

    func cancel() {
        resolve(false)
    }

    private func resolve(_ result: Bool) {
        guard isResolved == false else {
            return
        }
        isResolved = true
        timeoutTask?.cancel()
        timeoutTask = nil
        token?.cancel()
        token = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}
