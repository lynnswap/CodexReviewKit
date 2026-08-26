import CodexReview
import Foundation
import OSLog

private let reviewIngestionLogger = Logger(
    subsystem: "CodexReviewKit",
    category: "review-ingestion"
)

package struct ReviewIngestionDiagnosticRecord: Equatable, Sendable {
    package enum Stage: String, Equatable, Sendable {
        case paramsDecoding
        case schemaValidation
        case payloadDecoding
        case routing
    }

    package enum Disposition: String, Equatable, Sendable {
        case ignored
        case connectionFailed
    }

    package let method: String
    package let threadID: String?
    package let turnID: String?
    package let itemType: String?
    package let rawParams: Data
    package let stage: Stage
    package let error: ReviewIngestionError
    package let disposition: Disposition

    package init(
        method: String,
        threadID: String?,
        turnID: String?,
        itemType: String?,
        rawParams: Data,
        stage: Stage,
        error: ReviewIngestionError,
        disposition: Disposition
    ) {
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.itemType = itemType
        self.rawParams = rawParams
        self.stage = stage
        self.error = error
        self.disposition = disposition
    }
}

package protocol ReviewIngestionDiagnosticRecording: Sendable {
    func record(_ diagnostic: ReviewIngestionDiagnosticRecord)
}

package struct ReviewIngestionDiagnosticLogPlan: Equatable, Sendable {
    // Bound synchronous work on the notification-routing actor before encoding.
    package static let maximumCapturedRawByteCount = 12 * 1_024

    // Keep the variable payload at half of OSLog's 1 KiB message budget so the
    // fixed format, correlation identifier, and decimal counters have headroom.
    package static let maximumBase64ChunkLength = 512
    package static let maximumChunkCount = 32

    package struct Header: Equatable, Sendable {
        package let recordID: String
        package let originalRawByteCount: Int
        package let capturedRawByteCount: Int
        package let capturedBase64Length: Int
        package let chunkCount: Int
        package let isTruncated: Bool
    }

    package struct Chunk: Equatable, Sendable {
        package let recordID: String
        package let index: Int
        package let count: Int
        package let base64: String
    }

    package let header: Header
    package let chunks: [Chunk]

    package init(rawParams: Data, recordID: String) {
        let capturedRawParams = Data(rawParams.prefix(Self.maximumCapturedRawByteCount))
        let encoded = capturedRawParams.base64EncodedData()
        let chunkCount = encoded.isEmpty
            ? 0
            : ((encoded.count - 1) / Self.maximumBase64ChunkLength) + 1
        header = Header(
            recordID: recordID,
            originalRawByteCount: rawParams.count,
            capturedRawByteCount: capturedRawParams.count,
            capturedBase64Length: encoded.count,
            chunkCount: chunkCount,
            isTruncated: capturedRawParams.count != rawParams.count
        )
        chunks = stride(
            from: encoded.startIndex,
            to: encoded.endIndex,
            by: Self.maximumBase64ChunkLength
        ).enumerated().map { index, start in
            let end = min(start + Self.maximumBase64ChunkLength, encoded.endIndex)
            return Chunk(
                recordID: recordID,
                index: index,
                count: chunkCount,
                base64: String(decoding: encoded[start..<end], as: UTF8.self)
            )
        }
    }
}

package struct OSLogReviewIngestionDiagnosticRecorder: ReviewIngestionDiagnosticRecording {
    package init() {}

    package func record(_ diagnostic: ReviewIngestionDiagnosticRecord) {
        let plan = ReviewIngestionDiagnosticLogPlan(
            rawParams: diagnostic.rawParams,
            recordID: UUID().uuidString
        )
        reviewIngestionLogger.error(
            "Review ingestion failed record_id=\(plan.header.recordID, privacy: .public) original_raw_byte_count=\(plan.header.originalRawByteCount, privacy: .private) captured_raw_byte_count=\(plan.header.capturedRawByteCount, privacy: .private) captured_base64_length=\(plan.header.capturedBase64Length, privacy: .private) raw_chunk_count=\(plan.header.chunkCount, privacy: .private) raw_is_truncated=\(plan.header.isTruncated, privacy: .private) method=\(diagnostic.method, privacy: .public) stage=\(diagnostic.stage.rawValue, privacy: .public) disposition=\(diagnostic.disposition.rawValue, privacy: .public) thread=\(diagnostic.threadID ?? "nil", privacy: .private) turn=\(diagnostic.turnID ?? "nil", privacy: .private) item_type=\(diagnostic.itemType ?? "nil", privacy: .private) error=\(diagnostic.error.localizedDescription, privacy: .private)"
        )
        for chunk in plan.chunks {
            reviewIngestionLogger.error(
                "Review ingestion raw params record_id=\(chunk.recordID, privacy: .public) chunk_index_0_based=\(chunk.index, privacy: .private) chunk_count=\(chunk.count, privacy: .private) raw_params_base64_chunk=\(chunk.base64, privacy: .private)"
            )
        }
    }
}

extension ReviewIngestionError {
    var diagnosticItemType: String? {
        if case .unsupportedItemType(_, let type) = self {
            return type
        }
        return nil
    }
}
