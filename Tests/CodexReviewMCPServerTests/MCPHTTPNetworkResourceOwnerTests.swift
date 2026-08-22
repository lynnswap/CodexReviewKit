import Foundation
import Testing
import CodexReviewMCPServer
import CodexReviewTesting

@Suite("MCP HTTP network resource owner")
struct MCPHTTPNetworkResourceOwnerTests {
    @Test func acceptedConnectionClosesOnlyAfterItsChannelAcknowledges() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 1)
        let resource = TestingConnectionResource()
        _ = try #require(owner.admitConnection(resource))

        let closing = owner.beginClosing(.serverStop)
        await resource.waitUntilCloseIsSignalled()

        let closingSnapshot = owner.snapshot()
        #expect(closingSnapshot.phase == .closing(.serverStop))
        #expect(closingSnapshot.connections.count == 1)
        #expect(closingSnapshot.connections[0].closeAcknowledged == false)

        resource.acknowledgeClose()
        await closing.waitUntilClosed()

        #expect(owner.snapshot().isClosed)
    }

    @Test func requestAndWorkLeaseAreRegisteredBeforeTaskCreation() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 2)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())

        let beforeTask = try #require(owner.snapshot().connections.first?.requests.first)
        #expect(beforeTask.id == admitted.operation.id)
        #expect(beforeTask.phase == .reserved)

        let didRun = CompletionFlag()
        let task = Task {
            defer {
                admitted.lease.acknowledgeCompletion()
            }
            guard await admitted.lease.waitUntilStartIsAllowed() else {
                return
            }
            await didRun.complete()
        }
        admitted.lease.install(task)
        await task.value

        #expect(await didRun.isCompleted())
        #expect(owner.snapshot().connections.first?.requests.isEmpty == true)

        let closing = owner.beginClosing(.serverStop)
        await resource.waitUntilCloseIsSignalled()
        resource.acknowledgeClose()
        await closing.waitUntilClosed()
    }

    @Test func stopCancellationIsInstalledBeforeReservedWorkCanStart() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 8)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())
        let observation = StartObservation()
        let task = Task {
            defer {
                admitted.lease.acknowledgeCompletion()
            }
            let wasAllowed = await admitted.lease.waitUntilStartIsAllowed()
            await observation.record(
                wasAllowed: wasAllowed,
                wasCancelled: Task.isCancelled
            )
        }

        owner.closeAdmission()
        let closing = owner.beginClosing(.serverStop)
        await resource.waitUntilCloseIsSignalled()
        admitted.lease.install(task)
        resource.acknowledgeClose()

        await task.value
        await closing.waitUntilClosed()
        #expect(await observation.value() == .init(
            wasAllowed: false,
            wasCancelled: true
        ))
    }

    @Test func admissionCloseRejectsLateConnectionsAndRequests() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 3)
        let acceptedResource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(acceptedResource))

        owner.closeAdmission()

        #expect(owner.snapshot().phase == .admissionClosed)
        #expect(connection.admitRequest() == nil)
        let lateResource = TestingConnectionResource()
        #expect(owner.admitConnection(lateResource) == nil)
        await lateResource.waitUntilCloseIsSignalled()

        let closing = owner.beginClosing(.serverStop)
        await acceptedResource.waitUntilCloseIsSignalled()
        acceptedResource.acknowledgeClose()
        await closing.waitUntilClosed()
    }

    @Test func transportFailureWinsPeerCloseAndDrainsItsRequest() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 4)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())
        let started = AsyncGate()
        let completionGate = AsyncGate()
        let task = Task {
            defer {
                admitted.lease.acknowledgeCompletion()
            }
            guard await admitted.lease.waitUntilStartIsAllowed() else {
                return
            }
            await started.open()
            await completionGate.waitIgnoringCancellation()
        }
        admitted.lease.install(task)
        await started.wait()

        connection.transportFailed("broken pipe")
        await resource.waitUntilCloseIsSignalled()
        resource.acknowledgeClose()

        let closingRequest = try #require(owner.snapshot().connections.first?.requests.first)
        #expect(closingRequest.phase == .closing(.transportFailure("broken pipe")))
        #expect(owner.snapshot().connections.first?.closeAcknowledged == true)

        await completionGate.open()
        await task.value
        await connection.waitUntilClosed()

        #expect(owner.snapshot().phase == .accepting)
        #expect(owner.snapshot().connections.isEmpty)
    }

    @Test func peerCloseCancelsAndDrainsItsRequest() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 5)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())
        let started = AsyncGate()
        let completionGate = AsyncGate()
        let task = Task {
            defer {
                admitted.lease.acknowledgeCompletion()
            }
            guard await admitted.lease.waitUntilStartIsAllowed() else {
                return
            }
            await started.open()
            await completionGate.waitIgnoringCancellation()
        }
        admitted.lease.install(task)
        await started.wait()

        resource.acknowledgeClose()

        let closingRequest = try #require(owner.snapshot().connections.first?.requests.first)
        #expect(closingRequest.phase == .closing(.peerClosed))

        await completionGate.open()
        await task.value
        await connection.waitUntilClosed()

        #expect(owner.snapshot().phase == .accepting)
        #expect(owner.snapshot().connections.isEmpty)
    }

    @Test func aStoppedGenerationRejectsLateRegistrationWhileRestartUsesANewOwner() async throws {
        let first = MCPHTTPNetworkResourceOwner(generationID: 6)
        first.closeAdmission()
        let firstClosing = first.beginClosing(.serverStop)
        await firstClosing.waitUntilClosed()

        let lateFirstResource = TestingConnectionResource()
        #expect(first.admitConnection(lateFirstResource) == nil)
        await lateFirstResource.waitUntilCloseIsSignalled()

        let second = MCPHTTPNetworkResourceOwner(generationID: 7)
        let secondResource = TestingConnectionResource()
        _ = try #require(second.admitConnection(secondResource))

        #expect(first.snapshot().generationID == 6)
        #expect(first.snapshot().isClosed)
        #expect(second.snapshot().generationID == 7)
        #expect(second.snapshot().connections.count == 1)

        let secondClosing = second.beginClosing(.serverStop)
        await secondResource.waitUntilCloseIsSignalled()
        secondResource.acknowledgeClose()
        await secondClosing.waitUntilClosed()
    }
}

private final class TestingConnectionResource: MCPHTTPConnectionResource, @unchecked Sendable {
    private let lock = NSLock()
    private var closeAcknowledgement: (@Sendable () -> Void)?
    private var closeWasAcknowledged = false
    private var closeWasSignalled = false
    private var closeSignalWaiters: [CheckedContinuation<Void, Never>] = []

    func signalClose() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        closeWasSignalled = true
        waiters = closeSignalWaiters
        closeSignalWaiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func installCloseAcknowledgement(_ acknowledgement: @escaping @Sendable () -> Void) {
        var shouldAcknowledge = false
        lock.lock()
        precondition(closeAcknowledgement == nil)
        closeAcknowledgement = acknowledgement
        shouldAcknowledge = closeWasAcknowledged
        lock.unlock()
        if shouldAcknowledge {
            acknowledgement()
        }
    }

    func acknowledgeClose() {
        let acknowledgement: (@Sendable () -> Void)?
        lock.lock()
        closeWasAcknowledged = true
        acknowledgement = closeAcknowledgement
        lock.unlock()
        acknowledgement?()
    }

    func waitUntilCloseIsSignalled() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if closeWasSignalled {
                lock.unlock()
                continuation.resume()
            } else {
                closeSignalWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private actor CompletionFlag {
    private var completed = false

    func complete() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor StartObservation {
    struct Value: Equatable, Sendable {
        let wasAllowed: Bool
        let wasCancelled: Bool
    }

    private var recordedValue: Value?

    func record(wasAllowed: Bool, wasCancelled: Bool) {
        recordedValue = .init(
            wasAllowed: wasAllowed,
            wasCancelled: wasCancelled
        )
    }

    func value() -> Value? {
        recordedValue
    }
}
