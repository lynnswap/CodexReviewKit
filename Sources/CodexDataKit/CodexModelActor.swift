import Dispatch

public protocol CodexModelActor: Actor {
    nonisolated var modelContainer: CodexModelContainer { get }
    nonisolated var modelExecutor: CodexDefaultSerialModelExecutor { get }
}

public extension CodexModelActor {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        modelExecutor.asUnownedSerialExecutor()
    }

    var modelContext: CodexModelContext {
        modelExecutor.modelContext
    }
}

// DispatchQueue serializes every job, and the context is package-only so it can
// only be reached through CodexModelActor's actor-isolated modelContext property.
public final class CodexDefaultSerialModelExecutor: @unchecked Sendable, SerialExecutor {
    package let modelContext: CodexModelContext

    private let queue: DispatchQueue

    public convenience init(modelContainer: CodexModelContainer) {
        self.init(modelContext: CodexModelContext(modelContainer))
    }

    package init(modelContext: CodexModelContext) {
        self.modelContext = modelContext
        self.queue = DispatchQueue(
            label: "com.openai.codex-data-kit.model-executor",
            qos: .userInitiated
        )
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
