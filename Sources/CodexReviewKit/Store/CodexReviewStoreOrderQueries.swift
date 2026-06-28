extension CodexReviewStore {
    package var orderedWorkspaces: [CodexReviewWorkspace] {
        workspaces.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.cwd < $1.cwd
            }
            return $0.sortOrder > $1.sortOrder
        }
    }

    package var orderedJobs: [ReviewRunRecord] {
        orderedWorkspaces.flatMap { orderedJobs(in: $0) }
    }

    package var hasReviewJobs: Bool {
        jobs.isEmpty == false
    }

    package func workspace(cwd: String) -> CodexReviewWorkspace? {
        workspaces.first(where: { $0.cwd == cwd })
    }

    package func workspace(containing job: ReviewRunRecord) -> CodexReviewWorkspace? {
        workspace(cwd: job.cwd)
    }

    package func job(id: String) -> ReviewRunRecord? {
        jobs.first(where: { $0.id == id })
    }

    package func jobs(inWorkspace cwd: String) -> [ReviewRunRecord] {
        jobs.filter { $0.cwd == cwd }
    }

    package func orderedJobs(in workspace: CodexReviewWorkspace) -> [ReviewRunRecord] {
        orderedJobs(inWorkspace: workspace.cwd)
    }

    package func orderedJobs(inWorkspace cwd: String) -> [ReviewRunRecord] {
        jobs(inWorkspace: cwd).sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.id < $1.id
            }
            return $0.sortOrder > $1.sortOrder
        }
    }

    package func jobCount(in workspace: CodexReviewWorkspace) -> Int {
        jobs(inWorkspace: workspace.cwd).count
    }

    package func totalJobCount() -> Int {
        jobs.count
    }

    package func normalizeJobSortOrders(inWorkspace cwd: String) {
        let ordered = orderedJobs(inWorkspace: cwd)
        for (index, job) in ordered.enumerated() {
            job.sortOrder = Double(ordered.count - index - 1)
        }
    }

    package func normalizeWorkspaceSortOrders() {
        let ordered = orderedWorkspaces
        for (index, workspace) in ordered.enumerated() {
            workspace.sortOrder = Double(ordered.count - index - 1)
        }
    }

    package func normalizeAllJobSortOrders() {
        for workspace in workspaces {
            normalizeJobSortOrders(inWorkspace: workspace.cwd)
        }
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
