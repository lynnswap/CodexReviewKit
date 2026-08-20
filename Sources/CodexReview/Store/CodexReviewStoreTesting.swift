import Foundation

extension CodexReviewStore {
    nonisolated(unsafe) private static var requestCancellationDelayForTestingStorage: TimeInterval = 0
    nonisolated(unsafe) package static var requestCancellationDelay: TimeInterval {
        get { requestCancellationDelayForTestingStorage }
        set { requestCancellationDelayForTestingStorage = max(0, newValue) }
    }

    @_spi(Testing)
    public static var requestCancellationDelayForTesting: TimeInterval {
        get { requestCancellationDelay }
        set { requestCancellationDelay = newValue }
    }

    package func loadForTesting(
        serverState: CodexReviewServerState,
        authPhase: CodexReviewAuthModel.Phase = .signedOut,
        account: CodexAccount? = nil,
        persistedAccounts: [CodexAccount]? = nil,
        serverURL: URL? = nil,
        workspaces: [CodexReviewWorkspace],
        jobs: [CodexReviewJob] = [],
        settingsSnapshot: CodexReviewSettings.Snapshot? = nil
    ) {
        precondition(
            backend.isActive == false,
            "loadForTesting must be called before the embedded server starts."
        )
        self.serverState = serverState
        self.auth.updatePhase(authPhase)
        let resolvedPersistedAccounts = persistedAccounts ?? account.map { [$0] } ?? []
        self.auth.applyPersistedAccountStates(
            resolvedPersistedAccounts.map(savedAccountPayload(from:))
        )
        if let account,
           resolvedPersistedAccounts.contains(where: { $0.accountKey == account.accountKey })
        {
            self.auth.selectPersistedAccount(account.id)
        } else {
            self.auth.updateCurrentAccount(account)
        }
        self.serverURL = serverURL
        var existingByCWD: [String: CodexReviewWorkspace] = [:]
        for workspace in self.workspaces {
            existingByCWD[workspace.cwd] = workspace
        }

        var resolvedWorkspaces: [CodexReviewWorkspace] = []
        resolvedWorkspaces.reserveCapacity(workspaces.count)

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let sortOrder = Double(workspaces.count - workspaceIndex - 1)
            if let existingWorkspace = existingByCWD.removeValue(forKey: workspace.cwd) {
                existingWorkspace.sortOrder = sortOrder
                resolvedWorkspaces.append(existingWorkspace)
            } else {
                workspace.sortOrder = sortOrder
                resolvedWorkspaces.append(workspace)
            }
        }

        self.workspaces = Set(resolvedWorkspaces)
        var jobsByCWD: [String: [CodexReviewJob]] = [:]
        let resolvedJobs = jobs.filter { job in
            resolvedWorkspaces.contains(where: { $0.cwd == job.cwd })
        }
        for job in resolvedJobs {
            jobsByCWD[job.cwd, default: []].append(job)
        }
        for job in resolvedJobs {
            guard let workspaceJobs = jobsByCWD[job.cwd],
                  let index = workspaceJobs.firstIndex(where: { $0 === job })
            else {
                continue
            }
            job.sortOrder = Double(workspaceJobs.count - index - 1)
        }
        self.jobs = Set(resolvedJobs)
        if let settingsSnapshot {
            settings.loadForTesting(snapshot: settingsSnapshot)
        }
        writeDiagnosticsIfNeeded()
    }

    package func cancelAndDrainReviewWorkersForTesting() async {
        let tasks = Array(reviewWorkerTasks.values) + Array(runtimeStopDetachedReviewWorkerTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }

        reviewWorkerTasks.removeAll(keepingCapacity: false)
        runtimeStopDetachedReviewWorkerTasks.removeAll(keepingCapacity: false)
        startingJobIDs.removeAll(keepingCapacity: false)
        startupCancellations.removeAll(keepingCapacity: false)
        activeRuns.removeAll(keepingCapacity: false)
        reviewRecoveryWaitingJobIDs.removeAll(keepingCapacity: false)

        let waiters = reviewTerminalWaiters.values.flatMap { $0 }
        reviewTerminalWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume()
        }
    }
}
