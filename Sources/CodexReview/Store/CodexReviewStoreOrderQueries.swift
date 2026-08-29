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
        orderedWorkspaces.flatMap { orderedJobs(in: $0) }
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

}
