@MainActor
package final class ReviewHistoryMutationCoordinator {
    private var admissionIsOpen = true
    private var nextOrdinal: UInt64 = 0
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?

    package func enqueue<Intent: Sendable, Input: Sendable, Value: Sendable>(
        intent: Intent,
        prepare: @escaping @MainActor @Sendable (Intent) -> Input,
        operation: @escaping @Sendable (Input) async throws -> Value,
        apply: @escaping @MainActor @Sendable (
            Input,
            Result<Value, ReviewHistoryOperationFailure>
        ) -> Void
    ) -> ReviewHistoryMutationReceipt<Value>? {
        guard admissionIsOpen else {
            return nil
        }
        guard nextOrdinal < UInt64.max else {
            preconditionFailure("Review history mutation ordinal exhausted.")
        }
        nextOrdinal += 1
        let ordinal = nextOrdinal
        let receipt = ReviewHistoryMutationReceipt<Value>(ordinal: ordinal)
        let predecessor = tail
        let task = Task<Void, Never> { @MainActor [weak self] in
            await predecessor?.value
            guard let self else {
                receipt.resolve(.failure(.init(
                    message: "Review history mutation owner was released."
                )))
                return
            }
            let input = prepare(intent)
            let result: Result<Value, ReviewHistoryOperationFailure>
            do {
                result = .success(try await operation(input))
            } catch {
                result = .failure(.init(error))
            }
            receipt.resolve(result)
            apply(input, result)
            finish(ordinal: ordinal)
        }
        tasks[ordinal] = task
        tail = task
        return receipt
    }

    package func closeAdmissionAndWait() async {
        admissionIsOpen = false
        await tail?.value
    }

    private func finish(ordinal: UInt64) {
        tasks.removeValue(forKey: ordinal)
    }

    isolated deinit {
        for task in tasks.values {
            task.cancel()
        }
    }
}
