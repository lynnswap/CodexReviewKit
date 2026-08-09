import Foundation

package enum CodexServerRequestResponse: Equatable, Sendable {
    case result(Data)
    case error(code: Int, message: String)
}

package struct CodexAppServerRequestCodec: Sendable {
    package init() {}

    package func decode(method: String, params: Data) throws -> CodexAppServerRequest {
        let decoder = JSONDecoder()
        return switch method {
        case "item/commandExecution/requestApproval":
            .commandExecutionApproval(
                try decoder.decode(CodexCommandExecutionApprovalRequest.self, from: params)
            )
        case "item/fileChange/requestApproval":
            .fileChangeApproval(
                try decoder.decode(CodexFileChangeApprovalRequest.self, from: params)
            )
        case "item/tool/requestUserInput":
            .userInput(try decoder.decode(CodexUserInputRequest.self, from: params))
        case "mcpServer/elicitation/request":
            .mcpElicitation(try decoder.decode(CodexMCPElicitationRequest.self, from: params))
        case "item/permissions/requestApproval":
            .permissions(try decoder.decode(CodexPermissionsRequest.self, from: params))
        case "item/tool/call":
            .dynamicToolCall(try decoder.decode(CodexDynamicToolCallRequest.self, from: params))
        case "account/chatgptAuthTokens/refresh":
            .chatGPTAuthTokensRefresh(
                try decoder.decode(CodexChatGPTAuthTokensRefreshRequest.self, from: params)
            )
        case "attestation/generate":
            .attestationGenerate(
                try decoder.decode(CodexAttestationGenerateRequest.self, from: params)
            )
        case "currentTime/read":
            .currentTimeRead(try decoder.decode(CodexCurrentTimeReadRequest.self, from: params))
        default:
            .unknown(.init(method: method, params: params))
        }
    }

    package func response(
        to request: CodexAppServerRequest,
        resolution: CodexAppServerRequestResolution
    ) -> CodexServerRequestResponse {
        do {
            let encoder = JSONEncoder()
            switch (request, resolution) {
            case (.commandExecutionApproval, .approval(let decision)):
                return .result(try encoder.encode(ApprovalResponse(decision: decision)))
            case (.fileChangeApproval, .approval(let decision))
                where decision.isValidForFileChange:
                return .result(try encoder.encode(ApprovalResponse(decision: decision)))
            case (.userInput, .userInput(let response)):
                return .result(try encoder.encode(response))
            case (.mcpElicitation, .mcpElicitation(let response)):
                return .result(try encoder.encode(response))
            case (.permissions, .permissions(let response)):
                return .result(try encoder.encode(response))
            case (.dynamicToolCall, .dynamicToolCall(let response)):
                return .result(try encoder.encode(response))
            case (.chatGPTAuthTokensRefresh, .chatGPTAuthTokensRefresh(let response)):
                return .result(try encoder.encode(response))
            case (.attestationGenerate, .attestationGenerate(let response)):
                return .result(try encoder.encode(response))
            case (.currentTimeRead, .currentTimeRead(let response)):
                return .result(try encoder.encode(response))
            case (_, .rejectUnknown(let code, let message)):
                return .error(code: code, message: message)
            default:
                return Self.internalError(
                    "Server request resolution does not match \(request.method)."
                )
            }
        } catch {
            return Self.internalError(
                "Failed to encode response for \(request.method): \(error.localizedDescription)"
            )
        }
    }

    package func handle(
        _ request: CodexAppServerRequest,
        using handler: CodexAppServerRequestHandler
    ) async -> CodexServerRequestResponse {
        do {
            return response(to: request, resolution: try await handler(request))
        } catch {
            return Self.internalError(
                "Handler failed for \(request.method): \(error.localizedDescription)"
            )
        }
    }

    package static func builtInResolution(
        for request: CodexAppServerRequest,
        clock: CodexAppServerClock
    ) -> CodexAppServerRequestResolution {
        switch request {
        case .commandExecutionApproval, .fileChangeApproval:
            .approval(.decline)
        case .userInput:
            .userInput(.init(answers: [:]))
        case .mcpElicitation:
            .mcpElicitation(.init(action: .cancel, content: nil, meta: nil))
        case .permissions:
            .permissions(.init(
                permissions: .init(network: nil, fileSystem: nil),
                scope: .turn,
                strictAutoReview: false
            ))
        case .dynamicToolCall:
            .dynamicToolCall(.init(
                contentItems: [
                    .inputText(text: "Dynamic tool calls are not supported by this client."),
                ],
                success: false
            ))
        case .chatGPTAuthTokensRefresh, .attestationGenerate:
            .rejectUnknown(
                code: -32601,
                message: "No client provider is configured for \(request.method)."
            )
        case .currentTimeRead:
            .currentTimeRead(.init(
                currentTimeAt: Int64(clock.now().timeIntervalSince1970.rounded(.down))
            ))
        case .unknown:
            .rejectUnknown(code: -32601, message: "Method not found: \(request.method)")
        }
    }

    package static func internalError(_ message: String) -> CodexServerRequestResponse {
        .error(code: -32603, message: message)
    }

    private struct ApprovalResponse: Encodable {
        var decision: CodexApprovalDecision
    }
}
