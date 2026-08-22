import Foundation

@MainActor
package protocol CodexReviewSettingsBackend: AnyObject {
    var initialSettingsSnapshot: CodexReviewSettings.Snapshot { get }

    func refreshSettings() async throws -> CodexReviewSettings.Snapshot

    func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewSettings.ReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewSettings.ServiceTier?,
        persistServiceTier: Bool
    ) async throws

    func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewSettings.ReasoningEffort?
    ) async throws

    func updateSettingsServiceTier(
        _ serviceTier: CodexReviewSettings.ServiceTier?
    ) async throws
}

@MainActor
package final class CodexReviewSettingsService {
    package struct RuntimeCutoverToken: Equatable, Sendable {
        fileprivate let ownerID: UUID
        fileprivate let id: UUID
        fileprivate let sourceEpoch: UInt64
        fileprivate let targetEpoch: UInt64
    }

    package enum RuntimeCutoverError: Error, Equatable {
        case settingsStoreUnavailable
        case cutoverAlreadyInProgress
        case foreignToken
        case tokenAlreadyConsumed
        case staleToken
        case conflictingCommitSnapshot
        case epochExhausted
    }

    package enum RuntimeCutoverStatus: Equatable, Sendable {
        case active
        case draining
        case awaitingCommit
        case awaitingRecovery
    }

    private enum SettingsIntent {
        case refresh
        case model(String?)
        case reasoningEffort(CodexReviewSettings.ReasoningEffort?)
        case serviceTier(CodexReviewSettings.ServiceTier?)

        var isRefresh: Bool {
            if case .refresh = self { true } else { false }
        }
    }

    private struct QueuedIntent {
        let epoch: UInt64
        let intent: SettingsIntent
        let requiresCatalogRevalidation: Bool
    }

    private enum RuntimeCutoverPhase {
        case active(epoch: UInt64, lastConsumedTokenID: UUID?)
        case draining(RuntimeCutoverToken)
        case awaitingCommit(
            RuntimeCutoverToken,
            priorErrorMessage: String?
        )
        case committing(RuntimeCutoverToken)
        case awaitingRecovery(
            committedEpoch: UInt64,
            deferredEpoch: UInt64,
            lastConsumedTokenID: UUID
        )

        var status: RuntimeCutoverStatus {
            switch self {
            case .active:
                .active
            case .draining:
                .draining
            case .awaitingCommit, .committing:
                .awaitingCommit
            case .awaitingRecovery:
                .awaitingRecovery
            }
        }

        var admissionEpoch: UInt64 {
            switch self {
            case .active(let epoch, _):
                epoch
            case .draining(let token), .awaitingCommit(let token, _), .committing(let token):
                token.targetEpoch
            case .awaitingRecovery(_, let deferredEpoch, _):
                deferredEpoch
            }
        }

        func permitsDispatch(for epoch: UInt64) -> Bool {
            switch self {
            case .active(let activeEpoch, _):
                activeEpoch == epoch
            case .draining(let token):
                token.sourceEpoch == epoch
            case .committing(let token):
                token.targetEpoch == epoch
            case .awaitingCommit, .awaitingRecovery:
                false
            }
        }

        func permitsSubmittedIntentDrain(for epoch: UInt64) -> Bool {
            guard case .active(let activeEpoch, _) = self else {
                return false
            }
            return activeEpoch == epoch
        }

        func isDrainingSource(_ epoch: UInt64) -> Bool {
            guard case .draining(let token) = self else {
                return false
            }
            return token.sourceEpoch == epoch
        }

        func consumedTokenID() -> UUID? {
            switch self {
            case .active(_, let tokenID):
                tokenID
            case .awaitingRecovery(_, _, let tokenID):
                tokenID
            case .committing(let token):
                token.id
            case .draining, .awaitingCommit:
                nil
            }
        }
    }

    private typealias RuntimeCommitResult = Result<Void, any Error>

    private enum RuntimeCommitPublication {
        case published
        case replayPending
        case superseded
    }

    private enum RuntimeCommitOperation {
        case running(
            id: UUID,
            token: RuntimeCutoverToken,
            snapshot: CodexReviewSettings.Snapshot,
            task: Task<RuntimeCommitResult, Never>
        )
        case completed(
            id: UUID,
            token: RuntimeCutoverToken,
            snapshot: CodexReviewSettings.Snapshot,
            result: RuntimeCommitResult
        )

        var id: UUID {
            switch self {
            case .running(let id, _, _, _), .completed(let id, _, _, _):
                id
            }
        }

        var token: RuntimeCutoverToken {
            switch self {
            case .running(_, let token, _, _), .completed(_, let token, _, _):
                token
            }
        }

        var snapshot: CodexReviewSettings.Snapshot {
            switch self {
            case .running(_, _, let snapshot, _), .completed(_, _, let snapshot, _):
                snapshot
            }
        }
    }

    let initialSnapshot: CodexReviewSettings.Snapshot

    private let backend: any CodexReviewSettingsBackend
    private let cutoverOwnerID = UUID()
    private weak var settingsStore: SettingsStore?
    private var lastPersistedSelection: SettingsStore.Selection
    private var cutoverPhase: RuntimeCutoverPhase = .active(
        epoch: 0,
        lastConsumedTokenID: nil
    )
    private var queuedIntents: [QueuedIntent] = []
    private var processingEpoch: UInt64?
    private var epochDrainWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var runtimeCommitOperation: RuntimeCommitOperation?

    package var runtimeCutoverStatus: RuntimeCutoverStatus {
        cutoverPhase.status
    }

    package init(
        initialSnapshot: CodexReviewSettings.Snapshot,
        backend: any CodexReviewSettingsBackend
    ) {
        self.initialSnapshot = initialSnapshot
        self.backend = backend
        lastPersistedSelection = .init(
            model: initialSnapshot.model,
            reasoningEffort: initialSnapshot.reasoningEffort,
            serviceTier: initialSnapshot.serviceTier
        )
    }

    package func attach(settings: SettingsStore) {
        settingsStore = settings
        lastPersistedSelection = settings.currentSelection()
    }

    package func beginRuntimeCutover() async throws -> RuntimeCutoverToken {
        guard let settingsStore else {
            throw RuntimeCutoverError.settingsStoreUnavailable
        }

        let token: RuntimeCutoverToken
        switch cutoverPhase {
        case .active(let epoch, _):
            guard epoch < UInt64.max else {
                throw RuntimeCutoverError.epochExhausted
            }
            token = .init(
                ownerID: cutoverOwnerID,
                id: UUID(),
                sourceEpoch: epoch,
                targetEpoch: epoch + 1
            )
            cutoverPhase = .draining(token)

            if processingEpoch == nil {
                await drainIntents(for: token.sourceEpoch)
            } else {
                await waitUntilEpochDrained(token.sourceEpoch)
            }
            guard case .draining(token) = cutoverPhase else {
                throw RuntimeCutoverError.staleToken
            }
            cutoverPhase = .awaitingCommit(
                token,
                priorErrorMessage: settingsStore.lastErrorMessage
            )

        case .awaitingRecovery(let committedEpoch, let deferredEpoch, _):
            token = .init(
                ownerID: cutoverOwnerID,
                id: UUID(),
                sourceEpoch: committedEpoch,
                targetEpoch: deferredEpoch
            )
            cutoverPhase = .awaitingCommit(
                token,
                priorErrorMessage: settingsStore.lastErrorMessage
            )

        case .draining, .awaitingCommit, .committing:
            throw RuntimeCutoverError.cutoverAlreadyInProgress
        }

        settingsStore.beginLoading()
        return token
    }

    package func commitRuntimeSnapshot(
        token: RuntimeCutoverToken,
        snapshot: CodexReviewSettings.Snapshot
    ) async throws {
        if let operation = runtimeCommitOperation,
           operation.token == token
        {
            guard operation.snapshot == snapshot else {
                throw RuntimeCutoverError.conflictingCommitSnapshot
            }
            let result = await runtimeCommitResult(for: operation)
            clearCompletedRuntimeCommit(id: operation.id)
            try result.get()
            return
        }

        _ = try requireCurrentCutoverToken(token)
        guard settingsStore != nil else {
            throw RuntimeCutoverError.settingsStoreUnavailable
        }

        cutoverPhase = .committing(token)
        let operationID = UUID()
        let task = Task { @MainActor [self] in
            await performRuntimeCommit(
                id: operationID,
                token: token,
                snapshot: snapshot
            )
        }
        runtimeCommitOperation = .running(
            id: operationID,
            token: token,
            snapshot: snapshot,
            task: task
        )
        let result = await task.value
        clearCompletedRuntimeCommit(id: operationID)
        try result.get()
    }

    private func runtimeCommitResult(
        for operation: RuntimeCommitOperation
    ) async -> RuntimeCommitResult {
        switch operation {
        case .running(_, _, _, let task):
            await task.value
        case .completed(_, _, _, let result):
            result
        }
    }

    private func publishRuntimeCommitCompletion(
        id: UUID,
        token: RuntimeCutoverToken,
        snapshot: CodexReviewSettings.Snapshot,
        result: RuntimeCommitResult
    ) -> RuntimeCommitPublication {
        guard case .running(let runningID, let runningToken, _, _) = runtimeCommitOperation,
              runningID == id,
              runningToken == token
        else {
            return .superseded
        }
        if case .success = result,
           processingEpoch != nil || queuedIntents.contains(where: { $0.epoch == token.targetEpoch })
        {
            return .replayPending
        }

        switch result {
        case .success:
            cutoverPhase = .active(
                epoch: token.targetEpoch,
                lastConsumedTokenID: token.id
            )
        case .failure:
            cutoverPhase = .awaitingRecovery(
                committedEpoch: token.targetEpoch,
                deferredEpoch: token.targetEpoch,
                lastConsumedTokenID: token.id
            )
        }
        runtimeCommitOperation = .completed(
            id: id,
            token: token,
            snapshot: snapshot,
            result: result
        )
        return .published
    }

    private func clearCompletedRuntimeCommit(id: UUID) {
        guard case .completed(let completedID, _, _, _) = runtimeCommitOperation,
              completedID == id
        else {
            return
        }
        runtimeCommitOperation = nil
    }

    private func performRuntimeCommit(
        id: UUID,
        token: RuntimeCutoverToken,
        snapshot: CodexReviewSettings.Snapshot
    ) async -> RuntimeCommitResult {
        do {
            guard let settingsStore else {
                throw RuntimeCutoverError.settingsStoreUnavailable
            }

            settingsStore.apply(snapshot: snapshot)
            lastPersistedSelection = settingsStore.currentSelection()
            replayQueuedSelectionIntents(
                for: token.targetEpoch,
                settingsStore: settingsStore
            )
            settingsStore.finishLoading(errorMessage: nil)

            while true {
                if let error = await drainIntents(
                    for: token.targetEpoch,
                    retainingFailedIntents: true
                ) {
                    throw error
                }
                let result: RuntimeCommitResult = .success(())
                switch publishRuntimeCommitCompletion(
                    id: id,
                    token: token,
                    snapshot: snapshot,
                    result: result
                ) {
                case .published, .superseded:
                    return result
                case .replayPending:
                    continue
                }
            }
        } catch {
            if let settingsStore {
                replayQueuedSelectionIntents(
                    for: token.targetEpoch,
                    settingsStore: settingsStore
                )
                settingsStore.finishLoading(errorMessage: error.localizedDescription)
            }
            let result: RuntimeCommitResult = .failure(error)
            _ = publishRuntimeCommitCompletion(
                id: id,
                token: token,
                snapshot: snapshot,
                result: result
            )
            return result
        }
    }

    package func abortRuntimeCutover(
        token: RuntimeCutoverToken,
        message: String
    ) throws {
        _ = try requireCurrentCutoverToken(token)
        guard let settingsStore else {
            throw RuntimeCutoverError.settingsStoreUnavailable
        }

        cutoverPhase = .awaitingRecovery(
            committedEpoch: token.sourceEpoch,
            deferredEpoch: token.targetEpoch,
            lastConsumedTokenID: token.id
        )
        replayQueuedSelectionIntents(for: token.targetEpoch, settingsStore: settingsStore)
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.finishLoading(
            errorMessage: normalizedMessage.isEmpty
                ? "Runtime settings publication failed."
                : normalizedMessage
        )
    }

    package func cancelRuntimeCutover(
        token: RuntimeCutoverToken
    ) throws {
        let priorErrorMessage = try requireCurrentCutoverToken(token)
        guard let settingsStore else {
            throw RuntimeCutoverError.settingsStoreUnavailable
        }
        guard token.targetEpoch < UInt64.max else {
            throw RuntimeCutoverError.epochExhausted
        }

        let deferredEpoch = token.targetEpoch + 1
        queuedIntents = queuedIntents.map { queuedIntent in
            guard queuedIntent.epoch == token.targetEpoch else {
                return queuedIntent
            }
            return .init(
                epoch: deferredEpoch,
                intent: queuedIntent.intent,
                requiresCatalogRevalidation: queuedIntent.requiresCatalogRevalidation
            )
        }
        cutoverPhase = .awaitingRecovery(
            committedEpoch: token.sourceEpoch,
            deferredEpoch: deferredEpoch,
            lastConsumedTokenID: token.id
        )
        replayQueuedSelectionIntents(for: deferredEpoch, settingsStore: settingsStore)
        settingsStore.finishLoading(errorMessage: priorErrorMessage)
    }

    package func refreshIfRunning(serverState: CodexReviewServerState) async {
        guard case .running = serverState else {
            return
        }
        await refresh()
    }

    package func refresh() async {
        await submit(.refresh)
    }

    package func updateModel(_ model: String?) async {
        await submit(.model(model))
    }

    package func clearModelOverride() async {
        await updateModel(nil)
    }

    package func updateReasoningEffort(_ reasoningEffort: CodexReviewSettings.ReasoningEffort?) async {
        await submit(.reasoningEffort(reasoningEffort))
    }

    package func updateServiceTier(_ serviceTier: CodexReviewSettings.ServiceTier?) async {
        await submit(.serviceTier(serviceTier))
    }

    private func submit(_ intent: SettingsIntent) async {
        guard let settingsStore else {
            return
        }

        let epoch = cutoverPhase.admissionEpoch
        if intent.isRefresh == false {
            applySelectionIntent(intent, to: settingsStore)
        }
        queuedIntents.append(.init(epoch: epoch, intent: intent, requiresCatalogRevalidation: cutoverPhase.status != .active))

        guard cutoverPhase.permitsSubmittedIntentDrain(for: epoch),
              processingEpoch == nil
        else {
            return
        }
        await drainIntents(for: epoch)
    }

    private func drainIntents(for epoch: UInt64) async {
        _ = await drainIntents(for: epoch, retainingFailedIntents: false)
    }

    private func drainIntents(
        for epoch: UInt64,
        retainingFailedIntents: Bool
    ) async -> (any Error)? {
        guard processingEpoch == nil else {
            await waitUntilEpochDrained(epoch)
            return nil
        }

        processingEpoch = epoch
        defer {
            processingEpoch = nil
            resumeEpochDrainWaiters(epoch)
        }

        var retainedSelectionIntents: [QueuedIntent] = []
        while cutoverPhase.permitsDispatch(for: epoch) {
            let refreshIntents = takeQueuedRefreshIntents(for: epoch)
            if refreshIntents.isEmpty == false {
                if cutoverPhase.isDrainingSource(epoch) == false {
                    if let error = await performRefresh() {
                        guard retainingFailedIntents else {
                            continue
                        }
                        queuedIntents.insert(contentsOf: refreshIntents, at: 0)
                        queuedIntents.insert(contentsOf: retainedSelectionIntents, at: 0)
                        return error
                    }
                }
                continue
            }

            let selectionIntents = takeQueuedSelectionIntents(for: epoch)
            guard selectionIntents.isEmpty == false else {
                return nil
            }
            retainedSelectionIntents.append(contentsOf: selectionIntents)
            if let error = await persistSelectionIntents(retainedSelectionIntents) {
                if retainingFailedIntents {
                    queuedIntents.insert(contentsOf: retainedSelectionIntents, at: 0)
                    return error
                }
                retainedSelectionIntents.removeAll(keepingCapacity: true)
            }
        }
        return nil
    }

    private func performRefresh() async -> (any Error)? {
        guard let settingsStore else {
            return RuntimeCutoverError.settingsStoreUnavailable
        }

        settingsStore.beginLoading()
        do {
            let snapshot = try await backend.refreshSettings()
            settingsStore.apply(snapshot: snapshot)
            lastPersistedSelection = settingsStore.currentSelection()
            settingsStore.finishLoading(errorMessage: nil)
            return nil
        } catch {
            settingsStore.finishLoading(errorMessage: error.localizedDescription)
            return error
        }
    }

    private func persistSelectionIntents(_ intents: [QueuedIntent]) async -> (any Error)? {
        guard let settingsStore else {
            return RuntimeCutoverError.settingsStoreUnavailable
        }

        let previous = lastPersistedSelection
        let candidate = composedSelection(
            from: intents,
            baseline: previous,
            settingsStore: settingsStore
        )
        settingsStore.applyNormalizedSelection(candidate, catalog: settingsStore.models)
        let triggers = settingsStore.selectionTriggers(
            previous: previous,
            candidate: candidate
        )
        guard triggers.isEmpty == false else {
            return nil
        }

        var appliedSelection = previous
        for trigger in triggers {
            if let error = await persistSelectionChange(
                trigger: trigger,
                previous: appliedSelection,
                candidate: candidate
            ) {
                return error
            }
            appliedSelection = settingsStore.selectionAfterPersisting(
                trigger: trigger,
                previous: appliedSelection,
                candidate: candidate
            )
        }
        return nil
    }

    private func persistSelectionChange(
        trigger: SettingsStore.SelectionTrigger,
        previous: SettingsStore.Selection,
        candidate: SettingsStore.Selection
    ) async -> (any Error)? {
        guard let settingsStore else {
            return RuntimeCutoverError.settingsStoreUnavailable
        }

        settingsStore.beginLoading()
        do {
            try await persistSelection(
                trigger: trigger,
                previous: previous,
                candidate: candidate
            )
            lastPersistedSelection = settingsStore.selectionAfterPersisting(
                trigger: trigger,
                previous: previous,
                candidate: candidate
            )
            settingsStore.finishLoading(errorMessage: nil)
            return nil
        } catch {
            settingsStore.apply(snapshot: settingsStore.snapshot(selection: previous))
            lastPersistedSelection = previous
            settingsStore.finishLoading(errorMessage: error.localizedDescription)
            return error
        }
    }

    private func applySelectionIntent(
        _ intent: SettingsIntent,
        to settingsStore: SettingsStore
    ) {
        let current = settingsStore.currentSelection()
        let normalized: SettingsStore.Selection
        switch intent {
        case .refresh:
            return
        case .model(let model):
            normalized = settingsStore.normalizeSelection(
                model: model,
                reasoningEffort: current.reasoningEffort,
                serviceTier: current.serviceTier,
                catalog: settingsStore.models,
                clearIncompatibleOverrides: true
            )
        case .reasoningEffort(let reasoningEffort):
            normalized = settingsStore.normalizeSelection(
                model: current.model,
                reasoningEffort: reasoningEffort,
                serviceTier: current.serviceTier,
                catalog: settingsStore.models,
                clearIncompatibleOverrides: false
            )
        case .serviceTier(let serviceTier):
            normalized = settingsStore.normalizeSelection(
                model: current.model,
                reasoningEffort: current.reasoningEffort,
                serviceTier: serviceTier,
                catalog: settingsStore.models,
                clearIncompatibleOverrides: false
            )
        }
        settingsStore.applyNormalizedSelection(normalized, catalog: settingsStore.models)
    }

    private func replayQueuedSelectionIntents(
        for epoch: UInt64,
        settingsStore: SettingsStore
    ) {
        let intents = queuedIntents.filter {
            $0.epoch == epoch && $0.intent.isRefresh == false
        }
        guard intents.isEmpty == false else {
            return
        }
        let selection = composedSelection(
            from: intents,
            baseline: lastPersistedSelection,
            settingsStore: settingsStore
        )
        settingsStore.applyNormalizedSelection(selection, catalog: settingsStore.models)
    }

    private func composedSelection(
        from intents: [QueuedIntent],
        baseline: SettingsStore.Selection,
        settingsStore: SettingsStore
    ) -> SettingsStore.Selection {
        var model = baseline.model
        var reasoningEffort = baseline.reasoningEffort
        var serviceTier = baseline.serviceTier
        var hasModelIntent = false
        var requiresCatalogRevalidation = false

        for queuedIntent in intents {
            requiresCatalogRevalidation = requiresCatalogRevalidation
                || queuedIntent.requiresCatalogRevalidation
            switch queuedIntent.intent {
            case .refresh:
                break
            case .model(let value):
                model = value
                hasModelIntent = true
            case .reasoningEffort(let value):
                reasoningEffort = value
            case .serviceTier(let value):
                serviceTier = value
            }
        }

        return settingsStore.normalizeSelection(
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            catalog: settingsStore.models,
            clearIncompatibleOverrides: hasModelIntent || requiresCatalogRevalidation
        )
    }

    private func takeQueuedRefreshIntents(for epoch: UInt64) -> [QueuedIntent] {
        var intents: [QueuedIntent] = []
        queuedIntents.removeAll { queuedIntent in
            guard queuedIntent.epoch == epoch,
                  queuedIntent.intent.isRefresh
            else {
                return false
            }
            intents.append(queuedIntent)
            return true
        }
        return intents
    }

    private func takeQueuedSelectionIntents(for epoch: UInt64) -> [QueuedIntent] {
        var intents: [QueuedIntent] = []
        queuedIntents.removeAll { queuedIntent in
            guard queuedIntent.epoch == epoch,
                  queuedIntent.intent.isRefresh == false
            else {
                return false
            }
            intents.append(queuedIntent)
            return true
        }
        return intents
    }

    private func waitUntilEpochDrained(_ epoch: UInt64) async {
        guard processingEpoch == epoch || queuedIntents.contains(where: { $0.epoch == epoch }) else {
            return
        }
        await withCheckedContinuation { continuation in
            epochDrainWaiters[epoch, default: []].append(continuation)
        }
    }

    private func resumeEpochDrainWaiters(_ epoch: UInt64) {
        let waiters = epochDrainWaiters.removeValue(forKey: epoch) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func requireCurrentCutoverToken(
        _ token: RuntimeCutoverToken
    ) throws -> String? {
        guard token.ownerID == cutoverOwnerID else {
            throw RuntimeCutoverError.foreignToken
        }
        if cutoverPhase.consumedTokenID() == token.id {
            throw RuntimeCutoverError.tokenAlreadyConsumed
        }
        guard case .awaitingCommit(let currentToken, let priorErrorMessage) = cutoverPhase,
              currentToken == token
        else {
            throw RuntimeCutoverError.staleToken
        }
        return priorErrorMessage
    }

    private func persistSelection(
        trigger: SettingsStore.SelectionTrigger,
        previous: SettingsStore.Selection,
        candidate: SettingsStore.Selection
    ) async throws {
        switch trigger {
        case .model:
            try await backend.updateSettingsModel(
                candidate.model,
                reasoningEffort: candidate.reasoningEffort,
                persistReasoningEffort: previous.reasoningEffort != candidate.reasoningEffort,
                serviceTier: candidate.serviceTier,
                persistServiceTier: previous.serviceTier != candidate.serviceTier
            )
        case .reasoningEffort:
            try await backend.updateSettingsReasoningEffort(candidate.reasoningEffort)
        case .serviceTier:
            try await backend.updateSettingsServiceTier(candidate.serviceTier)
        }
    }
}
