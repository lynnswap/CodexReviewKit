import Foundation
import Synchronization
import Testing

import CodexAppServerKitTesting
@testable import CodexAppServerKit

@Suite("Server request registry")
struct ServerRequestRegistryTests {
    @Test func testingInjectorRoutesIntegerAndStringIDsThroughCodecAndRegistry() async throws {
        let injector = await CodexAppServerTestServerRequestInjector()
        let ids: [CodexServerRequestID] = [.integer(42), .string("approval-42")]

        for id in ids {
            try await injector.inject(
                id: id,
                method: "item/commandExecution/requestApproval",
                params: commandApprovalParams()
            )
            let response = try #require(await injector.response(for: id))
            #expect(try jsonResult(from: response) == ["decision": "decline"])
        }

        await injector.waitUntilIdle()
        #expect(await injector.childCount() == 0)
        #expect(await injector.responses().map(\.requestID) == ids)
    }

    @Test func duplicateRequestIDRespondsAtMostOnce() async throws {
        let invocationCount = Mutex(0)
        let started = RegistryTestCountSignal(target: 1)
        let suspension = RegistryTestSuspension()
        let injector = await CodexAppServerTestServerRequestInjector { _ in
            invocationCount.withLock { $0 += 1 }
            await started.signal()
            for await _ in suspension.stream {}
            return .approval(.accept)
        }
        let id = CodexServerRequestID.string("duplicate")

        try await injector.inject(
            id: id,
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams()
        )
        await started.wait()
        try await injector.inject(
            id: id,
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams()
        )
        suspension.finish()
        _ = await injector.response(for: id)
        await injector.waitUntilIdle()

        #expect(invocationCount.withLock { $0 } == 1)
        #expect(await injector.responses().count == 1)
        #expect(await injector.diagnostics().contains(.duplicateRequest(id)))

        try await injector.inject(
            id: id,
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams()
        )
        await injector.waitUntilIdle()
        #expect(invocationCount.withLock { $0 } == 2)
        #expect(await injector.responses().count == 2)
    }

    @Test func duplicateMalformedRequestIDRespondsAtMostOnceWhileReplyCommits() async {
        let responseStarted = RegistryTestCountSignal(target: 1)
        let responseGate = RegistryTestManualGate()
        let responseCount = Mutex(0)
        let diagnostics = Mutex<[ServerRequestRegistry.Diagnostic]>([])
        let connectionEventHub = ConnectionEventHub()
        var connectionEventIterator = connectionEventHub.events().makeAsyncIterator()
        let registry = ServerRequestRegistry(
            connectionEventHub: connectionEventHub,
            handler: { _ in
                throw RegistryTestFailure.unexpectedResponse
            },
            responder: { _, _ in
                await responseStarted.signal()
                await responseGate.wait()
                responseCount.withLock { $0 += 1 }
            },
            diagnosticHandler: { diagnostic in
                diagnostics.withLock { $0.append(diagnostic) }
            }
        )
        let id = CodexServerRequestID.string("malformed-duplicate")
        let method = "item/commandExecution/requestApproval"
        let malformedParams = Data("{}".utf8)

        await registry.receive(id: id, method: method, params: malformedParams)
        await responseStarted.wait()
        await registry.receive(id: id, method: method, params: malformedParams)
        await responseGate.release()
        await registry.waitUntilIdle()

        #expect(responseCount.withLock { $0 } == 1)
        guard case .warning(let decodeWarning) = await connectionEventIterator.next() else {
            Issue.record("Expected the decode failure on the connection event stream.")
            return
        }
        #expect(decodeWarning.method == method)
        #expect(decodeWarning.details?.contains("malformed-duplicate") == true)
        guard case .warning(let duplicateWarning) = await connectionEventIterator.next() else {
            Issue.record("Expected the duplicate request on the connection event stream.")
            return
        }
        #expect(duplicateWarning.message == "Received a duplicate server-request identifier.")
        #expect(duplicateWarning.details == "requestId: malformed-duplicate")
        #expect(diagnostics.withLock { values in
            values.contains(.duplicateRequest(id))
                && values.contains { diagnostic in
                    if case .decodeFailed(id, let decodedMethod, _) = diagnostic {
                        return decodedMethod == method
                    }
                    return false
                }
        })
    }

    @Test func handlerThrowRespondsWithInternalErrorAndDiagnostic() async throws {
        let injector = await CodexAppServerTestServerRequestInjector { _ in
            throw RegistryTestFailure.handler
        }
        let id = CodexServerRequestID.integer(7)

        try await injector.inject(
            id: id,
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams()
        )
        guard let response = await injector.response(for: id) else {
            Issue.record("Expected a handler failure response.")
            return
        }
        guard case .error(let code, let message) = response else {
            Issue.record("Expected a JSON-RPC internal error.")
            return
        }
        #expect(code == -32603)
        #expect(message.contains("Handler failed"))
        #expect(await injector.diagnostics().contains { diagnostic in
            if case .handlerFailed(id, let method, _) = diagnostic {
                return method == "item/commandExecution/requestApproval"
            }
            return false
        })
        #expect(await injector.childCount() == 0)
    }

    @Test func closeTracksHandlerUntilCommittedResponseFinishes() async throws {
        let responderStarted = RegistryTestCountSignal(target: 1)
        let responderGate = RegistryTestManualGate()
        let responderCancelled = RegistryTestThreadSafeSignal()
        let closeCompleted = Mutex(false)
        let registry = ServerRequestRegistry(
            connectionEventHub: ConnectionEventHub(),
            handler: { _ in .approval(.accept) },
            responder: { _, _ in
                await responderStarted.signal()
                await withTaskCancellationHandler {
                    await responderGate.wait()
                } onCancel: {
                    responderCancelled.signal()
                }
            }
        )

        await registry.receive(
            id: .string("committing-response"),
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams()
        )
        await responderStarted.wait()
        #expect(await registry.childCount() == 1)

        let closeTask = Task {
            await registry.cancelAllAndWait()
            closeCompleted.withLock { $0 = true }
        }
        await responderCancelled.wait()

        #expect(await registry.childCount() == 1)
        #expect(closeCompleted.withLock { $0 } == false)

        await responderGate.release()
        await closeTask.value
        #expect(await registry.childCount() == 0)
        #expect(closeCompleted.withLock { $0 })
    }

    @Test func resolvedNotificationCancelsAndAwaitsMatchingChildWithoutResponse() async throws {
        let started = RegistryTestCountSignal(target: 1)
        let suspension = RegistryTestSuspension()
        let injector = await CodexAppServerTestServerRequestInjector { _ in
            await started.signal()
            for await _ in suspension.stream {}
            return .approval(.accept)
        }
        let id = CodexServerRequestID.string("resolved")

        try await injector.inject(
            id: id,
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams()
        )
        await started.wait()
        #expect(await injector.childCount() == 1)

        let responseTask = Task {
            await injector.response(for: id)
        }
        try await injector.resolve(id)

        #expect(await injector.childCount() == 0)
        #expect(await injector.responses().isEmpty)
        #expect(await responseTask.value == nil)
    }

    @Test func closeRejectsNewWorkAndDrainsEveryChild() async throws {
        let started = RegistryTestCountSignal(target: 2)
        let suspension = RegistryTestSuspension()
        let injector = await CodexAppServerTestServerRequestInjector { _ in
            await started.signal()
            for await _ in suspension.stream {}
            return .approval(.accept)
        }

        for id in [CodexServerRequestID.integer(1), .string("two")] {
            try await injector.inject(
                id: id,
                method: "item/commandExecution/requestApproval",
                params: commandApprovalParams()
            )
        }
        await started.wait()
        #expect(await injector.childCount() == 2)

        await injector.close()

        #expect(await injector.childCount() == 0)
        #expect(await injector.responses().isEmpty)
        let rejectedID = CodexServerRequestID.string("after-close")
        await #expect(throws: CodexTransportFailure.self) {
            try await injector.inject(
                id: rejectedID,
                method: "item/commandExecution/requestApproval",
                params: commandApprovalParams()
            )
        }
    }

    @Test func handlerOwnedRegistryCloseSignalsWithoutAwaitingItself() async throws {
        let injectorBox = RegistryTestInjectorBox()
        let siblingStarted = RegistryTestCountSignal(target: 1)
        let closeReturned = RegistryTestCountSignal(target: 1)
        let siblingGate = RegistryTestManualGate()
        let injector = await CodexAppServerTestServerRequestInjector { request in
            guard case .commandExecutionApproval(let approval) = request else {
                throw RegistryTestFailure.unexpectedResponse
            }
            if approval.itemID == "sibling" {
                await siblingStarted.signal()
                await siblingGate.wait()
                return .approval(.accept)
            }
            await injectorBox.value()?.close()
            await closeReturned.signal()
            return .approval(.accept)
        }
        injectorBox.set(injector)
        let id = CodexServerRequestID.string("self-close")

        try await injector.inject(
            id: .string("sibling"),
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams(itemID: "sibling")
        )
        await siblingStarted.wait()
        try await injector.inject(
            id: id,
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams(itemID: "closer")
        )
        await closeReturned.wait()
        #expect(await injector.childCount() == 1)

        await siblingGate.release()
        await injector.waitUntilIdle()
        await injector.close()

        #expect(await injector.childCount() == 0)
        #expect(await injector.responses().isEmpty)
        #expect(await injector.diagnostics().contains(.ownedTaskRequestedClose(id)))
    }

    @Test func requestAcceptedBeforeHandlerOwnedCloseIsRejectedByClosingRegistry() async throws {
        let injectorBox = RegistryTestInjectorBox()
        let handlerStarted = RegistryTestCountSignal(target: 1)
        let requestClose = RegistryTestManualGate()
        let closeReturned = RegistryTestCountSignal(target: 1)
        let invocationCount = Mutex(0)
        let injector = await CodexAppServerTestServerRequestInjector { _ in
            invocationCount.withLock { $0 += 1 }
            await handlerStarted.signal()
            await requestClose.wait()
            await injectorBox.value()?.close()
            await closeReturned.signal()
            return .approval(.accept)
        }
        injectorBox.set(injector)

        try await injector.inject(
            id: .string("close-owner"),
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams()
        )
        await handlerStarted.wait()

        let deliveryGate = CodexAppServerTestGate()
        await injector.holdNextInboundEventDelivery(at: deliveryGate)
        let rejectedID = CodexServerRequestID.string("accepted-before-close")
        try await injector.injectAccepted(
            id: rejectedID,
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams()
        )
        await injector.waitUntilInboundEventDeliveryIsHeld()

        await requestClose.release()
        await closeReturned.wait()
        await injector.waitUntilInjectedRequestsAreDelivered()
        await injector.waitUntilIdle()

        #expect(invocationCount.withLock { $0 } == 1)
        #expect(await injector.responses().isEmpty)
        #expect(await injector.diagnostics().contains(
            .rejectedWhileClosing(
                rejectedID,
                method: "item/commandExecution/requestApproval"
            )
        ))
    }

    @Test func inheritedContextCannotClaimAReusedRequestIDAfterItsHandlerCompletes() async throws {
        let injectorBox = RegistryTestInjectorBox()
        let invocationCount = Mutex(0)
        let inheritedChildStarted = RegistryTestCountSignal(target: 1)
        let inheritedCloseGate = RegistryTestManualGate()
        let inheritedCloseReturned = RegistryTestCountSignal(target: 1)
        let reusedRequestStarted = RegistryTestCountSignal(target: 1)
        let injector = await CodexAppServerTestServerRequestInjector { _ in
            let invocation = invocationCount.withLock { count in
                count += 1
                return count
            }
            if invocation == 1 {
                Task {
                    await inheritedChildStarted.signal()
                    await inheritedCloseGate.wait()
                    await injectorBox.value()?.close()
                    await inheritedCloseReturned.signal()
                }
                return .approval(.accept)
            }

            await reusedRequestStarted.signal()
            try await Task.sleep(for: .seconds(3_600))
            return .approval(.accept)
        }
        injectorBox.set(injector)
        let id = CodexServerRequestID.string("reused")

        try await injector.inject(
            id: id,
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams()
        )
        await inheritedChildStarted.wait()
        _ = await injector.response(for: id)
        await injector.waitUntilIdle()

        try await injector.inject(
            id: id,
            method: "item/commandExecution/requestApproval",
            params: commandApprovalParams()
        )
        await reusedRequestStarted.wait()
        #expect(await injector.childCount() == 1)

        await inheritedCloseGate.release()
        await inheritedCloseReturned.wait()

        #expect(await injector.childCount() == 0)
        #expect(await injector.responses().count == 1)
        #expect(await injector.diagnostics().contains(.ownedTaskRequestedClose(id)) == false)

        let rejectedID = CodexServerRequestID.string("after-inherited-close")
        await #expect(throws: CodexTransportFailure.self) {
            try await injector.inject(
                id: rejectedID,
                method: "item/commandExecution/requestApproval",
                params: commandApprovalParams()
            )
        }
    }

    @Test func processTransportRoutesResolvedNotificationAndSuppressesWireResponse() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executableURL = rootURL.appendingPathComponent("fake-app-server")
        let startedURL = rootURL.appendingPathComponent("handler-started")
        let responseURL = rootURL.appendingPathComponent("response.json")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try """
            #!/bin/sh
            printf '%s\\n' '{"id":"request-string","method":"item/commandExecution/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"item","startedAtMs":1}}'
            while [ ! -f "$STARTED_PATH" ]; do :; done
            printf '%s\\n' '{"method":"serverRequest/resolved","params":{"threadId":"thread","requestId":"request-string"}}'
            if IFS= read -r line; then
                printf '%s\\n' "$line" > "$RESPONSE_PATH"
            fi
            """
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let cancellationObserved = RegistryTestCountSignal(target: 1)
        let transport = try AppServerProcessTransport(
            configuration: .init(
                executable: executableURL.path,
                arguments: [],
                environment: [
                    "STARTED_PATH": startedURL.path,
                    "RESPONSE_PATH": responseURL.path,
                ],
                codexHomeURL: rootURL.appendingPathComponent("codex-home", isDirectory: true)
            ),
            connectionEventHub: ConnectionEventHub()
        )
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            processTerminationToken: transport.processTerminationToken,
            handler: { _ in
                try Data().write(to: startedURL)
                do {
                    try await Task.sleep(for: .seconds(3_600))
                    return .approval(.accept)
                } catch {
                    await cancellationObserved.signal()
                    throw error
                }
            }
        )

        await cancellationObserved.wait()
        #expect(FileManager.default.fileExists(atPath: responseURL.path) == false)
        await harness.close()
        #expect(FileManager.default.fileExists(atPath: responseURL.path) == false)
    }

    @Test func handlerOwnedConnectionCloseReturnsThenSupervisorFinishesFullClose() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executableURL = rootURL.appendingPathComponent("fake-app-server")
        let readyURL = rootURL.appendingPathComponent("ready")
        let responseURL = rootURL.appendingPathComponent("response.json")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try """
            #!/bin/sh
            while [ ! -f "$READY_PATH" ]; do :; done
            printf '%s\\n' '{"id":"self-close","method":"item/commandExecution/requestApproval","params":{"threadId":"thread","turnId":"turn","itemId":"item","startedAtMs":1}}'
            if IFS= read -r line; then
                printf '%s\\n' "$line" > "$RESPONSE_PATH"
            fi
            """
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let leaseBox = RegistryTestConnectionLeaseBox()
        let handlerReturned = RegistryTestCountSignal(target: 1)
        let transport = try AppServerProcessTransport(
            configuration: .init(
                executable: executableURL.path,
                arguments: [],
                environment: [
                    "READY_PATH": readyURL.path,
                    "RESPONSE_PATH": responseURL.path,
                ],
                codexHomeURL: rootURL.appendingPathComponent("codex-home", isDirectory: true)
            ),
            connectionEventHub: ConnectionEventHub()
        )
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            processTerminationToken: transport.processTerminationToken,
            handler: { _ in
                await leaseBox.value()?.closeConnection()
                await handlerReturned.signal()
                return .approval(.accept)
            }
        )
        leaseBox.set(harness.lease)
        try Data().write(to: readyURL)

        await handlerReturned.wait()
        #expect(FileManager.default.fileExists(atPath: responseURL.path) == false)

        await harness.supervisor.waitUntilClosed()
        #expect(await harness.supervisor.serverRequestChildCount() == 0)
        #expect(FileManager.default.fileExists(atPath: responseURL.path) == false)
    }

    private func commandApprovalParams(itemID: String = "item") -> Data {
        Data(
            #"{"threadId":"thread","turnId":"turn","itemId":"\#(itemID)","startedAtMs":1}"#.utf8
        )
    }

    private func jsonResult(
        from response: CodexServerRequestResponse
    ) throws -> [String: String] {
        guard case .result(let data) = response else {
            throw RegistryTestFailure.unexpectedResponse
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}

private enum RegistryTestFailure: Error {
    case handler
    case unexpectedResponse
}

private actor RegistryTestCountSignal {
    private let target: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: Int) {
        self.target = target
    }

    func signal() {
        count += 1
        guard count >= target else {
            return
        }
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard count < target else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor RegistryTestManualGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class RegistryTestThreadSafeSignal: Sendable {
    private enum State {
        case pending([CheckedContinuation<Void, Never>])
        case signalled
    }

    private let state = Mutex<State>(.pending([]))

    func signal() {
        let waiters = state.withLock { state in
            switch state {
            case .pending(let waiters):
                state = .signalled
                return waiters
            case .signalled:
                return []
            }
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let isSignalled = state.withLock { state in
                switch state {
                case .pending(var waiters):
                    waiters.append(continuation)
                    state = .pending(waiters)
                    return false
                case .signalled:
                    return true
                }
            }
            if isSignalled {
                continuation.resume()
            }
        }
    }
}

private final class RegistryTestSuspension: Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}

private final class RegistryTestInjectorBox: Sendable {
    private let storage = Mutex<CodexAppServerTestServerRequestInjector?>(nil)

    func set(_ injector: CodexAppServerTestServerRequestInjector) {
        storage.withLock { $0 = injector }
    }

    func value() -> CodexAppServerTestServerRequestInjector? {
        storage.withLock { $0 }
    }
}

private final class RegistryTestConnectionLeaseBox: Sendable {
    private let storage = Mutex<AppServerConnectionLease?>(nil)

    func set(_ lease: AppServerConnectionLease) {
        storage.withLock { $0 = lease }
    }

    func value() -> AppServerConnectionLease? {
        storage.withLock { $0 }
    }
}
