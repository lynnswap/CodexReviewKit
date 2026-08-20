import Foundation

public enum ReviewTerminalKind: String, Codable, Sendable, Hashable {
    case completed
    case interrupted
    case failed
}

public enum ReviewInterruptionCause: Codable, Sendable, Hashable {
    case requested(ReviewCancellation)
    case server(message: String?)
    case transport(message: String)
    case previousProcessExit
}

public enum ReviewTerminalRecord: Codable, Sendable, Hashable {
    case completed
    case interrupted(ReviewInterruptionCause)
    case failed(message: String?)

    public var kind: ReviewTerminalKind {
        switch self {
        case .completed:
            .completed
        case .interrupted:
            .interrupted
        case .failed:
            .failed
        }
    }
}

package enum ReviewTerminalOutputStrategy: Sendable {
    case currentV2
}

package struct ReviewFinalResult: Equatable, Sendable {
    package enum Source: Equatable, Sendable {
        case exitedReviewMode(itemID: String)
        case turnSummary(itemID: String)
        case backendProvided

        package var itemID: String? {
            switch self {
            case .exitedReviewMode(let itemID), .turnSummary(let itemID):
                itemID
            case .backendProvided:
                nil
            }
        }
    }

    package static let maximumUTF8Bytes = 256 * 1024

    package var text: String
    package var source: Source
    package var suppressedAgentMessageItemIDs: Set<String>

    package init(
        validating text: String,
        source: Source,
        suppressedAgentMessageItemIDs: Set<String> = []
    ) throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw ReviewIngestionError.missingFinalReview
        }
        let byteCount = normalized.utf8.count
        guard byteCount <= Self.maximumUTF8Bytes else {
            throw ReviewIngestionError.outputTooLarge(
                actualBytes: byteCount,
                limit: Self.maximumUTF8Bytes
            )
        }
        self.text = normalized
        self.source = source
        self.suppressedAgentMessageItemIDs = suppressedAgentMessageItemIDs
    }
}

package enum ReviewAttemptTerminal: Equatable, Sendable {
    case completed(ReviewFinalResult)
    case interrupted(message: String?)
    case failed(message: String?)
}

package enum ReviewIngestionError: LocalizedError, Equatable, Sendable {
    case malformedKnownEvent(method: String, message: String)
    case unsupportedItemType(method: String, type: String)
    case missingRoutingIdentity(method: String)
    case conflictingActiveRouting(threadID: String)
    case conflictingStableEvent(key: String)
    case invalidTerminalStatus(String)
    case missingFinalReview
    case outputTooLarge(actualBytes: Int, limit: Int)
    case streamEndedWithoutTerminal

    package var errorDescription: String? {
        switch self {
        case .malformedKnownEvent(let method, let message):
            "Malformed app-server notification \(method): \(message)"
        case .unsupportedItemType(let method, let type):
            "Unsupported app-server item type \(type) in \(method)."
        case .missingRoutingIdentity(let method):
            "App-server notification \(method) is missing mandatory routing identity."
        case .conflictingActiveRouting(let threadID):
            "App-server thread \(threadID) routes to conflicting active review attempts."
        case .conflictingStableEvent(let key):
            "App-server sent conflicting payloads for stable review event \(key)."
        case .invalidTerminalStatus(let status):
            "Review ended with invalid terminal status \(status)."
        case .missingFinalReview:
            "Review completed without a canonical final review."
        case .outputTooLarge(let actualBytes, let limit):
            "Review output is too large (\(actualBytes) UTF-8 bytes; limit \(limit))."
        case .streamEndedWithoutTerminal:
            "Review event stream ended before an authoritative terminal was received."
        }
    }
}
