import Foundation
@preconcurrency import NIOCore

final class MCPHTTPNetworkResourceOwner: @unchecked Sendable {
    struct TaskAdmissionClosed: Error, Sendable {
        let kind: TaskKind
    }

    enum TaskKind: Hashable, Sendable {
        case domainHandler
        case response
        case finiteResponseSource
        case finiteResponseWriter
        case streamBridge
        case streamHeartbeat
        case streamWriter
        case streamCompletion
    }

    struct ChildRegistration: Hashable, Sendable {
        fileprivate let id: UUID
    }

    final class TaskReceipt: @unchecked Sendable {
        fileprivate let id: UUID
        fileprivate let kind: TaskKind
        fileprivate let childID: UUID?
        private weak var owner: MCPHTTPNetworkResourceOwner?
        private let lock = NSLock()
        private var cancelTask: (@Sendable () -> Void)?
        private var cancellationWasRequested = false
        private var didFinish = false

        fileprivate init(
            id: UUID,
            kind: TaskKind,
            childID: UUID?,
            owner: MCPHTTPNetworkResourceOwner
        ) {
            self.id = id
            self.kind = kind
            self.childID = childID
            self.owner = owner
        }

        func install<Success: Sendable, Failure: Error>(
            _ task: Task<Success, Failure>
        ) {
            let shouldCancel: Bool
            lock.lock()
            if didFinish {
                shouldCancel = false
            } else {
                cancelTask = { task.cancel() }
                shouldCancel = cancellationWasRequested
            }
            lock.unlock()
            if shouldCancel {
                task.cancel()
            }
        }

        func cancel() {
            let cancelTask: (@Sendable () -> Void)?
            lock.lock()
            cancellationWasRequested = true
            cancelTask = self.cancelTask
            lock.unlock()
            cancelTask?()
        }

        func finish() {
            let owner: MCPHTTPNetworkResourceOwner?
            lock.lock()
            guard didFinish == false else {
                lock.unlock()
                return
            }
            didFinish = true
            cancelTask = nil
            owner = self.owner
            lock.unlock()
            owner?.finishTask(id: id, kind: kind)
        }
    }

    private final class ChildResource: @unchecked Sendable {
        let registration: ChildRegistration
        let channel: any Channel

        init(registration: ChildRegistration, channel: any Channel) {
            self.registration = registration
            self.channel = channel
        }
    }

    private struct TaskCountWaiter {
        let kind: TaskKind
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct ChildCountWaiter {
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var acceptsChildren = false
    private var acceptsTasks = false
    private var closedTaskAdmissionKinds: Set<TaskKind> = []
    private var children: [UUID: ChildResource] = [:]
    private var tasks: [UUID: TaskReceipt] = [:]
    private var childDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var taskDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var taskKindDrainWaiters: [
        TaskKind: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var totalTaskCounts: [TaskKind: Int] = [:]
    private var taskCountWaiters: [UUID: TaskCountWaiter] = [:]
    private var totalChildCount = 0
    private var childCountWaiters: [UUID: ChildCountWaiter] = [:]
    private var heldTaskCompletionKind: TaskKind?
    private var heldTaskCompletionIDs: Set<UUID> = []
    private var taskCompletionHoldWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldHoldNextChildCloseAcknowledgement = false
    private var heldChildCloseAcknowledgementIDs: Set<UUID> = []
    private var childCloseHoldWaiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        precondition(
            children.isEmpty && tasks.isEmpty,
            "MCP network generation must drain resources before reopening."
        )
        acceptsChildren = true
        acceptsTasks = true
        closedTaskAdmissionKinds.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func registerChild(_ channel: any Channel) -> ChildRegistration? {
        let registration: ChildRegistration
        let completedWaiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        guard acceptsChildren else {
            lock.unlock()
            return nil
        }
        registration = .init(id: UUID())
        children[registration.id] = ChildResource(
            registration: registration,
            channel: channel
        )
        totalChildCount += 1
        let completedIDs = childCountWaiters.compactMap { id, waiter in
            totalChildCount >= waiter.targetCount ? id : nil
        }
        completedWaiters = completedIDs.compactMap {
            childCountWaiters.removeValue(forKey: $0)?.continuation
        }
        lock.unlock()
        for waiter in completedWaiters {
            waiter.resume()
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.acknowledgeChildClose(registration)
        }
        return registration
    }

    func closeChildAdmission() {
        lock.lock()
        acceptsChildren = false
        lock.unlock()
    }

    func closeAndDrainChildren() async {
        let channels = closeChildAdmissionAndSnapshot()
        for channel in channels {
            channel.close(mode: .all, promise: nil)
        }
        await withCheckedContinuation { continuation in
            lock.lock()
            if children.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                childDrainWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func closeChildAdmissionAndSnapshot() -> [any Channel] {
        lock.lock()
        acceptsChildren = false
        let channels = children.values.map(\.channel)
        lock.unlock()
        return channels
    }

    func registerTask(
        kind: TaskKind,
        child: ChildRegistration? = nil
    ) -> TaskReceipt? {
        let receipt: TaskReceipt
        let completedWaiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        guard acceptsTasks, closedTaskAdmissionKinds.contains(kind) == false else {
            lock.unlock()
            return nil
        }
        receipt = TaskReceipt(
            id: UUID(),
            kind: kind,
            childID: child?.id,
            owner: self
        )
        tasks[receipt.id] = receipt
        totalTaskCounts[kind, default: 0] += 1
        let completedIDs = taskCountWaiters.compactMap { id, waiter in
            waiter.kind == kind && totalTaskCounts[kind, default: 0] >= waiter.targetCount
                ? id
                : nil
        }
        completedWaiters = completedIDs.compactMap {
            taskCountWaiters.removeValue(forKey: $0)?.continuation
        }
        lock.unlock()
        for waiter in completedWaiters {
            waiter.resume()
        }
        return receipt
    }

    func performTask<Success: Sendable>(
        kind: TaskKind,
        operation: @escaping @Sendable () async throws -> Success
    ) async throws -> Success {
        guard let receipt = registerTask(kind: kind) else {
            throw TaskAdmissionClosed(kind: kind)
        }
        let task = Task {
            try await operation()
        }
        receipt.install(task)
        return try await withTaskCancellationHandler {
            defer { receipt.finish() }
            return try await task.value
        } onCancel: {
            receipt.cancel()
        }
    }

    func closeTaskAdmission(kind: TaskKind) {
        lock.lock()
        closedTaskAdmissionKinds.insert(kind)
        lock.unlock()
    }

    func closeTaskAdmissionCancelAndDrain() async {
        let receipts = closeTaskAdmissionAndSnapshot()
        for receipt in receipts {
            receipt.cancel()
        }
        await withCheckedContinuation { continuation in
            lock.lock()
            if tasks.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                taskDrainWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func closeTaskAdmissionAndSnapshot() -> [TaskReceipt] {
        lock.lock()
        acceptsTasks = false
        let receipts = Array(tasks.values)
        lock.unlock()
        return receipts
    }

    func cancelTasks(for child: ChildRegistration) {
        let receipts: [TaskReceipt]
        lock.lock()
        receipts = tasks.values.filter { $0.childID == child.id }
        lock.unlock()
        for receipt in receipts {
            receipt.cancel()
        }
    }

    private func acknowledgeChildClose(_ registration: ChildRegistration) {
        let holdWaiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        guard children[registration.id] != nil else {
            lock.unlock()
            return
        }
        if shouldHoldNextChildCloseAcknowledgement {
            shouldHoldNextChildCloseAcknowledgement = false
            heldChildCloseAcknowledgementIDs.insert(registration.id)
            holdWaiters = childCloseHoldWaiters
            childCloseHoldWaiters.removeAll(keepingCapacity: false)
            lock.unlock()
            for waiter in holdWaiters {
                waiter.resume()
            }
            return
        }
        let waiters = finishChildLocked(id: registration.id)
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func finishChildLocked(
        id: UUID
    ) -> [CheckedContinuation<Void, Never>] {
        children.removeValue(forKey: id)
        guard children.isEmpty else {
            return []
        }
        let waiters = childDrainWaiters
        childDrainWaiters.removeAll(keepingCapacity: false)
        return waiters
    }

    fileprivate func finishTask(id: UUID, kind: TaskKind) {
        let holdWaiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        guard tasks[id] != nil else {
            lock.unlock()
            return
        }
        if heldTaskCompletionKind == kind {
            heldTaskCompletionKind = nil
            heldTaskCompletionIDs.insert(id)
            holdWaiters = taskCompletionHoldWaiters
            taskCompletionHoldWaiters.removeAll(keepingCapacity: false)
            lock.unlock()
            for waiter in holdWaiters {
                waiter.resume()
            }
            return
        }
        let waiters = finishTaskLocked(id: id)
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func finishTaskLocked(
        id: UUID
    ) -> [CheckedContinuation<Void, Never>] {
        guard let finished = tasks.removeValue(forKey: id) else {
            return []
        }
        var waiters: [CheckedContinuation<Void, Never>] = []
        if tasks.values.contains(where: { $0.kind == finished.kind }) == false {
            waiters.append(contentsOf: taskKindDrainWaiters.removeValue(
                forKey: finished.kind
            ) ?? [])
        }
        if tasks.isEmpty {
            waiters.append(contentsOf: taskDrainWaiters)
            taskDrainWaiters.removeAll(keepingCapacity: false)
        }
        return waiters
    }

    func waitForTasksDrained(kind: TaskKind) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if tasks.values.contains(where: { $0.kind == kind }) == false {
                lock.unlock()
                continuation.resume()
            } else {
                taskKindDrainWaiters[kind, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    func holdNextTaskCompletionForTesting(kind: TaskKind) {
        lock.lock()
        precondition(
            heldTaskCompletionKind == nil && heldTaskCompletionIDs.isEmpty,
            "MCP task completion test gate owns one held completion."
        )
        heldTaskCompletionKind = kind
        lock.unlock()
    }

    func waitForHeldTaskCompletionForTesting() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if heldTaskCompletionIDs.isEmpty == false {
                lock.unlock()
                continuation.resume()
            } else {
                taskCompletionHoldWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func hasHeldTaskCompletionForTesting() -> Bool {
        lock.lock()
        let hasHeldCompletion = heldTaskCompletionIDs.isEmpty == false
        lock.unlock()
        return hasHeldCompletion
    }

    func releaseHeldTaskCompletionForTesting() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        let heldIDs = heldTaskCompletionIDs
        heldTaskCompletionIDs.removeAll(keepingCapacity: false)
        waiters = heldIDs.flatMap { finishTaskLocked(id: $0) }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForTaskCountForTesting(kind: TaskKind, count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if totalTaskCounts[kind, default: 0] >= count {
                lock.unlock()
                continuation.resume()
            } else {
                taskCountWaiters[UUID()] = .init(
                    kind: kind,
                    targetCount: count,
                    continuation: continuation
                )
                lock.unlock()
            }
        }
    }

    func taskCountForTesting(kind: TaskKind) -> Int {
        lock.lock()
        let count = totalTaskCounts[kind, default: 0]
        lock.unlock()
        return count
    }

    func childCountForTesting() -> Int {
        lock.lock()
        let count = totalChildCount
        lock.unlock()
        return count
    }

    func waitForChildCountForTesting(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if totalChildCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                childCountWaiters[UUID()] = .init(
                    targetCount: count,
                    continuation: continuation
                )
                lock.unlock()
            }
        }
    }

    func holdNextChildCloseAcknowledgementForTesting() {
        lock.lock()
        precondition(
            shouldHoldNextChildCloseAcknowledgement == false
                && heldChildCloseAcknowledgementIDs.isEmpty,
            "MCP child close test gate owns one acknowledgement."
        )
        shouldHoldNextChildCloseAcknowledgement = true
        lock.unlock()
    }

    func waitForHeldChildCloseAcknowledgementForTesting() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if heldChildCloseAcknowledgementIDs.isEmpty == false {
                lock.unlock()
                continuation.resume()
            } else {
                childCloseHoldWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func releaseHeldChildCloseAcknowledgementForTesting() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        let heldIDs = heldChildCloseAcknowledgementIDs
        heldChildCloseAcknowledgementIDs.removeAll(keepingCapacity: false)
        waiters = heldIDs.flatMap { finishChildLocked(id: $0) }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func resourceCountsForTesting() -> (children: Int, tasks: Int) {
        lock.lock()
        let counts = (children.count, tasks.count)
        lock.unlock()
        return counts
    }
}
