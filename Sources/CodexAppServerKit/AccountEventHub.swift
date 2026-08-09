import Foundation
import Synchronization

package actor AccountEventHub {
    package enum Mutation: Equatable, Sendable {
        case updated(AppServerNotificationDecoder.AccountUpdate)
        case rateLimitsUpdated(AppServerAPI.Account.RateLimits.Snapshot)
    }

    private var rateLimitsResponse: AppServerAPI.Account.RateLimits.Response?
    private let subscriptionRegistry = AccountEventSubscriptionRegistry()

    package init() {}

    package func events() -> CodexAccountEvents {
        subscriptionRegistry.makeEvents()
    }

    package var subscriberCountForTesting: Int {
        subscriptionRegistry.count
    }

    package func replaceRateLimits(
        with response: AppServerAPI.Account.RateLimits.Response
    ) {
        rateLimitsResponse = response
    }

    package func apply(_ mutation: Mutation) {
        guard subscriptionRegistry.isFinished == false else {
            return
        }
        switch mutation {
        case .updated:
            yield(.accountUpdated)
        case .rateLimitsUpdated(let update):
            let base = rateLimitsResponse ?? .init(rateLimits: update)
            let merged = base.merging(update)
            rateLimitsResponse = merged
            guard AppServerAPI.Account.RateLimits.Response.isCodexRateLimit(update.limitID) else {
                return
            }
            yield(.rateLimitsUpdated(.init(appServer: merged)))
        }
    }

    package func finish(throwing error: CodexAppServerError) {
        subscriptionRegistry.finish(throwing: error)
    }

    private func yield(_ event: CodexAccountEvent) {
        subscriptionRegistry.yield(event)
    }
}

public struct CodexAccountEvents: AsyncSequence, Sendable {
    public typealias Element = CodexAccountEvent

    private let channel: AccountEventSubscriberChannel
    private let cancellation: AccountEventSubscriptionCancellation

    fileprivate init(
        channel: AccountEventSubscriberChannel,
        cancellation: AccountEventSubscriptionCancellation
    ) {
        self.channel = channel
        self.cancellation = cancellation
    }

    public func makeAsyncIterator() -> Iterator {
        .init(channel: channel, cancellation: cancellation)
    }

    public func cancel() async {
        cancellation.cancel()
    }

    package func waitUntilNextSuspendsForTesting() async {
        await channel.waitUntilNextSuspendsForTesting()
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let channel: AccountEventSubscriberChannel
        private let cancellation: AccountEventSubscriptionCancellation

        fileprivate init(
            channel: AccountEventSubscriberChannel,
            cancellation: AccountEventSubscriptionCancellation
        ) {
            self.channel = channel
            self.cancellation = cancellation
        }

        public mutating func next() async throws -> CodexAccountEvent? {
            try await channel.next(cancellation: cancellation)
        }
    }
}

private final class AccountEventSubscriberChannel: Sendable {
    private enum Terminal {
        case open
        case finished(CodexAppServerError?)
    }

    private struct PendingEvent {
        var sequence: UInt64
        var event: CodexAccountEvent
    }

    private struct State {
        var nextSequence: UInt64 = 0
        var accountChanged: PendingEvent?
        var rateLimits: PendingEvent?
        var waiter: CheckedContinuation<
            Result<CodexAccountEvent?, CodexAppServerError>, Never
        >?
        var suspensionObservers: [CheckedContinuation<Void, Never>] = []
        var terminal = Terminal.open
    }

    private let state = Mutex(State())

    func yield(_ event: CodexAccountEvent) {
        let waiter = state.withLock { state -> CheckedContinuation<
            Result<CodexAccountEvent?, CodexAppServerError>, Never
        >? in
            guard case .open = state.terminal else {
                return nil
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            switch event {
            case .accountUpdated:
                let sequence = state.accountChanged?.sequence ?? state.nextSequence
                state.accountChanged = .init(sequence: sequence, event: event)
            case .rateLimitsUpdated:
                let sequence = state.rateLimits?.sequence ?? state.nextSequence
                state.rateLimits = .init(sequence: sequence, event: event)
            case .malformed, .unknown:
                preconditionFailure("AccountEventHub received an event outside its owned kinds.")
            }
            state.nextSequence &+= 1
            return nil
        }
        waiter?.resume(returning: .success(event))
    }

    func next(
        cancellation: AccountEventSubscriptionCancellation
    ) async throws -> CodexAccountEvent? {
        try await withTaskCancellationHandler {
            let result = await withCheckedContinuation { continuation in
                let registration = state.withLock { state -> (
                    Result<CodexAccountEvent?, CodexAppServerError>?,
                    [CheckedContinuation<Void, Never>]
                ) in
                    if let event = Self.takeNextPending(from: &state) {
                        return (.success(event), [])
                    }
                    switch state.terminal {
                    case .open:
                        precondition(state.waiter == nil, "CodexAccountEvents supports one iterator.")
                        state.waiter = continuation
                        let observers = state.suspensionObservers
                        state.suspensionObservers.removeAll()
                        return (nil, observers)
                    case .finished(let error):
                        if let error {
                            return (.failure(error), [])
                        }
                        return (.success(nil), [])
                    }
                }
                for observer in registration.1 {
                    observer.resume()
                }
                if let immediate = registration.0 {
                    continuation.resume(returning: immediate)
                }
            }
            return try result.get()
        } onCancel: {
            cancellation.cancel()
        }
    }

    func waitUntilNextSuspendsForTesting() async {
        await withCheckedContinuation { continuation in
            let isAlreadySuspendedOrFinished = state.withLock { state in
                if state.waiter != nil {
                    return true
                }
                guard case .open = state.terminal else {
                    return true
                }
                state.suspensionObservers.append(continuation)
                return false
            }
            if isAlreadySuspendedOrFinished {
                continuation.resume()
            }
        }
    }

    func finish(throwing error: CodexAppServerError?) {
        let completion = state.withLock { state -> (
            CheckedContinuation<Result<CodexAccountEvent?, CodexAppServerError>, Never>?,
            [CheckedContinuation<Void, Never>]
        ) in
            guard case .open = state.terminal else {
                return (nil, [])
            }
            state.terminal = .finished(error)
            state.accountChanged = nil
            state.rateLimits = nil
            let waiter = state.waiter
            state.waiter = nil
            let observers = state.suspensionObservers
            state.suspensionObservers.removeAll()
            return (waiter, observers)
        }
        for observer in completion.1 {
            observer.resume()
        }
        if let error {
            completion.0?.resume(returning: .failure(error))
        } else {
            completion.0?.resume(returning: .success(nil))
        }
    }

    private static func takeNextPending(from state: inout State) -> CodexAccountEvent? {
        enum Kind {
            case accountChanged
            case rateLimits
        }
        let candidates: [(Kind, PendingEvent)] = [
            state.accountChanged.map { (.accountChanged, $0) },
            state.rateLimits.map { (.rateLimits, $0) },
        ].compactMap(\.self)
        guard let (kind, pending) = candidates.min(by: { $0.1.sequence < $1.1.sequence }) else {
            return nil
        }
        switch kind {
        case .accountChanged:
            state.accountChanged = nil
        case .rateLimits:
            state.rateLimits = nil
        }
        return pending.event
    }
}

private final class AccountEventSubscriptionCancellation: Sendable {
    private struct State {
        var isCancelled = false
    }

    private let state = Mutex(State())
    private let id: UUID
    private let registry: AccountEventSubscriptionRegistry

    init(id: UUID, registry: AccountEventSubscriptionRegistry) {
        self.id = id
        self.registry = registry
    }

    func cancel() {
        let shouldRemove = state.withLock { state in
            guard state.isCancelled == false else {
                return false
            }
            state.isCancelled = true
            return true
        }
        if shouldRemove {
            registry.remove(id)
        }
    }

    deinit {
        cancel()
    }
}

private final class AccountEventSubscriptionRegistry: Sendable {
    private struct State {
        var channels: [UUID: AccountEventSubscriberChannel] = [:]
        var terminalError: CodexAppServerError?
    }

    private let state = Mutex(State())

    var isFinished: Bool {
        state.withLock { $0.terminalError != nil }
    }

    var count: Int {
        state.withLock { $0.channels.count }
    }

    func makeEvents() -> CodexAccountEvents {
        let id = UUID()
        let channel = AccountEventSubscriberChannel()
        let cancellation = AccountEventSubscriptionCancellation(id: id, registry: self)
        let terminalError = state.withLock { state -> CodexAppServerError? in
            guard let terminalError = state.terminalError else {
                state.channels[id] = channel
                return nil
            }
            return terminalError
        }
        if let terminalError {
            channel.finish(throwing: terminalError)
        }
        return .init(channel: channel, cancellation: cancellation)
    }

    func yield(_ event: CodexAccountEvent) {
        let channels = state.withLock { Array($0.channels.values) }
        for channel in channels {
            channel.yield(event)
        }
    }

    func remove(_ id: UUID) {
        let channel = state.withLock { $0.channels.removeValue(forKey: id) }
        channel?.finish(throwing: nil)
    }

    func finish(throwing error: CodexAppServerError) {
        let channels = state.withLock { state -> [AccountEventSubscriberChannel] in
            guard state.terminalError == nil else {
                return []
            }
            state.terminalError = error
            let channels = Array(state.channels.values)
            state.channels.removeAll()
            return channels
        }
        for channel in channels {
            channel.finish(throwing: error)
        }
    }
}

extension AppServerAPI.Account.RateLimits.Snapshot {
    package func merging(
        _ sparseUpdate: AppServerAPI.Account.RateLimits.Snapshot
    ) -> AppServerAPI.Account.RateLimits.Snapshot {
        .init(
            limitID: sparseUpdate.limitID ?? limitID,
            primary: primary.merging(sparseUpdate.primary),
            secondary: secondary.merging(sparseUpdate.secondary),
            planType: sparseUpdate.planType ?? planType
        )
    }

    fileprivate var normalizedLimitID: String {
        let trimmed = limitID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return if let trimmed, trimmed.isEmpty == false {
            trimmed
        } else {
            "codex"
        }
    }
}

private extension Optional where Wrapped == AppServerAPI.Account.RateLimits.Window {
    func merging(
        _ sparseUpdate: AppServerAPI.Account.RateLimits.Window?
    ) -> AppServerAPI.Account.RateLimits.Window? {
        guard let sparseUpdate else {
            return self
        }
        guard let current = self else {
            return sparseUpdate
        }
        return .init(
            usedPercent: sparseUpdate.usedPercent,
            windowDurationMins: sparseUpdate.windowDurationMins
                ?? current.windowDurationMins,
            resetsAt: sparseUpdate.resetsAt ?? current.resetsAt
        )
    }
}

extension AppServerAPI.Account.RateLimits.Response {
    package func merging(
        _ sparseUpdate: AppServerAPI.Account.RateLimits.Snapshot
    ) -> AppServerAPI.Account.RateLimits.Response {
        let updateID = sparseUpdate.normalizedLimitID
        var rateLimits = rateLimits
        var rateLimitsByLimitID = rateLimitsByLimitID

        if var snapshots = rateLimitsByLimitID {
            let existing = snapshots[updateID]
                ?? snapshots.first(where: { key, value in
                    key == updateID || value.normalizedLimitID == updateID
                })?.value
                ?? .init(limitID: sparseUpdate.limitID)
            snapshots[updateID] = existing.merging(sparseUpdate)
            rateLimitsByLimitID = snapshots
        } else if rateLimits.normalizedLimitID == updateID {
            rateLimits = rateLimits.merging(sparseUpdate)
        } else {
            rateLimitsByLimitID = [
                rateLimits.normalizedLimitID: rateLimits,
                updateID: sparseUpdate,
            ]
        }

        return .init(
            rateLimits: rateLimits,
            rateLimitsByLimitID: rateLimitsByLimitID
        )
    }
}
