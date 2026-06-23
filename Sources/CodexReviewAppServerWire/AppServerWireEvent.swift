import Foundation
import CodexReviewDomain

public struct AppServerWireEvent: Equatable, Sendable {
    public var kind: AppServerReviewEventKind
    public var itemKind: ReviewItemKind?
    public var itemID: ReviewTimelineItem.ID?
    public var timestamp: Date?

    public init(
        kind: AppServerReviewEventKind,
        itemKind: ReviewItemKind? = nil,
        itemID: ReviewTimelineItem.ID? = nil,
        timestamp: Date? = nil
    ) {
        self.kind = kind
        self.itemKind = itemKind
        self.itemID = itemID
        self.timestamp = timestamp
    }
}
