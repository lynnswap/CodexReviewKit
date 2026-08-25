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
        case terminalReduction
        case eventNormalization
    }

    package enum Disposition: String, Equatable, Sendable {
        case ignored
        case attemptFailed
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

package struct OSLogReviewIngestionDiagnosticRecorder: ReviewIngestionDiagnosticRecording {
    package init() {}

    package func record(_ diagnostic: ReviewIngestionDiagnosticRecord) {
        let rawParamsBase64 = diagnostic.rawParams.base64EncodedString()
        reviewIngestionLogger.error(
            "Review ingestion failed method=\(diagnostic.method, privacy: .public) thread=\(diagnostic.threadID ?? "nil", privacy: .private) turn=\(diagnostic.turnID ?? "nil", privacy: .private) item_type=\(diagnostic.itemType ?? "nil", privacy: .private) stage=\(diagnostic.stage.rawValue, privacy: .public) disposition=\(diagnostic.disposition.rawValue, privacy: .public) error=\(diagnostic.error.localizedDescription, privacy: .private) raw_params_base64=\(rawParamsBase64, privacy: .private)"
        )
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
