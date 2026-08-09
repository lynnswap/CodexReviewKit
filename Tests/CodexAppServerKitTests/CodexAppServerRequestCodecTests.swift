import Foundation
import Testing

@testable import CodexAppServerKit

@Suite("Typed server-request codec")
struct CodexAppServerRequestCodecTests {
    private let codec = CodexAppServerRequestCodec()

    @Test func serverRequestIDsPreserveIntegerAndStringJSONTypes() throws {
        for id in [CodexServerRequestID.integer(Int64.max), .string("request-7")] {
            let encoded = try JSONEncoder().encode(id)
            #expect(try JSONDecoder().decode(CodexServerRequestID.self, from: encoded) == id)

            let payload = try AppServerProcessTransport.serverRequestResponsePayload(
                id: id,
                response: .result(Data("{}".utf8))
            )
            let object = try #require(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            switch id {
            case .integer(let value):
                #expect((object["id"] as? NSNumber)?.int64Value == value)
            case .string(let value):
                #expect(object["id"] as? String == value)
            }
        }
    }

    @Test func decodesCurrentV2InventoryAndPreservesUnknown() throws {
        let fixtures: [(String, String, RequestKind)] = [
            (
                "item/commandExecution/requestApproval",
                #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":1,"availableDecisions":["decline",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["git","status"]}}]}"#,
                .commandApproval
            ),
            (
                "item/fileChange/requestApproval",
                #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","startedAtMs":2,"grantRoot":"/tmp"}"#,
                .fileApproval
            ),
            (
                "item/tool/requestUserInput",
                #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"q1","header":"Choice","question":"Pick one","isOther":false,"isSecret":false,"options":null}],"autoResolutionMs":1000}"#,
                .userInput
            ),
            (
                "mcpServer/elicitation/request",
                #"{"threadId":"thread-1","turnId":null,"serverName":"server","mode":"form","_meta":null,"message":"Value?","requestedSchema":{"type":"object"}}"#,
                .mcpElicitation
            ),
            (
                "item/permissions/requestApproval",
                #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","environmentId":null,"startedAtMs":3,"cwd":"/tmp","reason":null,"permissions":{}}"#,
                .permissions
            ),
            (
                "item/tool/call",
                #"{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","namespace":null,"tool":"lookup","arguments":{"key":"value"}}"#,
                .dynamicToolCall
            ),
            (
                "account/chatgptAuthTokens/refresh",
                #"{"reason":"unauthorized","previousAccountId":"account-1"}"#,
                .tokenRefresh
            ),
            ("attestation/generate", #"{}"#, .attestation),
            ("currentTime/read", #"{"threadId":"thread-1"}"#, .currentTime),
            ("future/method", #"{"opaque":true}"#, .unknown),
        ]

        for (method, json, expectedKind) in fixtures {
            let data = Data(json.utf8)
            let request = try codec.decode(method: method, params: data)
            #expect(kind(of: request) == expectedKind)
            #expect(request.method == method)
            if case .commandExecutionApproval(let approval) = request {
                #expect(approval.availableDecisions == [
                    .decline,
                    .acceptWithExecpolicyAmendment(.init(command: ["git", "status"])),
                ])
            }
            if case .mcpElicitation(let elicitation) = request {
                guard case .form(_, let message, let schema) = elicitation.elicitation else {
                    Issue.record("Expected the MCP form tagged variant.")
                    continue
                }
                #expect(message == "Value?")
                #expect(schema == .object(["type": .string("object")]))
            }
            if case .unknown(let raw) = request {
                #expect(raw.params == data)
            }
        }
    }

    @Test func mcpElicitationRejectsInvalidTaggedPayloads() throws {
        #expect(throws: DecodingError.self) {
            try decode(
                "mcpServer/elicitation/request",
                #"{"threadId":"thread-1","turnId":null,"serverName":"server","mode":"url","_meta":null,"message":"Open"}"#
            )
        }
        #expect(throws: DecodingError.self) {
            try decode(
                "mcpServer/elicitation/request",
                #"{"threadId":"thread-1","turnId":null,"serverName":"server","mode":"future","_meta":null,"message":"Unknown"}"#
            )
        }
    }

    @Test func builtInPolicyProducesExactCurrentV2Responses() throws {
        let clock = CodexAppServerClock {
            Date(timeIntervalSince1970: 1_700_000_000.75)
        }
        let cases: [(CodexAppServerRequest, String)] = [
            (
                try decode(
                    "item/commandExecution/requestApproval",
                    #"{"threadId":"t","turnId":"u","itemId":"i","startedAtMs":1}"#
                ),
                #"{"decision":"decline"}"#
            ),
            (
                try decode(
                    "item/fileChange/requestApproval",
                    #"{"threadId":"t","turnId":"u","itemId":"i","startedAtMs":1,"reason":null,"grantRoot":null}"#
                ),
                #"{"decision":"decline"}"#
            ),
            (
                try decode(
                    "item/tool/requestUserInput",
                    #"{"threadId":"t","turnId":"u","itemId":"i","questions":[],"autoResolutionMs":null}"#
                ),
                #"{"answers":{}}"#
            ),
            (
                try decode(
                    "mcpServer/elicitation/request",
                    #"{"threadId":"t","turnId":null,"serverName":"s","mode":"url","_meta":null,"message":"m","requestedSchema":null,"url":"https://example.com","elicitationId":"e"}"#
                ),
                #"{"action":"cancel","content":null,"_meta":null}"#
            ),
            (
                try decode(
                    "item/permissions/requestApproval",
                    #"{"threadId":"t","turnId":"u","itemId":"i","environmentId":null,"startedAtMs":1,"cwd":"/tmp","reason":null,"permissions":{}}"#
                ),
                #"{"permissions":{},"scope":"turn","strictAutoReview":false}"#
            ),
            (
                try decode(
                    "item/tool/call",
                    #"{"threadId":"t","turnId":"u","callId":"c","namespace":null,"tool":"x","arguments":{}}"#
                ),
                #"{"contentItems":[{"type":"inputText","text":"Dynamic tool calls are not supported by this client."}],"success":false}"#
            ),
            (
                try decode("currentTime/read", #"{"threadId":"t"}"#),
                #"{"currentTimeAt":1700000000}"#
            ),
        ]

        for (request, expectedJSON) in cases {
            let resolution = CodexAppServerRequestCodec.builtInResolution(
                for: request,
                clock: clock
            )
            let response = codec.response(to: request, resolution: resolution)
            let data = try resultData(from: response)
            #expect(try jsonEqual(data, Data(expectedJSON.utf8)))
        }
    }

    @Test func builtInPolicyRejectsProviderlessAndUnknownMethods() throws {
        let clock = CodexAppServerClock(now: { .distantPast })
        let requests = [
            (
                try decode(
                    "account/chatgptAuthTokens/refresh",
                    #"{"reason":"unauthorized","previousAccountId":null}"#
                ),
                "No client provider is configured for account/chatgptAuthTokens/refresh."
            ),
            (
                try decode("attestation/generate", #"{}"#),
                "No client provider is configured for attestation/generate."
            ),
            (
                try decode("future/method", #"{}"#),
                "Method not found: future/method"
            ),
        ]

        for (request, expectedMessage) in requests {
            let resolution = CodexAppServerRequestCodec.builtInResolution(
                for: request,
                clock: clock
            )
            guard case .error(let code, let message) = codec.response(
                to: request,
                resolution: resolution
            ) else {
                Issue.record("Expected method-not-found for \(request.method).")
                continue
            }
            #expect(code == -32601)
            #expect(message == expectedMessage)

            let payload = try AppServerProcessTransport.serverRequestResponsePayload(
                id: .string("request"),
                response: .error(code: code, message: message)
            )
            let expected = Data(
                #"{"id":"request","error":{"code":-32601,"message":"\#(expectedMessage)"}}"#.utf8
            )
            #expect(try jsonEqual(payload, expected))
        }
    }

    @Test func mismatchHandlerFailureAndEncodeFailureAreInternalErrors() async throws {
        let request = try decode("currentTime/read", #"{"threadId":"t"}"#)
        guard case .error(let mismatchCode, _) = codec.response(
            to: request,
            resolution: .approval(.accept)
        ) else {
            Issue.record("Expected an internal error for a resolution mismatch.")
            return
        }
        #expect(mismatchCode == -32603)

        let handled = await codec.handle(request) { _ in
            throw HandlerFailure()
        }
        guard case .error(let handlerCode, _) = handled else {
            Issue.record("Expected an internal error for a thrown handler error.")
            return
        }
        #expect(handlerCode == -32603)

        let permissions = try decode(
            "item/permissions/requestApproval",
            #"{"threadId":"t","turnId":"u","itemId":"i","environmentId":null,"startedAtMs":1,"cwd":"/tmp","reason":null,"permissions":{}}"#
        )
        let encodeFailure = codec.response(
            to: permissions,
            resolution: .permissions(.init(
                permissions: .init(network: .double(.infinity), fileSystem: nil),
                scope: .turn,
                strictAutoReview: false
            ))
        )
        guard case .error(let encodeCode, _) = encodeFailure else {
            Issue.record("Expected an internal error for response encoding failure.")
            return
        }
        #expect(encodeCode == -32603)
    }

    @Test func methodSpecificResponsesMatchCurrentV2TaggedAndNullShapes() throws {
        let command = try decode(
            "item/commandExecution/requestApproval",
            #"{"threadId":"t","turnId":"u","itemId":"i","startedAtMs":1}"#
        )
        let execPolicyResponse = codec.response(
            to: command,
            resolution: .approval(.acceptWithExecpolicyAmendment(
                .init(command: ["git", "status"])
            ))
        )
        #expect(try jsonEqual(
            resultData(from: execPolicyResponse),
            Data(
                #"{"decision":{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["git","status"]}}}"#.utf8
            )
        ))

        let networkPolicyResponse = codec.response(
            to: command,
            resolution: .approval(.applyNetworkPolicyAmendment(.init(
                host: "example.com",
                action: .allow
            )))
        )
        #expect(try jsonEqual(
            resultData(from: networkPolicyResponse),
            Data(
                #"{"decision":{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"example.com","action":"allow"}}}}"#.utf8
            )
        ))

        let file = try decode(
            "item/fileChange/requestApproval",
            #"{"threadId":"t","turnId":"u","itemId":"i","startedAtMs":1}"#
        )
        guard case .error(let fileMismatchCode, _) = codec.response(
            to: file,
            resolution: .approval(.acceptWithExecpolicyAmendment(.init(command: ["git"])))
        ) else {
            Issue.record("Expected command-only approval to be rejected for file changes.")
            return
        }
        #expect(fileMismatchCode == -32603)

        let refresh = try decode(
            "account/chatgptAuthTokens/refresh",
            #"{"reason":"unauthorized","previousAccountId":null}"#
        )
        let refreshResponse = codec.response(
            to: refresh,
            resolution: .chatGPTAuthTokensRefresh(.init(
                accessToken: "access",
                chatGPTAccountID: "account",
                chatGPTPlanType: nil
            ))
        )
        #expect(try jsonEqual(
            resultData(from: refreshResponse),
            Data(
                #"{"accessToken":"access","chatgptAccountId":"account","chatgptPlanType":null}"#.utf8
            )
        ))
    }

    private func decode(_ method: String, _ json: String) throws -> CodexAppServerRequest {
        try codec.decode(method: method, params: Data(json.utf8))
    }

    private func resultData(from response: CodexServerRequestResponse) throws -> Data {
        guard case .result(let data) = response else {
            throw UnexpectedResponse()
        }
        return data
    }

    private func jsonEqual(_ lhs: Data, _ rhs: Data) throws -> Bool {
        let left = try JSONSerialization.jsonObject(with: lhs, options: [.fragmentsAllowed])
        let right = try JSONSerialization.jsonObject(with: rhs, options: [.fragmentsAllowed])
        return (left as AnyObject).isEqual(right)
    }

    private func kind(of request: CodexAppServerRequest) -> RequestKind {
        switch request {
        case .commandExecutionApproval: .commandApproval
        case .fileChangeApproval: .fileApproval
        case .userInput: .userInput
        case .mcpElicitation: .mcpElicitation
        case .permissions: .permissions
        case .dynamicToolCall: .dynamicToolCall
        case .chatGPTAuthTokensRefresh: .tokenRefresh
        case .attestationGenerate: .attestation
        case .currentTimeRead: .currentTime
        case .unknown: .unknown
        }
    }

    private enum RequestKind: Equatable {
        case commandApproval
        case fileApproval
        case userInput
        case mcpElicitation
        case permissions
        case dynamicToolCall
        case tokenRefresh
        case attestation
        case currentTime
        case unknown
    }

    private struct HandlerFailure: Error {}
    private struct UnexpectedResponse: Error {}
}
