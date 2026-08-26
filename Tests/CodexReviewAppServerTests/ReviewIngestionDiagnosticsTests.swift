import Foundation
import Testing
@testable import CodexReviewAppServer

@Suite("review ingestion diagnostic log plan")
struct ReviewIngestionDiagnosticLogPlanTests {
    private let recordID = "00000000-0000-0000-0000-000000000001"

    @Test func emptyPayloadNeedsNoChunk() {
        let rawParams = Data()
        let plan = ReviewIngestionDiagnosticLogPlan(
            rawParams: rawParams,
            recordID: recordID
        )

        #expect(plan.header == .init(
            recordID: recordID,
            rawByteCount: 0,
            rawBase64Length: 0,
            chunkCount: 0
        ))
        #expect(plan.chunks.isEmpty)
        expectExactReconstruction(plan, of: rawParams)
    }

    @Test func payloadAtChunkBoundaryUsesOneBoundedChunk() {
        let rawParams = Data(repeating: 0xA5, count: 384)
        let plan = ReviewIngestionDiagnosticLogPlan(
            rawParams: rawParams,
            recordID: recordID
        )

        #expect(plan.header == .init(
            recordID: recordID,
            rawByteCount: 384,
            rawBase64Length: 512,
            chunkCount: 1
        ))
        #expect(plan.chunks.map(\.index) == [0])
        #expect(plan.chunks.map(\.count) == [1])
        #expect(plan.chunks.first?.base64.utf8.count == 512)
        expectExactReconstruction(plan, of: rawParams)
    }

    @Test func payloadPastChunkBoundaryUsesExplicitZeroBasedIndices() {
        let rawParams = Data(repeating: 0x5A, count: 385)
        let plan = ReviewIngestionDiagnosticLogPlan(
            rawParams: rawParams,
            recordID: recordID
        )

        #expect(plan.header == .init(
            recordID: recordID,
            rawByteCount: 385,
            rawBase64Length: 516,
            chunkCount: 2
        ))
        #expect(plan.chunks.map(\.recordID) == [recordID, recordID])
        #expect(plan.chunks.map(\.index) == [0, 1])
        #expect(plan.chunks.map(\.count) == [2, 2])
        #expect(plan.chunks.map { $0.base64.utf8.count } == [512, 4])
        expectExactReconstruction(plan, of: rawParams)
    }

    @Test func unicodeAndRawBinaryRoundTripThroughASCIIChunks() {
        var rawParams = Data(#"{"message":"こんにちは🌏"}"#.utf8)
        rawParams.append(contentsOf: [0x00, 0x7F, 0x80, 0xFF])
        let plan = ReviewIngestionDiagnosticLogPlan(
            rawParams: rawParams,
            recordID: recordID
        )

        #expect(plan.chunks.allSatisfy { $0.base64.utf8.allSatisfy { $0 < 0x80 } })
        expectExactReconstruction(plan, of: rawParams)
    }

    private func expectExactReconstruction(
        _ plan: ReviewIngestionDiagnosticLogPlan,
        of rawParams: Data
    ) {
        #expect(plan.header.recordID == recordID)
        #expect(plan.header.rawByteCount == rawParams.count)
        #expect(plan.header.chunkCount == plan.chunks.count)
        #expect(plan.chunks.allSatisfy {
            $0.base64.utf8.count <= ReviewIngestionDiagnosticLogPlan.maximumBase64ChunkLength
        })

        let base64 = plan.chunks.map(\.base64).joined()
        #expect(plan.header.rawBase64Length == base64.utf8.count)
        #expect(Data(base64Encoded: base64) == rawParams)
    }
}
