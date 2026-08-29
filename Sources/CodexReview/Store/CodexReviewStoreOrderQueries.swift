extension CodexReviewStore {
    package var orderedWorkspaces: [CodexReviewWorkspace] {
        workspaces.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.cwd < $1.cwd
            }
            return $0.sortOrder > $1.sortOrder
        }
    }

    package var orderedJobs: [CodexReviewJob] {
        jobs.sorted(by: jobPrecedes)
    }

    package var hasReviewJobs: Bool {
        jobs.isEmpty == false
    }

    package func workspace(cwd: String) -> CodexReviewWorkspace? {
        workspaces.first(where: { $0.cwd == cwd })
    }

    package func workspace(containing job: CodexReviewJob) -> CodexReviewWorkspace? {
        workspace(cwd: job.cwd)
    }

    package func job(id: String) -> CodexReviewJob? {
        jobs.first(where: { $0.id == id })
    }

    package func jobs(inWorkspace cwd: String) -> [CodexReviewJob] {
        jobs.filter { $0.cwd == cwd }
    }

    package func orderedJobs(in workspace: CodexReviewWorkspace) -> [CodexReviewJob] {
        orderedJobs(inWorkspace: workspace.cwd)
    }

    package func orderedJobs(inWorkspace cwd: String) -> [CodexReviewJob] {
        jobs(inWorkspace: cwd).sorted(by: jobPrecedes)
    }

    package func orderedJobs(inWorkspaces cwds: Set<String>) -> [CodexReviewJob] {
        jobs
            .filter { cwds.contains($0.cwd) }
            .sorted(by: jobPrecedes)
    }

    package func jobCount(in workspace: CodexReviewWorkspace) -> Int {
        jobs(inWorkspace: workspace.cwd).count
    }

    package func totalJobCount() -> Int {
        jobs.count
    }

    private func jobPrecedes(_ lhs: CodexReviewJob, _ rhs: CodexReviewJob) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.id < rhs.id
        }
        return lhs.sortOrder > rhs.sortOrder
    }
}
