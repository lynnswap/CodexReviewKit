import Foundation

package enum ReviewDomainEvent: Equatable, Sendable {
    case runStarted(turnID: ReviewTurn.ID, reviewThreadID: ReviewThread.ID?, model: String?)
    case itemStarted(ReviewEventItemSeed)
    case itemUpdated(ReviewEventItemSeed)
    case itemCompleted(ReviewEventItemSeed)
    case textDelta(itemID: ReviewEventItem.ID, kind: ReviewItemKind, family: ReviewItemFamily, content: ReviewEventItem.Content, delta: String)
    case reviewCompleted(summary: String, result: String?)
    case reviewFailed(String)
    case reviewCancelled(String)
}

package struct ReviewEventItemSeed: Equatable, Sendable {
    public var id: ReviewEventItem.ID
    public var kind: ReviewItemKind
    public var family: ReviewItemFamily
    public var phase: ReviewItemPhase
    public var content: ReviewEventItem.Content
    public var startedAt: Date?
    public var completedAt: Date?
    public var durationMs: Int?

    public init(
        id: ReviewEventItem.ID,
        kind: ReviewItemKind,
        family: ReviewItemFamily,
        phase: ReviewItemPhase,
        content: ReviewEventItem.Content,
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
