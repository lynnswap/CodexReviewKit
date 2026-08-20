import Foundation

package struct ReviewRuntimeGeneration: Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package func successor() -> Self {
        .init(rawValue: rawValue &+ 1)
    }
}

package struct RuntimePublicationSnapshot: Sendable {
    package let authentication: CodexReviewBackendModel.Auth.Snapshot
    package let settings: CodexReviewSettings.Snapshot

    package init(
        authentication: CodexReviewBackendModel.Auth.Snapshot,
        settings: CodexReviewSettings.Snapshot
    ) {
        self.authentication = authentication
        self.settings = settings
    }
}

package struct MCPServerGeneration: Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package struct MCPServerPublicationSnapshot: Sendable {
    package let serverURL: URL?

    package init(serverURL: URL?) {
        self.serverURL = serverURL
    }
}

package struct PreparedMCPServer: Sendable {
    package let generation: MCPServerGeneration

    package init(generation: MCPServerGeneration) {
        self.generation = generation
    }
}

package enum ReviewRuntimeTransitionPurpose: Equatable, Sendable {
    case stop
    case restartSameAccount
    case accountTransition
    case applicationClose
    case recoveryReplacement
}

@MainActor
package protocol RuntimeLifecycleHandle: Sendable {
    func activate() async throws
    func closeAdmission() async
    func close(purpose: ReviewRuntimeTransitionPurpose) async throws
    func waitUntilClosed() async throws
}

package struct PreparedRuntime: Sendable {
    package let snapshot: RuntimePublicationSnapshot
    package let handle: any RuntimeLifecycleHandle
    package let closeRecord: RuntimeCloseRecord

    @MainActor
    package init(
        snapshot: RuntimePublicationSnapshot,
        handle: any RuntimeLifecycleHandle,
        closeRecord: RuntimeCloseRecord = RuntimeCloseRecord()
    ) {
        self.snapshot = snapshot
        self.handle = handle
        self.closeRecord = closeRecord
    }
}

@MainActor
package final class RuntimeCloseRecord {
    package struct JoinResult {
        package let failures: [ReviewClosePrimaryFailure]
        package let installedClose: Bool
    }

    private enum State {
        case open
        case closing(Task<[ReviewClosePrimaryFailure], Never>)
        case closed([ReviewClosePrimaryFailure])
    }

    private var state: State = .open
    private var failuresWereConsumed = false

    package init() {}

    package func closeAndWait(
        handle: any RuntimeLifecycleHandle,
        purpose: ReviewRuntimeTransitionPurpose
    ) async -> JoinResult {
        let task: Task<[ReviewClosePrimaryFailure], Never>
        let installedClose: Bool
        switch state {
        case .open:
            let newTask = Task<[ReviewClosePrimaryFailure], Never> { @MainActor in
                let record = ReviewRuntimeTransitionRecord()
                var closeFailureWasRecorded = false
                do {
                    try await handle.close(purpose: purpose)
                } catch {
                    closeFailureWasRecorded = true
                    record.record(
                        error,
                        fallback: .client(error.localizedDescription)
                    )
                }
                do {
                    try await handle.waitUntilClosed()
                } catch {
                    if closeFailureWasRecorded == false {
                        record.record(
                            error,
                            fallback: .client(error.localizedDescription)
                        )
                    }
                }
                return record.failures
            }
            state = .closing(newTask)
            task = newTask
            installedClose = true
        case .closing(let existingTask):
            task = existingTask
            installedClose = false
        case .closed(let failures):
            return .init(failures: failures, installedClose: false)
        }

        let failures = await task.value
        state = .closed(failures)
        return .init(failures: failures, installedClose: installedClose)
    }

    package func consumeFailures() -> [ReviewClosePrimaryFailure] {
        guard failuresWereConsumed == false else {
            return []
        }
        guard case .closed(let failures) = state else {
            return []
        }
        failuresWereConsumed = true
        return failures
    }
}

@MainActor
package final class ReviewCloseFailureLedger {
    package private(set) var failures: [ReviewClosePrimaryFailure] = []
    package private(set) var consumedReviewCleanupJobIDs: Set<String> = []
    private var forceCloseFailureJobIDs: Set<String> = []

    package init() {}

    package func record(
        _ error: any Error,
        fallback: ReviewLifecycleResourceFailure
    ) {
        if let failure = error as? ReviewInterruptRequestFailure {
            failures.append(.interruptRequest(failure))
        } else if let failure = error as? ReviewRuntimeCloseFailure {
            failures.append(.attemptRuntime(failure))
        } else if let aggregate = error as? ReviewLifecycleResourceFailureAggregate {
            failures.append(.lifecycleResources(aggregate))
        } else if let failure = error as? ReviewLifecycleResourceFailure {
            failures.append(.lifecycleResources(.init(first: failure)))
        } else {
            failures.append(.lifecycleResources(.init(first: fallback)))
        }
    }

    package func record(_ failure: ReviewClosePrimaryFailure) {
        failures.append(failure)
    }

    package func record(contentsOf failures: [ReviewClosePrimaryFailure]) {
        self.failures.append(contentsOf: failures)
    }

    package func recordReviewCleanupFailure(
        _ failure: ReviewRuntimeCloseFailure,
        jobID: String
    ) {
        guard consumedReviewCleanupJobIDs.insert(jobID).inserted else {
            return
        }
        failures.append(.attemptRuntime(failure))
    }

    package func recordForceCloseFailures(
        _ failures: [ReviewClosePrimaryFailure],
        jobID: String
    ) {
        guard failures.isEmpty == false else {
            return
        }
        forceCloseFailureJobIDs.insert(jobID)
        self.failures.append(contentsOf: failures)
    }

    package func ownsForceCloseFailure(for jobID: String) -> Bool {
        forceCloseFailureJobIDs.contains(jobID)
    }

    package func merge(_ other: ReviewCloseFailureLedger) {
        failures.append(contentsOf: other.failures)
        importReceipts(from: other)
    }

    package func importReceipts(from other: ReviewCloseFailureLedger) {
        consumedReviewCleanupJobIDs.formUnion(other.consumedReviewCleanupJobIDs)
        forceCloseFailureJobIDs.formUnion(other.forceCloseFailureJobIDs)
    }

    package var failureDescription: String? {
        failures.first.map {
            ReviewCloseFailureAggregate(
                first: $0,
                additionalInLifecycleOrder: Array(failures.dropFirst())
            ).localizedDescription
        }
    }
}

package typealias ReviewRuntimeTransitionRecord = ReviewCloseFailureLedger

package struct ReviewRuntimePreparationFailure: LocalizedError, Sendable {
    package let preparationDescription: String
    package let cleanupFailures: ReviewLifecycleResourceFailureAggregate

    package init(
        preparationError: any Error,
        cleanupFailures: ReviewLifecycleResourceFailureAggregate
    ) {
        self.preparationDescription = preparationError.localizedDescription
        self.cleanupFailures = cleanupFailures
    }

    package var errorDescription: String? {
        "\(preparationDescription); \(cleanupFailures.localizedDescription)"
    }
}

package enum ReviewStoreRuntimeState {
    case stopped(ReviewRuntimeGeneration)
    case acquiring(
        generation: ReviewRuntimeGeneration,
        task: Task<Void, Never>,
        record: ReviewRuntimeTransitionRecord
    )
    case running(
        generation: ReviewRuntimeGeneration,
        runtime: PreparedRuntime,
        mcpGeneration: MCPServerGeneration
    )
    case transitioning(
        generation: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose,
        task: Task<Void, Never>,
        record: ReviewRuntimeTransitionRecord,
        sourceRuntime: PreparedRuntime?
    )
    case failed(
        generation: ReviewRuntimeGeneration,
        retainedMCPGeneration: MCPServerGeneration,
        serverURL: URL?
    )

    package var generation: ReviewRuntimeGeneration {
        switch self {
        case .stopped(let generation),
             .acquiring(let generation, _, _),
             .running(let generation, _, _),
             .transitioning(let generation, _, _, _, _),
             .failed(let generation, _, _):
            generation
        }
    }

    package var runtimeForClose: PreparedRuntime? {
        switch self {
        case .running(_, let runtime, _):
            return runtime
        case .transitioning(_, _, _, _, let sourceRuntime):
            return sourceRuntime
        case .stopped, .acquiring, .failed:
            return nil
        }
    }
}

package enum ReviewStoreLifetimeState {
    case open
    case closing(Task<Result<Void, ReviewCloseError>, Never>)
    case closed(Result<Void, ReviewCloseError>)
}

package struct ReviewStoreCommandRegistry {
    package enum Admission {
        case open
        case closed
    }

    package struct DrainWaiter {
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var admission: Admission = .open
    private(set) var nextID: UInt64 = 0
    private(set) var activeIDs: Set<UInt64> = []
    private(set) var ownedTasks: [UInt64: Task<Void, Never>] = [:]
    private var drainWaiters: [DrainWaiter] = []

    package mutating func register() -> UInt64? {
        guard case .open = admission else {
            return nil
        }
        nextID &+= 1
        activeIDs.insert(nextID)
        return nextID
    }

    package mutating func installOwnedTask(
        _ task: Task<Void, Never>,
        for id: UInt64
    ) {
        precondition(
            activeIDs.contains(id),
            "ReviewStoreCommandRegistry must register a command before installing its Task."
        )
        ownedTasks[id] = task
    }

    package mutating func closeAdmission() {
        admission = .closed
        resumeDrainWaitersIfNeeded()
    }

    package mutating func finish(_ id: UInt64) {
        activeIDs.remove(id)
        ownedTasks.removeValue(forKey: id)
        resumeDrainWaitersIfNeeded()
    }

    package func ownedTaskSnapshot() -> [(UInt64, Task<Void, Never>)] {
        ownedTasks.sorted { $0.key < $1.key }
    }

    package mutating func appendDrainWaiter(
        _ continuation: CheckedContinuation<Void, Never>
    ) {
        if activeIDs.isEmpty {
            continuation.resume()
        } else {
            drainWaiters.append(.init(continuation: continuation))
        }
    }

    private mutating func resumeDrainWaitersIfNeeded() {
        guard case .closed = admission, activeIDs.isEmpty else {
            return
        }
        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}

@MainActor
package protocol MCPServerLifecycleOwner: Sendable {
    func prepare() async throws -> PreparedMCPServer
    func activate(
        _ generation: MCPServerGeneration
    ) async throws -> MCPServerPublicationSnapshot
    func closeAdmission() async
    func drainAdmittedHandlers() async throws
    func stop() async throws
    func waitUntilStopped() async throws
    func close() async throws
    func waitUntilClosed() async throws
}

package enum ReviewLifecycleResourceFailure: LocalizedError, Equatable, Sendable {
    case client(String)
    case process(String)
    case authenticationObservation(String)
    case reader(String)
    case router(String)
    case session(String)
    case rateLimit(String)
    case mcpHandlerDrain(String)
    case mcpServer(String)

    package var errorDescription: String? {
        switch self {
        case .client(let message):
            "App-server client close failed: \(message)"
        case .process(let message):
            "App-server process close failed: \(message)"
        case .authenticationObservation(let message):
            "Authentication observation close failed: \(message)"
        case .reader(let message):
            "App-server reader close failed: \(message)"
        case .router(let message):
            "App-server router close failed: \(message)"
        case .session(let message):
            "App-server session close failed: \(message)"
        case .rateLimit(let message):
            "Rate-limit refresh close failed: \(message)"
        case .mcpHandlerDrain(let message):
            "MCP handler drain failed: \(message)"
        case .mcpServer(let message):
            "MCP server close failed: \(message)"
        }
    }
}

package struct ReviewLifecycleResourceFailureAggregate: LocalizedError, Sendable {
    package let first: ReviewLifecycleResourceFailure
    package let additionalInLifecycleOrder: [ReviewLifecycleResourceFailure]

    package init(
        first: ReviewLifecycleResourceFailure,
        additionalInLifecycleOrder: [ReviewLifecycleResourceFailure] = []
    ) {
        self.first = first
        self.additionalInLifecycleOrder = additionalInLifecycleOrder
    }

    package var errorDescription: String? {
        ([first] + additionalInLifecycleOrder)
            .map(\.localizedDescription)
            .joined(separator: "; ")
    }
}

package enum ReviewPersistenceError: LocalizedError, Sendable {
    case open(String)
    case migration(String)
    case read(String)
    case write(String)
    case close(String)

    package var errorDescription: String? {
        switch self {
        case .open(let message): "Review history open failed: \(message)"
        case .migration(let message): "Review history migration failed: \(message)"
        case .read(let message): "Review history read failed: \(message)"
        case .write(let message): "Review history write failed: \(message)"
        case .close(let message): "Review history close failed: \(message)"
        }
    }
}

package enum ReviewClosePrimaryFailure: LocalizedError, Sendable {
    case interruptRequest(ReviewInterruptRequestFailure)
    case attemptRuntime(ReviewRuntimeCloseFailure)
    case lifecycleResources(ReviewLifecycleResourceFailureAggregate)
    case persistence(ReviewPersistenceError)

    package var errorDescription: String? {
        switch self {
        case .interruptRequest(let failure): failure.localizedDescription
        case .attemptRuntime(let failure): failure.localizedDescription
        case .lifecycleResources(let failure): failure.localizedDescription
        case .persistence(let failure): failure.localizedDescription
        }
    }
}

package struct ReviewCloseFailureAggregate: LocalizedError, Sendable {
    package let first: ReviewClosePrimaryFailure
    package let additionalInLifecycleOrder: [ReviewClosePrimaryFailure]

    package init(
        first: ReviewClosePrimaryFailure,
        additionalInLifecycleOrder: [ReviewClosePrimaryFailure] = []
    ) {
        self.first = first
        self.additionalInLifecycleOrder = additionalInLifecycleOrder
    }

    package var errorDescription: String? {
        ([first] + additionalInLifecycleOrder)
            .map(\.localizedDescription)
            .joined(separator: "; ")
    }
}

package struct ReviewCloseError: LocalizedError, Sendable {
    package let failures: ReviewCloseFailureAggregate
    package let secondaryPhysicalDatabaseClose: ReviewPersistenceError?

    package init(
        failures: ReviewCloseFailureAggregate,
        secondaryPhysicalDatabaseClose: ReviewPersistenceError? = nil
    ) {
        self.failures = failures
        self.secondaryPhysicalDatabaseClose = secondaryPhysicalDatabaseClose
    }

    package var errorDescription: String? {
        guard let secondaryPhysicalDatabaseClose else {
            return failures.localizedDescription
        }
        return "\(failures.localizedDescription); \(secondaryPhysicalDatabaseClose.localizedDescription)"
    }
}

@MainActor
package final class NoMCPServerLifecycleOwner: MCPServerLifecycleOwner {
    private enum State {
        case stopped
        case prepared(MCPServerGeneration)
        case running(MCPServerGeneration)
        case closed
    }

    private var state: State = .stopped
    private var nextGeneration: UInt64 = 0

    package init() {}

    package func prepare() async throws -> PreparedMCPServer {
        guard case .stopped = state else {
            throw ReviewLifecycleResourceFailure.mcpServer(
                "No-MCP owner preparation requires stopped state."
            )
        }
        nextGeneration &+= 1
        let generation = MCPServerGeneration(rawValue: nextGeneration)
        state = .prepared(generation)
        return .init(generation: generation)
    }

    package func activate(
        _ generation: MCPServerGeneration
    ) async throws -> MCPServerPublicationSnapshot {
        guard case .prepared(generation) = state else {
            throw ReviewLifecycleResourceFailure.mcpServer(
                "No-MCP activation requires its exact prepared generation."
            )
        }
        state = .running(generation)
        return .init(serverURL: nil)
    }

    package func closeAdmission() async {}

    package func drainAdmittedHandlers() async throws {}

    package func stop() async throws {
        switch state {
        case .stopped:
            return
        case .prepared, .running:
            state = .stopped
        case .closed:
            throw ReviewLifecycleResourceFailure.mcpServer(
                "No-MCP owner is closed."
            )
        }
    }

    package func waitUntilStopped() async throws {
        guard case .stopped = state else {
            throw ReviewLifecycleResourceFailure.mcpServer(
                "No-MCP owner did not stop."
            )
        }
    }

    package func close() async throws {
        state = .closed
    }

    package func waitUntilClosed() async throws {
        guard case .closed = state else {
            throw ReviewLifecycleResourceFailure.mcpServer(
                "No-MCP owner did not close."
            )
        }
    }
}
