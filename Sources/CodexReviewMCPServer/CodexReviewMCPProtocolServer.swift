import Foundation
import MCP
import CodexReviewKit

package actor MCPClientSessionState {
    private var clientInfo: Client.Info?

    package init() {}

    package func update(clientInfo: Client.Info) {
        self.clientInfo = clientInfo
    }

    package func usesBoundedReviewStart(httpContext: HTTPRequest?) -> Bool {
        if Self.isClaudeClientName(clientInfo?.name)
            || Self.isClaudeClientName(clientInfo?.title)
            || Self.isClaudeClientName(httpContext?.header("User-Agent"))
        {
            return true
        }
        return false
    }

    private static func isClaudeClientName(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return value.localizedCaseInsensitiveContains("claude")
    }
}

@MainActor
package func makeMCPProtocolServer(
    adapter: CodexReviewMCPServer,
    sessionID: String,
    sessionRegistry: MCPReviewSessionRegistry,
    clientSession: MCPClientSessionState = .init(),
    boundedReviewWaitDuration: Duration = .seconds(540)
) async -> Server {
    let server = Server(
        name: "codex_review",
        version: "0.1.0",
        capabilities: .init(
            resources: .init(listChanged: true),
            tools: .init(listChanged: true)
        )
    )

    await server.withMethodHandler(ListTools.self) { _ in
        try await withMCPSessionOperation(registry: sessionRegistry, sessionID: sessionID) { _ in
            let tools = await adapter.tools.map { descriptor in
                Tool(
                    name: descriptor.name.rawValue,
                    description: descriptor.description,
                    inputSchema: schema(for: descriptor.name)
                )
            }
            return .init(tools: tools)
        }
    }

    await server.withMethodHandler(CallTool.self) { params in
        await withMCPSessionOperationResult(
            registry: sessionRegistry,
            sessionID: sessionID
        ) { operation in
            guard let tool = CodexReviewMCP.Tool.Name(rawValue: params.name) else {
                return .init(
                    content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            let httpContext = Server.currentHandlerContext?.httpContext
            let useBoundedReviewStart = await clientSession.usesBoundedReviewStart(httpContext: httpContext)
            let request = try toolRequest(
                tool: tool,
                arguments: params.arguments ?? [:],
                defaultSessionID: sessionID,
                boundedReviewWaitDuration: boundedReviewWaitDuration,
                useBoundedReviewStart: useBoundedReviewStart
            )
            let response: CodexReviewMCP.Tool.Response
            if case .reviewStart = request {
                response = try await handleReviewStart(
                    request,
                    sessionID: sessionID,
                    registry: sessionRegistry,
                    adapter: adapter
                )
            } else {
                let allowedRunIDs = try await sessionRegistry.members(for: operation)
                response = try await adapter.handle(
                    request,
                    allowedRunIDs: allowedRunIDs
                )
            }
            return try toolResult(response: response)
        }
    }

    await server.withMethodHandler(ListResources.self) { _ in
        try await withMCPSessionOperation(registry: sessionRegistry, sessionID: sessionID) { _ in
            .init(resources: helpResources.map(\.resource))
        }
    }

    await server.withMethodHandler(ReadResource.self) { params in
        try await withMCPSessionOperation(registry: sessionRegistry, sessionID: sessionID) { _ in
            let content = helpResources.first { $0.uri == params.uri }?.content
                ?? "Resource not found: \(params.uri)"
            return .init(contents: [.text(content, uri: params.uri, mimeType: "text/markdown")])
        }
    }

    await server.withMethodHandler(ListResourceTemplates.self) { _ in
        try await withMCPSessionOperation(registry: sessionRegistry, sessionID: sessionID) { _ in
            .init(templates: helpResourceTemplates)
        }
    }

    return server
}

private func withMCPSessionOperation<Result: Sendable>(
    registry: MCPReviewSessionRegistry,
    sessionID: String,
    operation: @Sendable (MCPSessionOperationToken) async throws -> Result
) async throws -> Result {
    let token = try await registry.beginOperation(in: sessionID)
    let result: Result
    do {
        result = try await operation(token)
    } catch {
        try await registry.finishOperation(token)
        throw error
    }
    try await registry.finishOperation(token)
    return result
}

private func withMCPSessionOperationResult(
    registry: MCPReviewSessionRegistry,
    sessionID: String,
    operation: @Sendable (MCPSessionOperationToken) async throws -> CallTool.Result
) async -> CallTool.Result {
    do {
        return try await withMCPSessionOperation(
            registry: registry,
            sessionID: sessionID,
            operation: operation
        )
    } catch {
        return .init(
            content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

private func handleReviewStart(
    _ request: CodexReviewMCP.Tool.Request,
    sessionID: String,
    registry: MCPReviewSessionRegistry,
    adapter: CodexReviewMCPServer
) async throws -> CodexReviewMCP.Tool.Response {
    guard case .reviewStart(_, let reviewRequest, let waitTimeout) = request else {
        preconditionFailure("Only review_start can enter the start reservation path.")
    }
    let reservation = try await registry.reserveStart(in: sessionID)
    var reservationIsPending = true
    do {
        let runID = try await adapter.beginReview(
            sessionID: sessionID,
            request: reviewRequest
        )
        let disposition = try await registry.bind(
            runID: runID,
            reservation: reservation
        )
        reservationIsPending = false
        guard case .bound = disposition else {
            throw MCPReviewSessionRegistryError.sessionNotOpen(sessionID)
        }
        return try await adapter.finishReviewStart(
            sessionID: sessionID,
            runID: runID,
            waitTimeout: waitTimeout
        )
    } catch {
        if reservationIsPending {
            try await registry.finishStart(reservation)
        }
        throw error
    }
}
