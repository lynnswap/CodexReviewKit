import Foundation
import Observation

@MainActor
@Observable
package final class ReviewTimeline {
    public struct Revision: RawRepresentable, Codable, Hashable, Sendable, Comparable {
        public var rawValue: UInt64

        public init(rawValue: UInt64) {
            self.rawValue = rawValue
        }

        public static let initial = Revision(rawValue: 0)

        public static func < (lhs: Revision, rhs: Revision) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public private(set) var revision: Revision = .initial
    public private(set) var orderedItemIDs: [ReviewTimelineItem.ID] = []
    public private(set) var itemsByID: [ReviewTimelineItem.ID: ReviewTimelineItem] = [:]
    public private(set) var activeItemIDs: Set<ReviewTimelineItem.ID> = []
    public private(set) var latestActivity: ReviewTimelineItem.ID?
    public private(set) var terminalStatus: ReviewLifecycleStatus?
    public private(set) var terminalSummary: String?
    public private(set) var terminalResult: String?

    public init() {}

    public var items: [ReviewTimelineItem] {
        orderedItemIDs.compactMap { itemsByID[$0] }
    }

    public var isTerminal: Bool {
        terminalStatus != nil
    }

    public func reset(keepingTerminal: Bool = true) {
        orderedItemIDs.removeAll(keepingCapacity: true)
        itemsByID.removeAll(keepingCapacity: true)
        activeItemIDs.removeAll(keepingCapacity: true)
        latestActivity = nil
        if keepingTerminal == false {
            terminalStatus = nil
            terminalSummary = nil
            terminalResult = nil
        }
        bumpRevision()
    }

    public func apply(_ event: ReviewDomainEvent, at timestamp: Date = Date()) {
        switch event {
        case .runStarted:
            terminalStatus = nil
            terminalSummary = nil
            terminalResult = nil
            bumpRevision()
        case .itemStarted(let seed):
            applySeed(seed, timestamp: timestamp, activity: .phaseDriven)
        case .itemUpdated(let seed):
            applySeed(seed, timestamp: timestamp, activity: .phaseDriven)
        case .itemCompleted(let seed):
            applySeed(seed, timestamp: timestamp, activity: .inactive)
        case .textDelta(let itemID, let kind, let family, let content, let delta):
            let item =
                item(for: itemID)
                ?? insert(
                    id: itemID,
                    kind: kind,
                    family: family,
                    phase: .running,
                    content: content,
                    timestamp: timestamp
                )
            item.appendText(delta, updatedAt: timestamp)
            synchronizeActiveMembership(for: item, activity: .phaseDriven)
            latestActivity = item.id
            bumpRevision()
        case .reviewCompleted(let summary, let result):
            terminalStatus = .succeeded
            terminalSummary = summary
            terminalResult = result
            activeItemIDs.removeAll(keepingCapacity: true)
            bumpRevision()
        case .reviewFailed(let message):
            terminalStatus = .failed
            terminalSummary = message
            terminalResult = nil
            activeItemIDs.removeAll(keepingCapacity: true)
            bumpRevision()
        case .reviewCancelled(let message):
            terminalStatus = .cancelled
            terminalSummary = message
            terminalResult = nil
            activeItemIDs.removeAll(keepingCapacity: true)
            bumpRevision()
        }
    }

    public func item(for id: ReviewTimelineItem.ID) -> ReviewTimelineItem? {
        itemsByID[id]
    }

    @discardableResult
    package func closeActiveItems(
        family: ReviewItemFamily? = nil,
        phase: ReviewItemPhase,
        timestamp: Date
    ) -> Bool {
        let ids = activeItemIDs.filter { id in
            guard let family else {
                return true
            }
            return itemsByID[id]?.family == family
        }
        guard ids.isEmpty == false else {
            return false
        }
        for id in ids {
            guard let item = itemsByID[id] else {
                continue
            }
            item.update(
                phase: phase,
                content: item.content.closingActiveContent(phase: phase),
                updatedAt: timestamp,
                completedAt: timestamp
            )
            activeItemIDs.remove(id)
        }
        bumpRevision()
        return true
    }

    @discardableResult
    package func updateItemContent(
        _ content: ReviewTimelineItem.Content,
        for id: ReviewTimelineItem.ID,
        updatedAt: Date? = nil
    ) -> Bool {
        guard let item = itemsByID[id],
            item.content != content
        else {
            return false
        }
        item.update(content: content, updatedAt: updatedAt ?? item.updatedAt)
        bumpRevision()
        return true
    }

    @discardableResult
    private func applySeed(
        _ seed: ReviewTimelineItemSeed,
        timestamp: Date,
        activity: ItemActivity
    ) -> ReviewTimelineItem {
        let item = upsert(seed, timestamp: timestamp)
        item.update(
            kind: seed.kind,
            family: seed.family,
            phase: seed.phase,
            content: item.content.mergingTimelineUpdate(seed.content),
            updatedAt: timestamp,
            startedAt: seed.startedAt,
            completedAt: seed.completedAt,
            durationMs: seed.durationMs
        )
        synchronizeActiveMembership(for: item, activity: activity)
        latestActivity = item.id
        bumpRevision()
        return item
    }

    private enum ItemActivity {
        case inactive
        case phaseDriven
    }

    private func synchronizeActiveMembership(for item: ReviewTimelineItem, activity: ItemActivity) {
        switch activity {
        case .inactive:
            activeItemIDs.remove(item.id)
        case .phaseDriven:
            if isTerminal || item.phase.isTerminal {
                activeItemIDs.remove(item.id)
            } else {
                activeItemIDs.insert(item.id)
            }
        }
    }

    @discardableResult
    private func upsert(_ seed: ReviewTimelineItemSeed, timestamp: Date) -> ReviewTimelineItem {
        if let item = itemsByID[seed.id] {
            return item
        }
        return insert(
            id: seed.id,
            kind: seed.kind,
            family: seed.family,
            phase: seed.phase,
            content: seed.content,
            timestamp: timestamp,
            startedAt: seed.startedAt,
            completedAt: seed.completedAt,
            durationMs: seed.durationMs
        )
    }

    @discardableResult
    private func insert(
        id: ReviewTimelineItem.ID,
        kind: ReviewItemKind,
        family: ReviewItemFamily,
        phase: ReviewItemPhase,
        content: ReviewTimelineItem.Content,
        timestamp: Date,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        durationMs: Int? = nil
    ) -> ReviewTimelineItem {
        let item = ReviewTimelineItem(
            id: id,
            kind: kind,
            family: family,
            phase: phase,
            content: content,
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: durationMs
        )
        itemsByID[id] = item
        orderedItemIDs.append(id)
        return item
    }

    private func bumpRevision() {
        revision = Revision(rawValue: revision.rawValue &+ 1)
    }
}
