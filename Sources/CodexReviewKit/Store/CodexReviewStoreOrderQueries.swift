extension CodexReviewStore {
    package var orderedReviewRuns: [ReviewRunRecord] {
        reviewRuns.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.id < $1.id
            }
            return $0.sortOrder > $1.sortOrder
        }
    }

    package var hasReviewRuns: Bool {
        reviewRuns.isEmpty == false
    }

    package func reviewRun(id: String) -> ReviewRunRecord? {
        reviewRuns.first(where: { $0.id == id })
    }

    package func hasCancellableReview(forChatID chatID: String) -> Bool {
        cancellableReviewRun(forChatID: chatID) != nil
    }

    package func cancellableReviewRun(forChatID chatID: String) -> ReviewRunRecord? {
        orderedReviewRuns.first { runRecord in
            guard runRecord.isTerminal == false else {
                return false
            }
            return runRecord.matchesChatID(chatID)
        }
    }

    package func reviewRuns(inWorkspace cwd: String) -> [ReviewRunRecord] {
        reviewRuns.filter { $0.cwd == cwd }
    }

    package func orderedReviewRuns(inWorkspace cwd: String) -> [ReviewRunRecord] {
        orderedReviewRuns.filter { $0.cwd == cwd }
    }

    package func totalReviewRunCount() -> Int {
        reviewRuns.count
    }

    package func normalizeReviewRunSortOrders(inWorkspace cwd: String) {
        let ordered = orderedReviewRuns(inWorkspace: cwd)
        for (index, runRecord) in ordered.enumerated() {
            runRecord.sortOrder = Double(ordered.count - index - 1)
        }
    }

    package func normalizeAllReviewRunSortOrders() {
        for cwd in Set(reviewRuns.map(\.cwd)) {
            normalizeReviewRunSortOrders(inWorkspace: cwd)
        }
    }
}

private extension ReviewRunRecord {
    func matchesChatID(_ chatID: String) -> Bool {
        matchesChatID(chatID, candidate: core.run.reviewThreadID)
            || matchesChatID(chatID, candidate: core.run.threadID)
    }

    private func matchesChatID(_ chatID: String, candidate: String?) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
            candidate.isEmpty == false
        else {
            return false
        }
        return candidate == chatID
    }
}

package func reorderedSortOrder<Item: AnyObject>(
    moving item: Item,
    toIndex destinationIndex: Int,
    in orderedItems: [Item],
    sortOrder: (Item) -> Double
) -> Double? {
    guard let sourceIndex = orderedItems.firstIndex(where: { $0 === item }) else {
        return nil
    }

    var remainingItems = orderedItems
    remainingItems.remove(at: sourceIndex)
    let insertionIndex = max(0, min(destinationIndex, remainingItems.count))
    let previousSortOrder = insertionIndex > 0
        ? sortOrder(remainingItems[insertionIndex - 1])
        : nil
    let nextSortOrder = insertionIndex < remainingItems.count
        ? sortOrder(remainingItems[insertionIndex])
        : nil

    switch (previousSortOrder, nextSortOrder) {
    case (.some(let previous), .some(let next)):
        guard previous != next else {
            return nil
        }
        let midpoint = previous + (next - previous) / 2
        guard midpoint.isFinite,
              midpoint > min(previous, next),
              midpoint < max(previous, next)
        else {
            return nil
        }
        return midpoint
    case (.some(let previous), .none):
        let next = previous - 1
        guard next.isFinite, next != previous else {
            return nil
        }
        return next
    case (.none, .some(let next)):
        let previous = next + 1
        guard previous.isFinite, previous != next else {
            return nil
        }
        return previous
    case (.none, .none):
        return 0
    }
}
