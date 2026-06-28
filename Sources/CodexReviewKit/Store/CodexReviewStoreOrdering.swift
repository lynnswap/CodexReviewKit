extension CodexReviewStore {
    @discardableResult
    package func reorderWorkspaces(cwds: [String], beforeCWD: String?) -> Bool {
        let cwdSet = Set(cwds)
        guard beforeCWD.map({ cwdSet.contains($0) }) != true else {
            return false
        }

        let ordered = orderedWorkspaces
        let remaining = ordered.filter { cwdSet.contains($0.cwd) == false }
        let destinationIndex: Int
        if let beforeCWD {
            guard let beforeIndex = remaining.firstIndex(where: { $0.cwd == beforeCWD }) else {
                return false
            }
            destinationIndex = beforeIndex
        } else {
            destinationIndex = remaining.count
        }
        return reorderWorkspaces(cwds: cwds, toRemainingIndex: destinationIndex)
    }

    @discardableResult
    package func reorderWorkspaces(cwds: [String], toIndex: Int) -> Bool {
        reorderWorkspaces(cwds: cwds, toRemainingIndex: toIndex)
    }

    @discardableResult
    private func reorderWorkspaces(cwds: [String], toRemainingIndex toIndex: Int) -> Bool {
        let cwdSet = Set(cwds)
        let ordered = orderedWorkspaces
        let moving = ordered.filter { cwdSet.contains($0.cwd) }
        guard moving.isEmpty == false else {
            return false
        }

        let remaining = ordered.filter { cwdSet.contains($0.cwd) == false }
        let destinationIndex = max(0, min(toIndex, remaining.count))
        var reordered = remaining
        reordered.insert(contentsOf: moving, at: destinationIndex)
        guard reordered.count == ordered.count,
              zip(reordered, ordered).contains(where: { pair in pair.0 !== pair.1 })
        else {
            return false
        }

        for (index, workspace) in reordered.enumerated() {
            workspace.sortOrder = Double(reordered.count - index - 1)
        }
        writeDiagnosticsIfNeeded()
        return true
    }

    @discardableResult
    package func reorderJob(
        id: String,
        inWorkspace cwd: String,
        beforeJobID: String?
    ) -> Bool {
        guard beforeJobID != id,
              workspace(cwd: cwd) != nil
        else {
            return false
        }

        let ordered = orderedReviewRuns(inWorkspace: cwd)
        guard let job = ordered.first(where: { $0.id == id }) else {
            return false
        }

        let remaining = ordered.filter { $0 !== job }
        let destinationIndex: Int
        if let beforeJobID {
            guard let beforeIndex = remaining.firstIndex(where: { $0.id == beforeJobID }) else {
                return false
            }
            destinationIndex = beforeIndex
        } else {
            destinationIndex = remaining.count
        }
        return reorderJob(id: id, inWorkspace: cwd, toIndex: destinationIndex)
    }

    @discardableResult
    package func reorderJob(
        id: String,
        inWorkspace cwd: String,
        toIndex: Int
    ) -> Bool {
        guard workspace(cwd: cwd) != nil else {
            return false
        }

        let ordered = orderedReviewRuns(inWorkspace: cwd)
        guard let job = ordered.first(where: { $0.id == id }),
              let sourceIndex = ordered.firstIndex(where: { $0 === job })
        else {
            return false
        }

        let destinationIndex = max(0, min(toIndex, ordered.count - 1))
        guard sourceIndex != destinationIndex else {
            return false
        }

        var sortOrder = reorderedSortOrder(
            moving: job,
            toIndex: destinationIndex,
            in: ordered,
            sortOrder: \.sortOrder
        )
        if sortOrder == nil {
            normalizeReviewRunSortOrders(inWorkspace: cwd)
            sortOrder = reorderedSortOrder(
                moving: job,
                toIndex: destinationIndex,
                in: orderedReviewRuns(inWorkspace: cwd),
                sortOrder: \.sortOrder
            )
        }
        guard let sortOrder else {
            return false
        }
        job.sortOrder = sortOrder
        writeDiagnosticsIfNeeded()
        return true
    }
}
