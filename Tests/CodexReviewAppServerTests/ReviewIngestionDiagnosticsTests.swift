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
            originalRawByteCount: 0,
            capturedRawByteCount: 0,
            capturedBase64Length: 0,
            chunkCount: 0,
            isTruncated: false
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
            originalRawByteCount: 384,
            capturedRawByteCount: 384,
            capturedBase64Length: 512,
            chunkCount: 1,
            isTruncated: false
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
            originalRawByteCount: 385,
            capturedRawByteCount: 385,
            capturedBase64Length: 516,
            chunkCount: 2,
            isTruncated: false
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

    @Test func overBudgetPayloadReportsAndReconstructsItsExactCapturedPrefix() {
        let rawParams = Data(
            (0..<(ReviewIngestionDiagnosticLogPlan.maximumCapturedRawByteCount + 257))
                .map { UInt8(truncatingIfNeeded: $0) }
        )
        let plan = ReviewIngestionDiagnosticLogPlan(
            rawParams: rawParams,
            recordID: recordID
        )

        #expect(plan.header == .init(
            recordID: recordID,
            originalRawByteCount: rawParams.count,
            capturedRawByteCount: 12_288,
            capturedBase64Length: 16_384,
            chunkCount: 32,
            isTruncated: true
        ))
        #expect(plan.chunks.map(\.index) == Array(0..<32))
        #expect(plan.chunks.allSatisfy { $0.count == 32 })
        expectExactReconstruction(plan, of: rawParams)
    }

    @Test func repeatedPlansNeverExceedTheSynchronousChunkBudget() {
        let rawParams = Data(
            repeating: 0xC3,
            count: ReviewIngestionDiagnosticLogPlan.maximumCapturedRawByteCount * 8
        )

        for iteration in 0..<64 {
            let plan = ReviewIngestionDiagnosticLogPlan(
                rawParams: rawParams,
                recordID: "\(recordID)-\(iteration)"
            )

            #expect(plan.chunks.count <= ReviewIngestionDiagnosticLogPlan.maximumChunkCount)
            #expect(plan.header.chunkCount <= ReviewIngestionDiagnosticLogPlan.maximumChunkCount)
            #expect(plan.header.capturedRawByteCount
                <= ReviewIngestionDiagnosticLogPlan.maximumCapturedRawByteCount)
        }
    }

    private func expectExactReconstruction(
        _ plan: ReviewIngestionDiagnosticLogPlan,
        of rawParams: Data
    ) {
        let expectedCapture = Data(
            rawParams.prefix(ReviewIngestionDiagnosticLogPlan.maximumCapturedRawByteCount)
        )
        #expect(plan.header.recordID == recordID)
        #expect(plan.header.originalRawByteCount == rawParams.count)
        #expect(plan.header.capturedRawByteCount == expectedCapture.count)
        #expect(plan.header.isTruncated == (rawParams.count > expectedCapture.count))
        #expect(plan.header.chunkCount == plan.chunks.count)
        #expect(plan.header.chunkCount <= ReviewIngestionDiagnosticLogPlan.maximumChunkCount)
        #expect(plan.chunks.allSatisfy {
            $0.base64.utf8.count <= ReviewIngestionDiagnosticLogPlan.maximumBase64ChunkLength
        })

        let base64 = plan.chunks.map(\.base64).joined()
        #expect(plan.header.capturedBase64Length == base64.utf8.count)
        #expect(Data(base64Encoded: base64) == expectedCapture)
    }
}
