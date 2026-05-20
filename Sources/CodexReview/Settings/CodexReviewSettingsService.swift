import Foundation

@MainActor
package protocol CodexReviewSettingsBackend: AnyObject {
    var initialSettingsSnapshot: CodexReviewSettingsSnapshot { get }

    func refreshSettings() async throws -> CodexReviewSettingsSnapshot

    func updateSettingsModel(
        _ model: String?,
        reasoningEffort: CodexReviewReasoningEffort?,
        persistReasoningEffort: Bool,
        serviceTier: CodexReviewServiceTier?,
        persistServiceTier: Bool
    ) async throws

    func updateSettingsReasoningEffort(
        _ reasoningEffort: CodexReviewReasoningEffort?
    ) async throws

    func updateSettingsServiceTier(
        _ serviceTier: CodexReviewServiceTier?
    ) async throws
}

@MainActor
package final class CodexReviewSettingsService {
    let initialSnapshot: CodexReviewSettingsSnapshot

    private let backend: any CodexReviewSettingsBackend
    private weak var settingsStore: SettingsStore?
    private var pendingRefresh = false
    private var pendingSelection: SettingsStore.Selection?
    private var lastPersistedSelection: SettingsStore.Selection

    package init(
        initialSnapshot: CodexReviewSettingsSnapshot,
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

    package func refreshIfRunning(serverState: CodexReviewServerState) async {
        guard case .running = serverState else {
            return
        }
        await refresh()
    }

    package func refresh() async {
        guard let settingsStore else {
            return
        }
        guard settingsStore.isLoading == false else {
            pendingRefresh = true
            return
        }

        settingsStore.beginLoading()
        do {
            let snapshot = try await backend.refreshSettings()
            settingsStore.apply(snapshot: snapshot)
            lastPersistedSelection = settingsStore.currentSelection()
            settingsStore.finishLoading(errorMessage: nil)
        } catch {
            settingsStore.finishLoading(errorMessage: error.localizedDescription)
        }
        await drainPendingWorkIfNeeded()
    }

    package func updateModel(_ model: String?) async {
        await applySelectionChange(
            trigger: .model,
            candidate: { settingsStore in
                .init(
                    model: model,
                    reasoningEffort: settingsStore.currentSelection().reasoningEffort,
                    serviceTier: settingsStore.currentSelection().serviceTier
                )
            }
        )
    }

    package func clearModelOverride() async {
        await updateModel(nil)
    }

    package func updateReasoningEffort(_ reasoningEffort: CodexReviewReasoningEffort?) async {
        await applySelectionChange(
            trigger: .reasoningEffort,
            candidate: { settingsStore in
                .init(
                    model: settingsStore.currentSelection().model,
                    reasoningEffort: reasoningEffort,
                    serviceTier: settingsStore.currentSelection().serviceTier
                )
            }
        )
    }

    package func updateServiceTier(_ serviceTier: CodexReviewServiceTier?) async {
        await applySelectionChange(
            trigger: .serviceTier,
            candidate: { settingsStore in
                .init(
                    model: settingsStore.currentSelection().model,
                    reasoningEffort: settingsStore.currentSelection().reasoningEffort,
                    serviceTier: serviceTier
                )
            }
        )
    }

    private func applySelectionChange(
        trigger: SettingsStore.SelectionTrigger,
        candidate: (SettingsStore) -> SettingsStore.Selection
    ) async {
        guard let settingsStore else {
            return
        }

        let normalized = settingsStore.normalizeSelection(
            model: candidate(settingsStore).model,
            reasoningEffort: candidate(settingsStore).reasoningEffort,
            serviceTier: candidate(settingsStore).serviceTier,
            catalog: settingsStore.models,
            clearIncompatibleOverrides: trigger == .model
        )
        settingsStore.applyNormalizedSelection(normalized, catalog: settingsStore.models)

        guard settingsStore.isLoading == false else {
            pendingSelection = normalized
            return
        }
        guard normalized != lastPersistedSelection else {
            pendingSelection = nil
            return
        }

        await persistSelectionChange(
            trigger: trigger,
            previous: lastPersistedSelection,
            candidate: normalized
        )
    }

    private func persistSelectionChange(
        trigger: SettingsStore.SelectionTrigger,
        previous: SettingsStore.Selection,
        candidate: SettingsStore.Selection
    ) async {
        guard let settingsStore else {
            return
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
        } catch {
            settingsStore.apply(snapshot: settingsStore.snapshot(selection: previous))
            lastPersistedSelection = previous
            settingsStore.finishLoading(errorMessage: error.localizedDescription)
        }
        await drainPendingWorkIfNeeded()
    }

    private func drainPendingWorkIfNeeded() async {
        if pendingRefresh {
            pendingRefresh = false
            await refresh()
            return
        }
        guard let pendingSelection, let settingsStore else {
            return
        }
        self.pendingSelection = nil

        let previous = lastPersistedSelection
        let triggers = settingsStore.selectionTriggers(
            previous: previous,
            candidate: pendingSelection
        )
        guard triggers.isEmpty == false else {
            return
        }

        var appliedSelection = previous
        for trigger in triggers {
            await persistSelectionChange(
                trigger: trigger,
                previous: appliedSelection,
                candidate: pendingSelection
            )
            guard settingsStore.currentSelection() == pendingSelection else {
                return
            }
            appliedSelection = settingsStore.selectionAfterPersisting(
                trigger: trigger,
                previous: appliedSelection,
                candidate: pendingSelection
            )
        }
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
