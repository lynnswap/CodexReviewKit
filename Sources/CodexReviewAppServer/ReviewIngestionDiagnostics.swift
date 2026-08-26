import CodexReview
import Foundation
import OSLog
import Synchronization

private let reviewIngestionLogger = Logger(
    subsystem: "CodexReviewKit",
    category: "review-ingestion"
)

package struct ReviewIngestionDiagnosticRecord: Equatable, Sendable {
    package enum Stage: String, Hashable, Sendable {
        case paramsDecoding
        case schemaValidation
        case payloadDecoding
        case routing
    }

    package enum Disposition: String, Hashable, Sendable {
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

package struct ReviewIngestionDiagnosticSummary: Equatable, Sendable {
    package enum MethodCategory: String, Hashable, Sendable {
        case diagnosticMethod
        case threadLifecycle
        case turnLifecycle
        case itemLifecycle
        case itemDelta
        case model
        case other

        fileprivate init(_ method: String) {
            switch method {
            case "warning", "guardianWarning", "deprecationNotice", "configWarning", "error":
                self = .diagnosticMethod
            case "thread/closed", "thread/status/changed", "thread/compacted":
                self = .threadLifecycle
            case "turn/started", "turn/completed", "turn/diff/updated", "turn/plan/updated":
                self = .turnLifecycle
            case "item/started", "item/completed",
                 "item/autoApprovalReview/started", "item/autoApprovalReview/completed":
                self = .itemLifecycle
            case "item/agentMessage/delta", "item/plan/delta",
                 "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded",
                 "item/reasoning/textDelta", "item/commandExecution/outputDelta",
                 "item/commandExecution/terminalInteraction", "item/fileChange/outputDelta",
                 "item/fileChange/patchUpdated", "item/mcpToolCall/progress":
                self = .itemDelta
            case "model/rerouted", "model/verification":
                self = .model
            default:
                self = .other
            }
        }
    }

    package enum ErrorCase: String, Hashable, Sendable {
        case malformedKnownEvent
        case unsupportedItemType
        case missingRoutingIdentity
        case conflictingActiveRouting
        case conflictingStableEvent
        case invalidTerminalStatus
        case missingFinalReview
        case outputTooLarge
        case streamEndedWithoutTerminal

        fileprivate init(_ error: ReviewIngestionError) {
            switch error {
            case .malformedKnownEvent: self = .malformedKnownEvent
            case .unsupportedItemType: self = .unsupportedItemType
            case .missingRoutingIdentity: self = .missingRoutingIdentity
            case .conflictingActiveRouting: self = .conflictingActiveRouting
            case .conflictingStableEvent: self = .conflictingStableEvent
            case .invalidTerminalStatus: self = .invalidTerminalStatus
            case .missingFinalReview: self = .missingFinalReview
            case .outputTooLarge: self = .outputTooLarge
            case .streamEndedWithoutTerminal: self = .streamEndedWithoutTerminal
            }
        }
    }

    package struct Key: Hashable, Sendable {
        package let methodCategory: MethodCategory
        package let stage: ReviewIngestionDiagnosticRecord.Stage
        package let disposition: ReviewIngestionDiagnosticRecord.Disposition
        package let errorCase: ErrorCase

        package init(_ diagnostic: ReviewIngestionDiagnosticRecord) {
            methodCategory = .init(diagnostic.method)
            stage = diagnostic.stage
            disposition = diagnostic.disposition
            errorCase = .init(diagnostic.error)
        }

        package init(
            methodCategory: MethodCategory,
            stage: ReviewIngestionDiagnosticRecord.Stage,
            disposition: ReviewIngestionDiagnosticRecord.Disposition,
            errorCase: ErrorCase
        ) {
            self.methodCategory = methodCategory
            self.stage = stage
            self.disposition = disposition
            self.errorCase = errorCase
        }
    }

    package let recordID: UUID
    package let key: Key
    package let rawByteCount: Int
    package let hasThreadID: Bool
    package let hasTurnID: Bool
    package let hasItemType: Bool

    package init(_ diagnostic: ReviewIngestionDiagnosticRecord, recordID: UUID) {
        self.recordID = recordID
        key = .init(diagnostic)
        rawByteCount = diagnostic.rawParams.count
        hasThreadID = diagnostic.threadID != nil
        hasTurnID = diagnostic.turnID != nil
        hasItemType = diagnostic.itemType != nil
    }
}

package struct ReviewIngestionDiagnosticSampler: Sendable {
    package enum Decision: Equatable, Sendable {
        case emitFullRecord
        case emitSuppressionSummary
        case emitCapacitySuppressionSummary
        case suppress
    }

    package static let fullRecordLimit = 2
    package static let maximumKeyCount = 16

    private var emissionCounts: [ReviewIngestionDiagnosticSummary.Key: Int] = [:]
    private var didEmitCapacitySummary = false

    package init() {}
    package var trackedKeyCount: Int { emissionCounts.count }

    package mutating func decision(
        for key: ReviewIngestionDiagnosticSummary.Key
    ) -> Decision {
        if let count = emissionCounts[key] {
            if count < Self.fullRecordLimit {
                emissionCounts[key] = count + 1
                return .emitFullRecord
            }
            if count == Self.fullRecordLimit {
                emissionCounts[key] = count + 1
                return .emitSuppressionSummary
            }
            return .suppress
        }
        guard emissionCounts.count < Self.maximumKeyCount else {
            guard didEmitCapacitySummary == false else { return .suppress }
            didEmitCapacitySummary = true
            return .emitCapacitySuppressionSummary
        }
        emissionCounts[key] = 1
        return .emitFullRecord
    }
}

package final class OSLogReviewIngestionDiagnosticRecorder: ReviewIngestionDiagnosticRecording {
    private let sampler = Mutex(ReviewIngestionDiagnosticSampler())

    package init() {}

    package func record(_ diagnostic: ReviewIngestionDiagnosticRecord) {
        let key = ReviewIngestionDiagnosticSummary.Key(diagnostic)
        switch sampler.withLock({ $0.decision(for: key) }) {
        case .emitFullRecord:
            let summary = ReviewIngestionDiagnosticSummary(diagnostic, recordID: UUID())
            reviewIngestionLogger.error(
                "Review ingestion failed record_id=\(summary.recordID.uuidString, privacy: .public) method_category=\(summary.key.methodCategory.rawValue, privacy: .public) stage=\(summary.key.stage.rawValue, privacy: .public) disposition=\(summary.key.disposition.rawValue, privacy: .public) error_case=\(summary.key.errorCase.rawValue, privacy: .public) raw_byte_count=\(summary.rawByteCount, privacy: .private) has_thread_id=\(summary.hasThreadID, privacy: .private) has_turn_id=\(summary.hasTurnID, privacy: .private) has_item_type=\(summary.hasItemType, privacy: .private)"
            )
        case .emitSuppressionSummary:
            reviewIngestionLogger.error(
                "Review ingestion diagnostics suppressed method_category=\(key.methodCategory.rawValue, privacy: .public) stage=\(key.stage.rawValue, privacy: .public) disposition=\(key.disposition.rawValue, privacy: .public) error_case=\(key.errorCase.rawValue, privacy: .public) full_record_limit=\(ReviewIngestionDiagnosticSampler.fullRecordLimit, privacy: .public)"
            )
        case .emitCapacitySuppressionSummary:
            reviewIngestionLogger.error(
                "Review ingestion diagnostic sampler capacity reached tracked_key_limit=\(ReviewIngestionDiagnosticSampler.maximumKeyCount, privacy: .public)"
            )
        case .suppress:
            break
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
