extension CodexReviewStore {
    package func reorderWorkspaces(cwds: [String], toIndex: Int) {
        let cwdSet = Set(cwds)
        let ordered = orderedWorkspaces
        let moving = ordered.filter { cwdSet.contains($0.cwd) }
        guard moving.isEmpty == false else {
            return
        }

        let remaining = ordered.filter { cwdSet.contains($0.cwd) == false }
        let destinationIndex = max(0, min(toIndex, remaining.count))
        var reordered = remaining
        reordered.insert(contentsOf: moving, at: destinationIndex)
        guard reordered.count == ordered.count,
              zip(reordered, ordered).contains(where: { pair in pair.0 !== pair.1 })
        else {
            return
        }

        for (index, workspace) in reordered.enumerated() {
            workspace.sortOrder = Double(reordered.count - index - 1)
        }
        writeDiagnosticsIfNeeded()
    }

    package func reorderJob(
        id: String,
        inWorkspace cwd: String,
        toIndex: Int
    ) {
        guard workspace(cwd: cwd) != nil else {
            return
        }

        let ordered = orderedJobs(inWorkspace: cwd)
        guard let job = ordered.first(where: { $0.id == id }),
              let sourceIndex = ordered.firstIndex(where: { $0 === job })
        else {
            return
        }

        let destinationIndex = max(0, min(toIndex, ordered.count - 1))
        guard sourceIndex != destinationIndex else {
            return
        }

        var sortOrder = reorderedSortOrder(
            moving: job,
            toIndex: destinationIndex,
            in: ordered,
            sortOrder: \.sortOrder
        )
        if sortOrder == nil {
            normalizeJobSortOrders(inWorkspace: cwd)
            sortOrder = reorderedSortOrder(
                moving: job,
                toIndex: destinationIndex,
                in: orderedJobs(inWorkspace: cwd),
                sortOrder: \.sortOrder
            )
        }
        guard let sortOrder else {
            return
        }
        job.sortOrder = sortOrder
        writeDiagnosticsIfNeeded()
    }
}
