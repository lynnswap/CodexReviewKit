private struct ReviewHistoryReorderIntent: Sendable {
    enum Kind: Sendable {
        case workspaces(cwds: [String], toIndex: Int)
        case job(id: String, cwd: String, toIndex: Int)
    }

    var kind: Kind
}

private struct ReviewHistoryReorderPlan: Sendable {
    var ordering: ReviewHistoryOrdering?
    var workspaceSortOrders: [String: Double]
    var reviewSortOrders: [String: Double]

    static let none = ReviewHistoryReorderPlan(
        ordering: nil,
        workspaceSortOrders: [:],
        reviewSortOrders: [:]
    )
}

extension CodexReviewStore {
    package func reorderWorkspaces(cwds: [String], toIndex: Int) async -> Bool {
        await performHistoryReorder(.init(
            kind: .workspaces(cwds: cwds, toIndex: toIndex)
        ))
    }

    package func reorderJob(
        id: String,
        inWorkspace cwd: String,
        toIndex: Int
    ) async -> Bool {
        await performHistoryReorder(.init(
            kind: .job(id: id, cwd: cwd, toIndex: toIndex)
        ))
    }

    private func performHistoryReorder(_ intent: ReviewHistoryReorderIntent) async -> Bool {
        await loadReviewHistoryIfNeeded()
        guard historyAvailability == .available,
              applicationShutdownRequested == false
        else {
            return false
        }
        let persistence = historyPersistence
        guard let receipt = historyMutationCoordinator.enqueue(
            intent: intent,
            prepare: { [weak self] intent in
                self?.makeHistoryReorderPlan(intent) ?? .none
            },
            operation: { plan in
                guard let ordering = plan.ordering else {
                    return false
                }
                try await persistence.saveOrdering(ordering)
                return true
            },
            apply: { [weak self] plan, result in
                guard let self else {
                    return
                }
                switch result {
                case .success(true):
                    applyHistoryReorderPlan(plan)
                case .success(false):
                    break
                case .failure(let failure):
                    publishReviewHistoryFailure(failure)
                }
            }
        ) else {
            return false
        }
        switch await receipt.wait() {
        case .success(let didApply):
            return didApply
        case .failure:
            return false
        }
    }

    private func makeHistoryReorderPlan(
        _ intent: ReviewHistoryReorderIntent
    ) -> ReviewHistoryReorderPlan {
        guard historyAvailability == .available,
              applicationShutdownRequested == false
        else {
            return .none
        }
        switch intent.kind {
        case .workspaces(let cwds, let toIndex):
            let cwdSet = Set(cwds)
            let ordered = orderedWorkspaces
            let moving = ordered.filter { cwdSet.contains($0.cwd) }
            guard moving.isEmpty == false else {
                return .none
            }
            let remaining = ordered.filter { cwdSet.contains($0.cwd) == false }
            let destinationIndex = max(0, min(toIndex, remaining.count))
            var reordered = remaining
            reordered.insert(contentsOf: moving, at: destinationIndex)
            guard reordered.count == ordered.count,
                  zip(reordered, ordered).contains(where: { $0.0 !== $0.1 })
            else {
                return .none
            }
            let sortOrders = Dictionary(uniqueKeysWithValues:
                reordered.enumerated().map { index, workspace in
                    (workspace.cwd, Double(reordered.count - index - 1))
                }
            )
            return ReviewHistoryReorderPlan(
                ordering: currentReviewHistoryOrdering(
                    workspaceSortOrders: sortOrders
                ),
                workspaceSortOrders: sortOrders,
                reviewSortOrders: [:]
            )

        case .job(let id, let cwd, let toIndex):
            guard workspace(cwd: cwd) != nil else {
                return .none
            }
            let ordered = orderedJobs(inWorkspace: cwd)
            guard let job = ordered.first(where: { $0.id == id }),
                  let sourceIndex = ordered.firstIndex(where: { $0 === job })
            else {
                return .none
            }
            let destinationIndex = max(0, min(toIndex, ordered.count - 1))
            guard sourceIndex != destinationIndex else {
                return .none
            }
            var reordered = ordered
            reordered.remove(at: sourceIndex)
            reordered.insert(job, at: destinationIndex)
            let sortOrders = Dictionary(uniqueKeysWithValues:
                reordered.enumerated().map { index, job in
                    (job.id, Double(reordered.count - index - 1))
                }
            )
            return ReviewHistoryReorderPlan(
                ordering: currentReviewHistoryOrdering(
                    reviewSortOrders: sortOrders
                ),
                workspaceSortOrders: [:],
                reviewSortOrders: sortOrders
            )
        }
    }

    private func applyHistoryReorderPlan(_ plan: ReviewHistoryReorderPlan) {
        for workspace in workspaces {
            if let sortOrder = plan.workspaceSortOrders[workspace.cwd] {
                workspace.sortOrder = sortOrder
            }
        }
        for job in jobs {
            if let sortOrder = plan.reviewSortOrders[job.id] {
                job.sortOrder = sortOrder
            }
        }
        noteHistoryMembershipOrOrderingMutation()
        writeDiagnosticsIfNeeded()
    }
}
