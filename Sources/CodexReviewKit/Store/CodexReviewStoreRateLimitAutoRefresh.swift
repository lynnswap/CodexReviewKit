import Foundation
import ObservationBridge

package struct CodexReviewStoreRateLimitAutoRefreshTarget: Equatable, Sendable {
    package enum Kind: Hashable, Sendable {
        case selectedRunningInterval
        case selectedIdleInterval
        case backgroundInterval
        case resetWindow
        case retryAfterNoProgress

        fileprivate var isInterval: Bool {
            switch self {
            case .selectedRunningInterval, .selectedIdleInterval, .backgroundInterval:
                true
            case .resetWindow, .retryAfterNoProgress:
                false
            }
        }
    }

    package var accountKey: String
    package var kind: Kind
    package var dueAt: Date

    package init(
        accountKey: String,
        kind: Kind,
        dueAt: Date
    ) {
        self.accountKey = accountKey
        self.kind = kind
        self.dueAt = dueAt
    }
}

private struct CodexReviewStoreRateLimitAutoRefreshContext {
    var selectedAccountKey: String?
    var hasRunningReviewRuns: Bool
    var serverState: CodexReviewServerState
    var now: Date
}

@MainActor
private struct CodexReviewStoreRateLimitAutoRefreshPolicy {
    var selectedRunningInterval: TimeInterval = 60
    var selectedIdleInterval: TimeInterval = 15 * 60
    var backgroundInterval: TimeInterval = 15 * 60
    var resetRefreshDelay: TimeInterval = 60
    var noProgressRefreshRetryDelay: TimeInterval = 60

    func targets(
        accounts: [CodexReviewAccount],
        context: CodexReviewStoreRateLimitAutoRefreshContext
    ) -> [CodexReviewStoreRateLimitAutoRefreshTarget] {
        guard case .running = context.serverState else {
            return []
        }

        return accounts.compactMap { account in
            target(for: account, context: context)
        }.sorted {
            if $0.dueAt == $1.dueAt {
                return $0.accountKey < $1.accountKey
            }
            return $0.dueAt < $1.dueAt
        }
    }

    private func target(
        for account: CodexReviewAccount,
        context: CodexReviewStoreRateLimitAutoRefreshContext
    ) -> CodexReviewStoreRateLimitAutoRefreshTarget? {
        guard account.capabilities.supportsRateLimitRefresh else {
            return nil
        }

        let intervalTarget = intervalTarget(for: account, context: context)
        guard let resetTarget = resetTarget(for: account),
              resetTarget.dueAt < intervalTarget.dueAt
        else {
            return intervalTarget
        }
        return resetTarget
    }

    private func intervalTarget(
        for account: CodexReviewAccount,
        context: CodexReviewStoreRateLimitAutoRefreshContext
    ) -> CodexReviewStoreRateLimitAutoRefreshTarget {
        let kind: CodexReviewStoreRateLimitAutoRefreshTarget.Kind
        let interval: TimeInterval
        switch role(for: account, context: context) {
        case .selected:
            if context.hasRunningReviewRuns {
                kind = .selectedRunningInterval
                interval = selectedRunningInterval
            } else {
                kind = .selectedIdleInterval
                interval = selectedIdleInterval
            }
        case .background:
            kind = .backgroundInterval
            interval = backgroundInterval
        }

        return .init(
            accountKey: account.accountKey,
            kind: kind,
            dueAt: (account.lastRateLimitFetchAt ?? context.now).addingTimeInterval(interval)
        )
    }

    private func resetTarget(for account: CodexReviewAccount) -> CodexReviewStoreRateLimitAutoRefreshTarget? {
        nextUnconsumedResetRefreshDate(for: account).map {
            .init(
                accountKey: account.accountKey,
                kind: .resetWindow,
                dueAt: $0
            )
        }
    }

    private func role(
        for account: CodexReviewAccount,
        context: CodexReviewStoreRateLimitAutoRefreshContext
    ) -> CodexReviewStoreRateLimitAutoRefreshRole {
        account.accountKey == context.selectedAccountKey ? .selected : .background
    }

    private func nextUnconsumedResetRefreshDate(for account: CodexReviewAccount) -> Date? {
        account.rateLimits
            .compactMap { window -> Date? in
                guard let resetsAt = window.resetsAt else {
                    return nil
                }
                let dueAt = resetsAt.addingTimeInterval(resetRefreshDelay)
                if let lastRateLimitFetchAt = account.lastRateLimitFetchAt,
                   lastRateLimitFetchAt >= dueAt
                {
                    return nil
                }
                return dueAt
            }
            .min()
    }
}

private enum CodexReviewStoreRateLimitAutoRefreshRole {
    case selected
    case background
}

@MainActor
private struct CodexReviewStoreRateLimitAutoRefreshAccountState {
    var firstIntervalDueAtByKind: [CodexReviewStoreRateLimitAutoRefreshTarget.Kind: Date] = [:]
    var suppressedUntil: Date?
    var refreshTask: Task<Void, Never>?

    var isRefreshing: Bool {
        refreshTask != nil
    }

    mutating func scheduledTarget(
        from target: CodexReviewStoreRateLimitAutoRefreshTarget,
        account: CodexReviewAccount,
        now: Date
    ) -> CodexReviewStoreRateLimitAutoRefreshTarget {
        if let suppressedUntil, suppressedUntil <= now {
            self.suppressedUntil = nil
        }

        var target = target
        if account.lastRateLimitFetchAt == nil,
           target.kind.isInterval,
           target.dueAt > now
        {
            let firstDueAt = firstIntervalDueAtByKind[target.kind] ?? target.dueAt
            firstIntervalDueAtByKind[target.kind] = firstDueAt
            target.dueAt = min(target.dueAt, firstDueAt)
        } else if account.lastRateLimitFetchAt != nil {
            firstIntervalDueAtByKind.removeAll(keepingCapacity: false)
        }

        if let suppressedUntil = self.suppressedUntil,
           suppressedUntil > target.dueAt
        {
            target.kind = .retryAfterNoProgress
            target.dueAt = suppressedUntil
        }
        return target
    }

    mutating func recordRefreshCompletion(
        lastFetchAtBeforeRefresh: Date?,
        lastFetchAtAfterRefresh: Date?,
        now: Date,
        retryDelay: TimeInterval
    ) {
        refreshTask = nil
        if Self.fetchMetadataAdvanced(
            before: lastFetchAtBeforeRefresh,
            after: lastFetchAtAfterRefresh
        ) {
            suppressedUntil = nil
            firstIntervalDueAtByKind.removeAll(keepingCapacity: false)
        } else {
            suppressedUntil = now.addingTimeInterval(retryDelay)
        }
    }

    private static func fetchMetadataAdvanced(before: Date?, after: Date?) -> Bool {
        guard let after else {
            return false
        }
        guard let before else {
            return true
        }
        return after > before
    }
}

@MainActor
extension CodexReviewStore {
    package func startAccountRateLimitAutoRefresh() {
        if accountRateLimitAutoRefreshDriver == nil {
            accountRateLimitAutoRefreshDriver = CodexReviewStoreRateLimitAutoRefreshDriver(store: self)
        }
        accountRateLimitAutoRefreshDriver?.start()
    }

    package func accountRateLimitAutoRefreshTargets(now: Date) -> [CodexReviewStoreRateLimitAutoRefreshTarget] {
        CodexReviewStoreRateLimitAutoRefreshDriver.targets(
            accounts: auth.accounts,
            selectedAccountKey: auth.selectedAccount?.accountKey,
            hasRunningReviewRuns: hasRunningReviewRuns,
            serverState: serverState,
            now: now
        )
    }

    package func refreshDueAccountRateLimits(now: Date) {
        startAccountRateLimitAutoRefresh()
        accountRateLimitAutoRefreshDriver?.refreshDueAccounts(now: now)
    }

    package var accountRateLimitAutoRefreshInFlightAccountKeys: Set<String> {
        accountRateLimitAutoRefreshDriver?.inFlightAccountKeys ?? []
    }
}

@MainActor
package final class CodexReviewStoreRateLimitAutoRefreshDriver {
    private static let policy = CodexReviewStoreRateLimitAutoRefreshPolicy()

    private struct ScheduledWakeUp {
        var dueAt: Date
        var task: Task<Void, Never>
    }

    private weak var store: CodexReviewStore?
    private var observation: PortableObservationTracking.Token?
    private var scheduledWakeUp: ScheduledWakeUp?
    private var accountStates: [String: CodexReviewStoreRateLimitAutoRefreshAccountState] = [:]
    package var inFlightAccountKeys: Set<String> {
        Set(accountStates.compactMap { accountKey, state in
            state.isRefreshing ? accountKey : nil
        })
    }

    init(store: CodexReviewStore) {
        self.store = store
    }

    package static func targets(
        accounts: [CodexReviewAccount],
        selectedAccountKey: String?,
        hasRunningReviewRuns: Bool,
        serverState: CodexReviewServerState,
        now: Date
    ) -> [CodexReviewStoreRateLimitAutoRefreshTarget] {
        policy.targets(
            accounts: accounts,
            context: .init(
                selectedAccountKey: selectedAccountKey,
                hasRunningReviewRuns: hasRunningReviewRuns,
                serverState: serverState,
                now: now
            )
        )
    }

    func start() {
        guard observation == nil else {
            syncLatestTargets()
            return
        }
        observation = withPortableContinuousObservation { [weak self, weak store] _ in
            guard let self, let store else {
                return
            }
            let now = store.clock.now()
            let targets = store.accountRateLimitAutoRefreshTargets(now: now)
            self.syncTargets(targets, now: now)
        }
    }

    func cancel() {
        observation?.cancel()
        observation = nil
        scheduledWakeUp?.task.cancel()
        scheduledWakeUp = nil
        accountStates.values.forEach { state in
            state.refreshTask?.cancel()
        }
        accountStates.removeAll(keepingCapacity: false)
    }

    func refreshDueAccounts(now: Date) {
        guard let store else {
            return
        }
        syncTargets(store.accountRateLimitAutoRefreshTargets(now: now), now: now)
    }

    private func syncLatestTargets() {
        guard let store else {
            return
        }
        let now = store.clock.now()
        syncTargets(
            store.accountRateLimitAutoRefreshTargets(now: now),
            now: now
        )
    }

    private func syncTargets(
        _ targets: [CodexReviewStoreRateLimitAutoRefreshTarget],
        now: Date
    ) {
        let targets = scheduledTargets(from: targets, now: now)
        for target in targets {
            guard accountStates[target.accountKey]?.isRefreshing != true else {
                continue
            }
            if target.dueAt <= now {
                startRefresh(accountKey: target.accountKey)
            }
        }

        let nextDueAt = targets
            .filter { target in
                target.dueAt > now && accountStates[target.accountKey]?.isRefreshing != true
            }
            .map(\.dueAt)
            .min()
        scheduleWakeUp(at: nextDueAt, now: now)
    }

    private func scheduledTargets(
        from targets: [CodexReviewStoreRateLimitAutoRefreshTarget],
        now: Date
    ) -> [CodexReviewStoreRateLimitAutoRefreshTarget] {
        guard let store else {
            accountStates.removeAll(keepingCapacity: false)
            return targets
        }

        let targetAccountKeys = Set(targets.map(\.accountKey))
        let accountsByKey = Dictionary(uniqueKeysWithValues: store.auth.accounts.map {
            ($0.accountKey, $0)
        })
        pruneAccountStates(targetAccountKeys: targetAccountKeys)

        return targets.compactMap { target in
            guard let account = accountsByKey[target.accountKey] else {
                return nil
            }
            var state = accountStates[target.accountKey] ?? .init()
            let scheduledTarget = state.scheduledTarget(
                from: target,
                account: account,
                now: now
            )
            accountStates[target.accountKey] = state
            return scheduledTarget
        }
    }

    private func pruneAccountStates(targetAccountKeys: Set<String>) {
        accountStates = accountStates.filter { accountKey, state in
            targetAccountKeys.contains(accountKey) || state.isRefreshing
        }
    }

    private func scheduleWakeUp(at dueAt: Date?, now: Date) {
        guard let dueAt else {
            scheduledWakeUp?.task.cancel()
            scheduledWakeUp = nil
            return
        }
        guard scheduledWakeUp?.dueAt != dueAt else {
            return
        }
        scheduledWakeUp?.task.cancel()
        let delay = max(0, dueAt.timeIntervalSince(now))
        scheduledWakeUp = .init(
            dueAt: dueAt,
            task: Task { @MainActor [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard Task.isCancelled == false else {
                    return
                }
                self?.scheduledWakeUp = nil
                self?.syncLatestTargets()
            }
        )
    }

    private func startRefresh(accountKey: String) {
        guard accountStates[accountKey]?.isRefreshing != true else {
            return
        }
        accountStates[accountKey, default: .init()].refreshTask = Task { @MainActor [weak self, weak store] in
            guard let self, let store else {
                return
            }
            let lastFetchAtBeforeRefresh = store.auth.accounts
                .first(where: { $0.accountKey == accountKey })?
                .lastRateLimitFetchAt
            await store.refreshAccountRateLimits(accountKey: accountKey)
            guard Task.isCancelled == false else {
                return
            }
            let lastFetchAtAfterRefresh = store.auth.accounts
                .first(where: { $0.accountKey == accountKey })?
                .lastRateLimitFetchAt
            var state = self.accountStates[accountKey] ?? .init()
            state.recordRefreshCompletion(
                lastFetchAtBeforeRefresh: lastFetchAtBeforeRefresh,
                lastFetchAtAfterRefresh: lastFetchAtAfterRefresh,
                now: store.clock.now(),
                retryDelay: Self.policy.noProgressRefreshRetryDelay
            )
            self.accountStates[accountKey] = state
            self.syncLatestTargets()
        }
    }
}
