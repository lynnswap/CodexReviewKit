import Foundation

extension CodexReviewStore {
    package func loadForTesting(
        serverState: CodexReviewServerState,
        authPhase: CodexReviewAuthModel.Phase = .signedOut,
        account: CodexReviewAccount? = nil,
        persistedAccounts: [CodexReviewAccount]? = nil,
        serverURL: URL? = nil,
        reviewRuns: [ReviewRunRecord] = [],
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
        for (index, runRecord) in reviewRuns.enumerated() {
            runRecord.sortOrder = Double(reviewRuns.count - index - 1)
        }
        self.reviewRuns = Set(reviewRuns)
        if let settingsSnapshot {
            settings.loadForTesting(snapshot: settingsSnapshot)
        }
        writeDiagnosticsIfNeeded()
    }

    package func cancelAndDrainReviewWorkersForTesting() async {
        await runtimeState.cancelAndDrainAllWorkersForTesting()
        runtimeState.clearForTesting()
    }
}
