import Foundation
import ObservationBridge

@MainActor
public enum ReviewObservationAwaiter {
    public static func waitUntilTerminal(
        job: ReviewRunRecord,
        timeout: Duration? = nil
    ) async -> Bool {
        if job.isTerminal {
            return true
        }

        let waiter = ReviewTerminalObservationWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.begin(
                    job: job,
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
        job: ReviewRunRecord,
        timeout: Duration?,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        self.continuation = continuation
        token = withPortableContinuousObservation { [weak self, job] event in
            _ = job.core.lifecycle.status
            guard job.isTerminal else {
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
