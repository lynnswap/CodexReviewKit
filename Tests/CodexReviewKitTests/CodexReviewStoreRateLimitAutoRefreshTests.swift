import Foundation
import Testing
@_spi(Testing) @testable import CodexReviewKit
import CodexReviewTesting

@Suite("Store rate limit auto refresh")
@MainActor
struct CodexReviewStoreRateLimitAutoRefreshTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func selectedRunningAccountRefreshesAfterOneMinute() {
        let account = makeAccount(lastFetchAt: now)

        let targets = targets(accounts: [account], selectedAccount: account, hasRunningReviewRuns: true)

        #expect(targets == [
            .init(accountKey: account.accountKey, kind: .selectedRunningInterval, dueAt: now.addingTimeInterval(60)),
        ])
    }

    @Test func selectedIdleAccountRefreshesAfterFifteenMinutes() {
        let account = makeAccount(lastFetchAt: now)

        let targets = targets(accounts: [account], selectedAccount: account, hasRunningReviewRuns: false)

        #expect(targets == [
            .init(accountKey: account.accountKey, kind: .selectedIdleInterval, dueAt: now.addingTimeInterval(15 * 60)),
        ])
    }

    @Test func nonSelectedAccountsRefreshAfterFifteenMinutes() {
        let selectedAccount = makeAccount(email: "selected@example.com", lastFetchAt: now)
        let otherAccount = makeAccount(email: "other@example.com", lastFetchAt: now)

        let targets = targets(
            accounts: [selectedAccount, otherAccount],
            selectedAccount: selectedAccount,
            hasRunningReviewRuns: false
        )

        #expect(targets == [
            .init(
                accountKey: otherAccount.accountKey,
                kind: .backgroundInterval,
                dueAt: now.addingTimeInterval(15 * 60)
            ),
            .init(
                accountKey: selectedAccount.accountKey,
                kind: .selectedIdleInterval,
                dueAt: now.addingTimeInterval(15 * 60)
            ),
        ])
    }

    @Test func accountsWithoutRateLimitRefreshCapabilityAreNotTargeted() {
        let selectedAccount = makeAccount(
            email: "selected@example.com",
            lastFetchAt: now,
            capabilities: .noCodexRateLimits
        )
        let otherAccount = makeAccount(email: "other@example.com", lastFetchAt: now)

        let targets = targets(
            accounts: [selectedAccount, otherAccount],
            selectedAccount: selectedAccount,
            hasRunningReviewRuns: true
        )

        #expect(targets == [
            .init(
                accountKey: otherAccount.accountKey,
                kind: .backgroundInterval,
                dueAt: now.addingTimeInterval(15 * 60)
            ),
        ])
    }

    @Test func runningRunsOnlyAccelerateSelectedAccount() {
        let selectedAccount = makeAccount(email: "selected@example.com", lastFetchAt: now)
        let otherAccount = makeAccount(email: "other@example.com", lastFetchAt: now)

        let targets = targets(
            accounts: [selectedAccount, otherAccount],
            selectedAccount: selectedAccount,
            hasRunningReviewRuns: true
        )

        #expect(targets == [
            .init(
                accountKey: selectedAccount.accountKey,
                kind: .selectedRunningInterval,
                dueAt: now.addingTimeInterval(60)
            ),
            .init(
                accountKey: otherAccount.accountKey,
                kind: .backgroundInterval,
                dueAt: now.addingTimeInterval(15 * 60)
            ),
        ])
    }

    @Test func resetRefreshCanPreemptNormalInterval() {
        let resetAt = now.addingTimeInterval(2 * 60)
        let account = makeAccount(
            lastFetchAt: now,
            rateLimits: [
                (windowDurationMinutes: 300, usedPercent: 100, resetsAt: resetAt),
            ]
        )

        let targets = targets(accounts: [account], selectedAccount: account, hasRunningReviewRuns: false)

        #expect(targets == [
            .init(accountKey: account.accountKey, kind: .resetWindow, dueAt: resetAt.addingTimeInterval(60)),
        ])
    }

    @Test func resetRefreshIsConsumedAfterFetchPastResetDueDate() {
        let resetAt = now.addingTimeInterval(2 * 60)
        let resetRefreshAt = resetAt.addingTimeInterval(60)
        let account = makeAccount(
            lastFetchAt: resetRefreshAt,
            rateLimits: [
                (windowDurationMinutes: 300, usedPercent: 100, resetsAt: resetAt),
            ]
        )

        let targets = targets(accounts: [account], selectedAccount: account, hasRunningReviewRuns: false)

        #expect(targets == [
            .init(
                accountKey: account.accountKey,
                kind: .selectedIdleInterval,
                dueAt: resetRefreshAt.addingTimeInterval(15 * 60)
            ),
        ])
    }

    @Test func nilLastFetchUsesNowUnlessResetIsUnconsumed() {
        let account = makeAccount(lastFetchAt: nil)

        let targets = targets(accounts: [account], selectedAccount: account, hasRunningReviewRuns: false)

        #expect(targets == [
            .init(accountKey: account.accountKey, kind: .selectedIdleInterval, dueAt: now.addingTimeInterval(15 * 60)),
        ])
    }

    @Test func nilLastFetchStillRefreshesUnconsumedResetImmediately() {
        let resetAt = now.addingTimeInterval(-2 * 60)
        let account = makeAccount(
            lastFetchAt: nil,
            rateLimits: [
                (windowDurationMinutes: 300, usedPercent: 100, resetsAt: resetAt),
            ]
        )

        let targets = targets(accounts: [account], selectedAccount: account, hasRunningReviewRuns: false)

        #expect(targets == [
            .init(accountKey: account.accountKey, kind: .resetWindow, dueAt: resetAt.addingTimeInterval(60)),
        ])
    }

    @Test func storeTargetsFollowRunningRunState() {
        let account = makeAccount(lastFetchAt: now)
        let runningRun = ReviewRunRecord.makeForTesting(
            targetSummary: "Review changes",
            status: .running,
            startedAt: now,
            summary: "Running."
        )
        let store = CodexReviewStore.makePreviewStore()

        loadStore(store, account: account, reviewRuns: [])
        #expect(store.accountRateLimitAutoRefreshTargets(now: now) == [
            .init(accountKey: account.accountKey, kind: .selectedIdleInterval, dueAt: now.addingTimeInterval(15 * 60)),
        ])

        loadStore(store, account: account, reviewRuns: [runningRun])
        #expect(store.accountRateLimitAutoRefreshTargets(now: now) == [
            .init(accountKey: account.accountKey, kind: .selectedRunningInterval, dueAt: now.addingTimeInterval(60)),
        ])

        loadStore(store, account: account, reviewRuns: [])
        #expect(store.accountRateLimitAutoRefreshTargets(now: now) == [
            .init(accountKey: account.accountKey, kind: .selectedIdleInterval, dueAt: now.addingTimeInterval(15 * 60)),
        ])
    }

    @Test func storeInFlightRefreshDoesNotStartDuplicateRequestForSameAccount() async throws {
        let account = makeAccount(lastFetchAt: now.addingTimeInterval(-15 * 60))
        let backend = BlockingRateLimitRefreshBackend(account: account)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: account,
            persistedAccounts: [account],
            workspaces: []
        )

        store.refreshDueAccountRateLimits(now: now)
        await backend.waitUntilRefreshStarts()

        store.refreshDueAccountRateLimits(now: now)
        await Task.yield()

        #expect(backend.refreshedAccountKeys == [account.accountKey])

        await backend.releaseRefresh()
        try await waitForCondition {
            store.accountRateLimitAutoRefreshInFlightAccountKeys.isEmpty
        }
    }

    @Test func noProgressRefreshDoesNotImmediatelyRestartSameAccount() async throws {
        let account = makeAccount(lastFetchAt: now.addingTimeInterval(-15 * 60))
        let backend = NoProgressRateLimitRefreshBackend(account: account)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            clock: .init(now: { now })
        )
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: account,
            persistedAccounts: [account],
            workspaces: []
        )

        store.refreshDueAccountRateLimits(now: now)
        try await waitForCondition {
            backend.refreshedAccountKeys.count == 1
                && store.accountRateLimitAutoRefreshInFlightAccountKeys.isEmpty
        }

        store.refreshDueAccountRateLimits(now: now)
        await Task.yield()

        #expect(backend.refreshedAccountKeys == [account.accountKey])
    }

    @Test func nilLastFetchFirstRefreshUsesStableDueDate() async throws {
        let account = makeAccount(lastFetchAt: nil)
        let backend = NoProgressRateLimitRefreshBackend(account: account)
        let clock = MutableTestClock(now: now)
        let store = CodexReviewStore.makeTestingStore(
            backend: backend,
            clock: .init(now: { clock.now })
        )
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: account,
            persistedAccounts: [account],
            workspaces: []
        )

        store.refreshDueAccountRateLimits(now: now)
        await Task.yield()
        #expect(backend.refreshedAccountKeys.isEmpty)

        clock.now = now.addingTimeInterval(15 * 60)
        store.refreshDueAccountRateLimits(now: clock.now)
        try await waitForCondition {
            backend.refreshedAccountKeys == [account.accountKey]
        }
    }

    private func makeAccount(
        accountKey: String? = nil,
        email: String = "review@example.com",
        lastFetchAt: Date?,
        capabilities: CodexReviewBackendModel.Account.Capabilities = .supportsCodexRateLimits,
        rateLimits: [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)] = []
    ) -> CodexReviewAccount {
        let account = CodexReviewAccount(
            accountKey: accountKey,
            email: email,
            planType: "pro",
            capabilities: capabilities
        )
        account.updateRateLimits(rateLimits)
        account.updateRateLimitFetchMetadata(fetchedAt: lastFetchAt, error: nil)
        return account
    }

    private func targets(
        accounts: [CodexReviewAccount],
        selectedAccount: CodexReviewAccount?,
        hasRunningReviewRuns: Bool,
        serverState: CodexReviewServerState = .running
    ) -> [CodexReviewStoreRateLimitAutoRefreshTarget] {
        CodexReviewStoreRateLimitAutoRefreshDriver.targets(
            accounts: accounts,
            selectedAccountKey: selectedAccount?.accountKey,
            hasRunningReviewRuns: hasRunningReviewRuns,
            serverState: serverState,
            now: now
        )
    }

    private func loadStore(
        _ store: CodexReviewStore,
        account: CodexReviewAccount,
        reviewRuns: [ReviewRunRecord]
    ) {
        store.loadForTesting(
            serverState: .running,
            authPhase: .signedOut,
            account: account,
            persistedAccounts: [account],
            workspaces: [CodexReviewWorkspace(cwd: "/tmp/repo")],
            reviewRuns: reviewRuns
        )
    }

    private func waitForCondition(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while await MainActor.run(body: condition) == false {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TestFailure("timed out")
            }
            defer {
                group.cancelAll()
            }
            try await group.next()
        }
    }
}

private struct TestFailure: Error {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}

private final class MutableTestClock: @unchecked Sendable {
    nonisolated(unsafe) var now: Date

    init(now: Date) {
        self.now = now
    }
}

@MainActor
private final class NoProgressRateLimitRefreshBackend: PreviewCodexReviewStoreBackend {
    private(set) var refreshedAccountKeys: [String] = []

    init(account: CodexReviewAccount) {
        super.init(seed: .init(
            initialAccount: account,
            initialAccounts: [account]
        ))
    }

    override func refreshAccountRateLimits(
        auth _: CodexReviewAuthModel,
        accountKey: String
    ) async {
        refreshedAccountKeys.append(accountKey)
    }
}

@MainActor
private final class BlockingRateLimitRefreshBackend: PreviewCodexReviewStoreBackend {
    private let startedGate = AsyncGate()
    private let releaseGate = AsyncGate()
    private(set) var refreshedAccountKeys: [String] = []

    init(account: CodexReviewAccount) {
        super.init(seed: .init(
            initialAccount: account,
            initialAccounts: [account]
        ))
    }

    override func refreshAccountRateLimits(
        auth _: CodexReviewAuthModel,
        accountKey: String
    ) async {
        refreshedAccountKeys.append(accountKey)
        await startedGate.open()
        await releaseGate.wait()
    }

    func waitUntilRefreshStarts() async {
        await startedGate.wait()
    }

    func releaseRefresh() async {
        await releaseGate.open()
    }
}
