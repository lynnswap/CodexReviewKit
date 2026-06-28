import Foundation

package enum ReviewDomainEvent: Equatable, Sendable {
    case runStarted(turnID: ReviewTurn.ID, reviewThreadID: ReviewThread.ID?, model: String?)
    case itemStarted(ReviewTimelineItemSeed)
    case itemUpdated(ReviewTimelineItemSeed)
    case itemCompleted(ReviewTimelineItemSeed)
    case textDelta(itemID: ReviewTimelineItem.ID, kind: ReviewItemKind, family: ReviewItemFamily, content: ReviewTimelineItem.Content, delta: String)
    case reviewCompleted(summary: String, result: String?)
    case reviewFailed(String)
    case reviewCancelled(String)
}

package struct ReviewTimelineItemSeed: Equatable, Sendable {
    public var id: ReviewTimelineItem.ID
    public var kind: ReviewItemKind
    public var family: ReviewItemFamily
    public var phase: ReviewItemPhase
    public var content: ReviewTimelineItem.Content
    public var startedAt: Date?
    public var completedAt: Date?
    public var durationMs: Int?

    public init(
        id: ReviewTimelineItem.ID,
        kind: ReviewItemKind,
        family: ReviewItemFamily,
        phase: ReviewItemPhase,
        content: ReviewTimelineItem.Content,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.family = family
        self.phase = phase
        self.content = content
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
    }
}
