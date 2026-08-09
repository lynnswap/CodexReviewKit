import Foundation
import Synchronization

import CodexAppServerKit

package struct CodexAppServerTestServerResponse: Equatable, Sendable {
    package var requestID: CodexServerRequestID
    package var response: CodexServerRequestResponse
}

package actor CodexAppServerTestServerRequestInjector {
    private let transport: CodexAppServerTestTransport
    private let harness: CodexAppServerTestConnectionHarness
    private let diagnosticRecorder: CodexAppServerTestServerRequestDiagnostics
    private var injectedRequestCount = 0

    package init(
        clock: CodexAppServerClock = .init(),
        handler: CodexAppServerRequestHandler? = nil
    ) async {
        let transport = CodexAppServerTestTransport()
        let diagnostics = CodexAppServerTestServerRequestDiagnostics()
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            clock: clock,
            handler: handler,
            diagnosticHandler: { diagnostic in
                diagnostics.record(diagnostic)
            }
        )
        self.transport = transport
        self.harness = harness
        self.diagnosticRecorder = diagnostics
    }

    package func inject(
        id: CodexServerRequestID,
        method: String,
        params: Data
    ) async throws {
        try await transport.emitServerRequest(id: id, method: method, params: params)
        injectedRequestCount += 1
        await harness.connection.waitForServerRequestReceiveCount(
            atLeast: injectedRequestCount
        )
    }

    package func injectAccepted(
        id: CodexServerRequestID,
        method: String,
        params: Data
    ) async throws {
        try await transport.emitServerRequest(id: id, method: method, params: params)
        injectedRequestCount += 1
    }

    package func holdNextInboundEventDelivery(at gate: CodexAppServerTestGate) async {
        await transport.holdNextInboundEventDelivery(at: gate)
    }

    package func waitUntilInboundEventDeliveryIsHeld() async {
        await transport.waitUntilInboundEventDeliveryIsHeld()
    }

    package func waitUntilInjectedRequestsAreDelivered() async {
        await harness.connection.waitForServerRequestReceiveCount(
            atLeast: injectedRequestCount
        )
    }

    package func resolve(_ id: CodexServerRequestID) async throws {
        let params = try JSONEncoder().encode(
            CodexAppServerTestResolvedNotification(
                threadID: "testing",
                requestID: id
            )
        )
        try await transport.emitServerNotification(
            method: "serverRequest/resolved",
            params: params
        )
        await harness.connection.waitUntilServerRequestsIdle()
        await transport.finishServerRequestWithoutResponse(id)
    }

    package func close() async {
        await harness.close()
        await transport.finishAllServerRequestsWithoutResponse()
    }

    package func response(
        for id: CodexServerRequestID
    ) async -> CodexServerRequestResponse? {
        await transport.serverRequestResponse(for: id)
    }

    package func responses() async -> [CodexAppServerTestServerResponse] {
        await transport.recordedServerRequestResponses()
    }

    package func diagnostics() -> [ServerRequestRegistry.Diagnostic] {
        diagnosticRecorder.values()
    }

    package func childCount() async -> Int {
        await harness.supervisor.serverRequestChildCount()
    }

    package func waitUntilIdle() async {
        await harness.connection.waitUntilServerRequestsIdle()
    }
}

private struct CodexAppServerTestResolvedNotification: Encodable {
    var threadID: String
    var requestID: CodexServerRequestID

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case requestID = "requestId"
    }
}

private final class CodexAppServerTestServerRequestDiagnostics: Sendable {
    private let storage = Mutex<[ServerRequestRegistry.Diagnostic]>([])

    func record(_ diagnostic: ServerRequestRegistry.Diagnostic) {
        storage.withLock { $0.append(diagnostic) }
    }

    func values() -> [ServerRequestRegistry.Diagnostic] {
        storage.withLock { $0 }
    }
}
