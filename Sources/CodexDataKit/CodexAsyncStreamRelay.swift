import Foundation
import Synchronization

final class CodexAsyncStreamRelay<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var isFinished = false
    }

    private let state = Mutex(State())
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    init(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
    ) {
        self.bufferingPolicy = bufferingPolicy
    }

    var hasContinuations: Bool {
        state.withLock { state in
            state.continuations.isEmpty == false
        }
    }

    func makeStream() -> AsyncStream<Element> {
        let id = UUID()
        let pair = AsyncStream<Element>.makeStream(bufferingPolicy: bufferingPolicy)
        let shouldFinish = state.withLock { state in
            guard state.isFinished == false else {
                return true
            }
            state.continuations[id] = pair.continuation
            return false
        }
        if shouldFinish {
            pair.continuation.finish()
            return pair.stream
        }
        let owner = CodexAsyncStreamRelayWeakBox(self)
        pair.continuation.onTermination = codexAsyncStreamRelayTermination(owner: owner, id: id)
        return pair.stream
    }

    func yield(_ element: Element) {
        let continuations = state.withLock { state in
            Array(state.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(element)
        }
    }

    fileprivate func removeStream(_ id: UUID) {
        let continuation = state.withLock { state in
            state.continuations.removeValue(forKey: id)
        }
        continuation?.finish()
    }

    func finish() {
        let continuations: [AsyncStream<Element>.Continuation] = state.withLock { state in
            guard state.isFinished == false else {
                return []
            }
            state.isFinished = true
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    deinit {
        finish()
    }
}

private final class CodexAsyncStreamRelayWeakBox<Element: Sendable>: @unchecked Sendable {
    weak var value: CodexAsyncStreamRelay<Element>?

    init(_ value: CodexAsyncStreamRelay<Element>) {
        self.value = value
    }
}

private func codexAsyncStreamRelayTermination<Element: Sendable>(
    owner: CodexAsyncStreamRelayWeakBox<Element>,
    id: UUID
) -> @Sendable (AsyncStream<Element>.Continuation.Termination) -> Void {
    { @Sendable _ in
        owner.value?.removeStream(id)
    }
}
