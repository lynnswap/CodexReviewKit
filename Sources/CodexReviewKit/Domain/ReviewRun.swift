import Foundation
import Observation

public enum ReviewLifecycleStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case incomplete

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .incomplete:
            true
        case .queued, .running:
            false
        }
    }
}

@MainActor
@Observable
public final class ReviewRun: Identifiable, Hashable {
    public typealias ID = ReviewRunID

    public nonisolated let id: ID
    public private(set) var threadID: ReviewThread.ID?
    public private(set) var turnID: ReviewTurn.ID?
    public private(set) var reviewThreadID: ReviewThread.ID?
    public private(set) var model: String?
    public private(set) var status: ReviewLifecycleStatus
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?

    public init(
        id: ID,
        threadID: ReviewThread.ID? = nil,
        turnID: ReviewTurn.ID? = nil,
        reviewThreadID: ReviewThread.ID? = nil,
        model: String? = nil,
        status: ReviewLifecycleStatus = .queued,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.turnID = turnID
        self.reviewThreadID = reviewThreadID
        self.model = model
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public func update(
        threadID: ReviewThread.ID? = nil,
        turnID: ReviewTurn.ID? = nil,
        reviewThreadID: ReviewThread.ID? = nil,
        model: String? = nil,
        status: ReviewLifecycleStatus? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        if let threadID {
            self.threadID = threadID
        }
        if let turnID {
            self.turnID = turnID
        }
        if let reviewThreadID {
            self.reviewThreadID = reviewThreadID
        }
        if let model {
            self.model = model
        }
        if let status {
            self.status = status
        }
        if let startedAt {
            self.startedAt = startedAt
        }
        if let endedAt {
            self.endedAt = endedAt
        }
    }

    public nonisolated static func == (lhs: ReviewRun, rhs: ReviewRun) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
