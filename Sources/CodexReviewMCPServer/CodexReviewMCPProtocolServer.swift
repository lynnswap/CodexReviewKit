import Foundation
import MCP
import CodexReviewKit
import CodexReviewMCPAdapter

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
    defaultSessionID: String? = nil,
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
        let tools = await adapter.tools.map { descriptor in
            Tool(
                name: descriptor.name.rawValue,
                description: descriptor.description,
                inputSchema: schema(for: descriptor.name)
            )
        }
        return .init(tools: tools)
    }

    await server.withMethodHandler(CallTool.self) { params in
        guard let tool = CodexReviewMCP.Tool.Name(rawValue: params.name) else {
            return .init(
                content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        do {
            let httpContext = Server.currentHandlerContext?.httpContext
            let useBoundedReviewStart = await clientSession.usesBoundedReviewStart(httpContext: httpContext)
            let request = try toolRequest(
                tool: tool,
                arguments: params.arguments ?? [:],
                defaultSessionID: defaultSessionID,
                boundedReviewWaitDuration: boundedReviewWaitDuration,
                useBoundedReviewStart: useBoundedReviewStart
            )
            let response = try await adapter.handle(request)
            return try toolResult(response: response)
        } catch {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    await server.withMethodHandler(ListResources.self) { _ in
        .init(resources: helpResources.map(\.resource))
    }

    await server.withMethodHandler(ReadResource.self) { params in
        let content = helpResources.first { $0.uri == params.uri }?.content
            ?? "Resource not found: \(params.uri)"
        return .init(contents: [.text(content, uri: params.uri, mimeType: "text/markdown")])
    }

    await server.withMethodHandler(ListResourceTemplates.self) { _ in
        .init(templates: helpResourceTemplates)
    }

    return server
}
