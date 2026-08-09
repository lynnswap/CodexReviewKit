import Foundation
import Testing

@testable import CodexAppServerKit

@Suite("JSON-RPC envelope codec")
struct JSONRPCEnvelopeCodecTests {
    @Test func responseRequiresExactlyOneResultOrError() throws {
        for json in [
            #"{"id":1}"#,
            #"{"id":1,"result":{},"error":{"code":-1,"message":"failure"}}"#,
        ] {
            let data = Data(json.utf8)
            do {
                _ = try JSONRPC.decodeInboundEnvelope(data)
                Issue.record("Expected a protocol violation for \(json).")
            } catch let failure as CodexTransportFailure {
                guard case .protocolViolation(_, let rawData) = failure else {
                    Issue.record("Expected a protocol violation, got \(failure).")
                    continue
                }
                #expect(rawData == data)
            }
        }
    }

    @Test func responseRequiresStrictErrorShape() throws {
        for json in [
            #"{"id":1,"error":null}"#,
            #"{"id":1,"error":[]}"#,
            #"{"id":1,"error":{"message":"failure"}}"#,
            #"{"id":1,"error":{"code":"-1","message":"failure"}}"#,
            #"{"id":1,"error":{"code":true,"message":"failure"}}"#,
            #"{"id":1,"error":{"code":1.5,"message":"failure"}}"#,
            #"{"id":1,"error":{"code":1e100,"message":"failure"}}"#,
            #"{"id":1,"error":{"code":-1}}"#,
            #"{"id":1,"error":{"code":-1,"message":false}}"#,
        ] {
            let data = Data(json.utf8)
            do {
                _ = try JSONRPC.decodeInboundEnvelope(data)
                Issue.record("Expected a protocol violation for \(json).")
            } catch let failure as CodexTransportFailure {
                guard case .protocolViolation(_, let rawData) = failure else {
                    Issue.record("Expected a protocol violation, got \(failure).")
                    continue
                }
                #expect(rawData == data)
            }
        }
    }

    @Test func responseRequiresExactIntegerID() throws {
        for json in [
            #"{"id":true,"result":{}}"#,
            #"{"id":1.5,"result":{}}"#,
            #"{"id":1e100,"result":{}}"#,
        ] {
            let data = Data(json.utf8)
            #expect(throws: CodexTransportFailure.self) {
                _ = try JSONRPC.decodeInboundEnvelope(data)
            }
        }
    }

    @Test func responsePreservesJSONNullPayloads() throws {
        let resultFrame = Data(#"{"id":1,"result":null}"#.utf8)
        guard case .response(1, .success(let result)) = try JSONRPC.decodeInboundEnvelope(
            resultFrame
        ) else {
            Issue.record("Expected a successful response.")
            return
        }
        #expect(result == Data("null".utf8))

        let errorFrame = Data(
            #"{"id":2,"error":{"code":-32000,"message":"failure","data":null}}"#.utf8
        )
        guard case .response(2, .failure(.responseError(let error))) =
            try JSONRPC.decodeInboundEnvelope(errorFrame) else {
            Issue.record("Expected an error response.")
            return
        }
        #expect(error.data == Data("null".utf8))
        #expect(try AppServerProcessTransport.responsePayloadData(from: NSNull()) == Data("null".utf8))
    }
}
