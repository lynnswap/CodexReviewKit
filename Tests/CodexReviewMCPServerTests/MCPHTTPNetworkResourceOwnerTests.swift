import Foundation
import MCP
import Testing
import CodexReviewMCPServer
import CodexReviewTesting

@Suite("MCP HTTP network resource owner")
struct MCPHTTPNetworkResourceOwnerTests {
    @Test func closeWaiterObservationCompletesWhenGenerationIsAlreadyClosed() async {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 20)
        let closing = owner.beginClosing(.serverStop)

        await closing.waitUntilClosed()

        #expect(await owner.waitForCloseWaiterRegistrationForTesting() == .alreadyClosed)
    }

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

    @Test func domainWorkCreationIsRejectedAfterAdmissionClose() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 10)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())

        owner.closeAdmission()
        #expect(admitted.operation.startDomainWork {} == nil)
        admitted.lease.acknowledgeCompletion()
        let closing = owner.beginClosing(.serverStop)
        resource.acknowledgeClose()
        await closing.waitUntilClosed()

        #expect(owner.snapshot().isClosed)
    }

    @Test func connectionAdmissionCloseRejectsDomainWork() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 14)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())

        connection.closeAdmission()
        #expect(admitted.operation.startDomainWork {} == nil)
        admitted.lease.acknowledgeCompletion()
        let closing = owner.beginClosing(.serverStop)
        resource.acknowledgeClose()
        await closing.waitUntilClosed()

        #expect(owner.snapshot().isClosed)
    }

    @Test func finalRequestKeepsItsDomainAdmissionUntilConnectionClose() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 15)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest(finalForConnection: true))

        let task = try #require(admitted.operation.startDomainWork {})
        try await task.value
        admitted.lease.acknowledgeCompletion()

        let closing = owner.beginClosing(.serverStop)
        resource.acknowledgeClose()
        await closing.waitUntilClosed()
        #expect(owner.snapshot().isClosed)
    }

    @Test func responseAndHTTPCompletionStillJoinDomainAcknowledgement() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 11)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())
        let started = AsyncGate()
        let release = AsyncGate()
        let domainTask = try #require(admitted.operation.startDomainWork {
            await started.open()
            await release.waitIgnoringCancellation()
        })
        await started.wait()

        let httpTask = Task {
            defer { admitted.lease.acknowledgeCompletion() }
            guard await admitted.lease.waitUntilStartIsAllowed() else { return }
            #expect(admitted.operation.beginResponse())
            admitted.operation.acknowledgeResponseEnd()
        }
        admitted.lease.install(httpTask)
        await httpTask.value

        let closing = owner.beginClosing(.serverStop)
        resource.acknowledgeClose()
        let didClose = CompletionFlag()
        let waiter = Task {
            await closing.waitUntilClosed()
            await didClose.complete()
        }
        #expect(await didClose.isCompleted() == false)
        #expect(owner.snapshot().connections[0].requests[0].pendingDomainWorkCount == 1)

        await release.open()
        try await domainTask.value
        await waiter.value
        #expect(await didClose.isCompleted())
        #expect(owner.snapshot().isClosed)
    }

    @Test func callerCancellationDoesNotAcknowledgeOwnedDomainWork() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 12)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())
        let started = AsyncGate()
        let release = AsyncGate()
        let observation = StartObservation()
        let domainTask = try #require(admitted.operation.startDomainWork {
            await started.open()
            await release.waitIgnoringCancellation()
            await observation.record(wasAllowed: true, wasCancelled: Task.isCancelled)
        })
        await started.wait()

        domainTask.cancel()
        #expect(owner.snapshot().connections[0].requests[0].pendingDomainWorkCount == 1)
        await release.open()
        try await domainTask.value
        #expect(await observation.value() == .init(wasAllowed: true, wasCancelled: true))

        let closing = owner.beginClosing(.serverStop)
        admitted.lease.acknowledgeCompletion()
        resource.acknowledgeClose()
        await closing.waitUntilClosed()
    }

    @Test func domainWorkCompletionAlwaysReleasesReservation() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 13)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())
        let task = try #require(admitted.operation.startDomainWork {})

        try await task.value
        #expect(owner.snapshot().connections[0].requests[0].pendingDomainWorkCount == 0)

        let closing = owner.beginClosing(.serverStop)
        admitted.lease.acknowledgeCompletion()
        resource.acknowledgeClose()
        await closing.waitUntilClosed()
    }

    @Test func operationIdentityResolvesOnlyItsBoundSessionAndActiveOwner() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 16)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())

        #expect(admitted.operation.bindSession("session-16"))
        #expect(admitted.operation.bindSession("session-16"))
        #expect(admitted.operation.bindSession("other-session") == false)
        let token = try #require(MCPHTTPNetworkResourceOwner.OperationToken(
            headerValue: admitted.operation.token.headerValue
        ))
        #expect(owner.resolve(token, sessionID: "session-16") === admitted.operation)
        #expect(owner.resolve(token, sessionID: "other-session") == nil)
        #expect(MCPHTTPNetworkResourceOwner.OperationToken(headerValue: "client-spoof") == nil)

        admitted.lease.acknowledgeCompletion()
        #expect(owner.resolve(token, sessionID: "session-16") == nil)
        let closing = owner.beginClosing(.serverStop)
        resource.acknowledgeClose()
        await closing.waitUntilClosed()
    }

    @Test func httpBoundaryReplacesSpoofedIdentityAndBindsTheExactOperation() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 17)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())
        let request = HTTPRequest(method: "POST", headers: [
            "x-cOdExReViEw-ReQuEsT-oPeRaTiOn": "client-spoof",
            "X-Client": "preserved",
        ])

        let owned = try #require(CodexReviewMCPHTTPServer.ownedRequest(
            request,
            operation: admitted.operation,
            sessionID: "session-17"
        ))
        let identityHeaders = owned.headers.filter {
            $0.key.lowercased() == MCPHTTPNetworkResourceOwner.operationTokenHeaderName.lowercased()
        }
        #expect(identityHeaders.count == 1)
        #expect(identityHeaders.values.first == admitted.operation.token.headerValue)
        #expect(owned.header("X-Client") == "preserved")
        let encodedToken = try #require(identityHeaders.values.first)
        let token = try #require(MCPHTTPNetworkResourceOwner.OperationToken(
            headerValue: encodedToken
        ))
        #expect(owner.resolve(token, sessionID: "session-17") === admitted.operation)
        #expect(CodexReviewMCPHTTPServer.ownedRequest(
            request,
            operation: admitted.operation,
            sessionID: "other-session"
        ) == nil)

        admitted.lease.acknowledgeCompletion()
        let closing = owner.beginClosing(.serverStop)
        resource.acknowledgeClose()
        await closing.waitUntilClosed()
    }

    @Test func domainBridgeClassifiesIdentityAdmissionAndDomainErrors() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 18)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())
        let sessionID = "session-18"
        #expect(admitted.operation.bindSession(sessionID))
        let ownedRequest = HTTPRequest(
            method: "POST",
            headers: [
                MCPHTTPNetworkResourceOwner.operationTokenHeaderName:
                    admitted.operation.token.headerValue,
            ]
        )

        await #expect(throws: DomainBridgeFailure.expected) {
            try await performMCPDomainWork(
                networkResources: owner,
                sessionID: sessionID,
                httpContext: ownedRequest
            ) { throw DomainBridgeFailure.expected }
        }
        #expect(owner.snapshot().connections[0].requests[0].pendingDomainWorkCount == 0)
        await #expect(throws: MCPError.self) {
            try await performMCPDomainWork(
                networkResources: owner,
                sessionID: sessionID,
                httpContext: nil
            ) {}
        }
        await #expect(throws: MCPError.self) {
            try await performMCPDomainWork(
                networkResources: owner,
                sessionID: "other-session",
                httpContext: ownedRequest
            ) {}
        }

        owner.closeAdmission()
        await #expect(throws: CancellationError.self) {
            try await performMCPDomainWork(
                networkResources: owner,
                sessionID: sessionID,
                httpContext: nil
            ) {}
        }
        let closing = owner.beginClosing(.serverStop)
        admitted.lease.acknowledgeCompletion()
        resource.acknowledgeClose()
        await closing.waitUntilClosed()
    }

    @Test func domainBridgeCancellationSignalsChildAndAwaitsItsAcknowledgement() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 19)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))
        let admitted = try #require(connection.admitRequest())
        let sessionID = "session-19"
        #expect(admitted.operation.bindSession(sessionID))
        let request = HTTPRequest(method: "POST", headers: [
            MCPHTTPNetworkResourceOwner.operationTokenHeaderName:
                admitted.operation.token.headerValue,
        ])
        let started = AsyncGate()
        let release = AsyncGate()
        let childSawCancellation = CompletionFlag()
        let caller = Task {
            try await performMCPDomainWork(
                networkResources: owner,
                sessionID: sessionID,
                httpContext: request
            ) {
                await started.open()
                await release.waitIgnoringCancellation()
                if Task.isCancelled { await childSawCancellation.complete() }
                throw DomainBridgeFailure.expected
            }
        }
        await started.wait()

        caller.cancel()
        #expect(owner.snapshot().connections[0].requests[0].pendingDomainWorkCount == 1)
        await release.open()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(await childSawCancellation.isCompleted())
        #expect(owner.snapshot().connections[0].requests[0].pendingDomainWorkCount == 0)

        let closing = owner.beginClosing(.serverStop)
        admitted.lease.acknowledgeCompletion()
        resource.acknowledgeClose()
        await closing.waitUntilClosed()
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

    @Test func finalRequestAdmissionAtomicallyClosesFutureAdmission() async throws {
        let owner = MCPHTTPNetworkResourceOwner(generationID: 9)
        let resource = TestingConnectionResource()
        let connection = try #require(owner.admitConnection(resource))

        let admitted = try #require(connection.admitRequest(finalForConnection: true))

        let snapshot = try #require(owner.snapshot().connections.first)
        #expect(snapshot.phase == .admissionClosed)
        #expect(snapshot.requests.map(\.id) == [admitted.operation.id])
        #expect(connection.admitRequest(finalForConnection: false) == nil)

        let task = Task {
            defer {
                admitted.lease.acknowledgeCompletion()
            }
            guard await admitted.lease.waitUntilStartIsAllowed() else {
                return
            }
        }
        admitted.lease.install(task)
        await task.value

        let closing = owner.beginClosing(.serverStop)
        await resource.waitUntilCloseIsSignalled()
        resource.acknowledgeClose()
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

private enum DomainBridgeFailure: Error {
    case expected
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
