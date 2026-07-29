import Foundation
import ObservationBridge
import Synchronization

@MainActor
package enum ReviewObservationAwaiter {
    package static func waitUntilTerminal(
        run: ReviewRunRecord,
        timeout: Duration? = nil
    ) async -> Bool {
        if run.isTerminal {
            return true
        }

        let signal = ReviewTerminalObservationSignal()
        let token = withPortableContinuousObservation { [run, signal] event in
            _ = run.core.status
            guard run.isTerminal else {
                return
            }
            event.cancel()
            signal.finish(true)
        }
        defer {
            token.cancel()
            signal.finish(false)
        }

        guard let timeout else {
            return await signal.wait()
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await signal.wait()
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

private final class ReviewTerminalObservationSignal: Sendable {
    private enum State: Sendable {
        case idle
        case waiting(CheckedContinuation<Bool, Never>)
        case finished(Bool)
    }

    private let state = Mutex<State>(.idle)

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Bool? in
                    switch state {
                    case .idle where Task.isCancelled:
                        state = .finished(false)
                        return false
                    case .idle:
                        state = .waiting(continuation)
                        return nil
                    case .waiting:
                        preconditionFailure("A terminal observation signal is single-consumer.")
                    case .finished(let result):
                        return result
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            finish(false)
        }
    }

    func finish(_ result: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            switch state {
            case .idle:
                state = .finished(result)
                return nil
            case .waiting(let continuation):
                state = .finished(result)
                return continuation
            case .finished:
                return nil
            }
        }
        continuation?.resume(returning: result)
    }
}
