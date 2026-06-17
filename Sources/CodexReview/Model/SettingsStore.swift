import Foundation
import Observation

@MainActor
@Observable
package final class SettingsStore {
    package struct Selection: Equatable {
        let model: String?
        let reasoningEffort: CodexReviewSettings.ReasoningEffort?
        let serviceTier: CodexReviewSettings.ServiceTier?
    }

    package enum SelectionTrigger {
        case model
        case reasoningEffort
        case serviceTier
    }

    package private(set) var selectedModel: String?
    package private(set) var selectedReasoningEffort: CodexReviewSettings.ReasoningEffort?
    package private(set) var selectedServiceTier: CodexReviewSettings.ServiceTier?
    package private(set) var fallbackModel: String?
    package private(set) var models: [CodexReviewSettings.ModelCatalogItem]
    package private(set) var isLoading = false
    package private(set) var lastErrorMessage: String?

    package init(snapshot: CodexReviewSettings.Snapshot) {
        selectedModel = snapshot.model
        fallbackModel = snapshot.fallbackModel
        selectedReasoningEffort = snapshot.reasoningEffort
        selectedServiceTier = snapshot.serviceTier
        models = snapshot.models
        applyNormalizedSelection(
            normalizeSelection(
                model: snapshot.model,
                reasoningEffort: snapshot.reasoningEffort,
                serviceTier: snapshot.serviceTier,
                catalog: snapshot.models,
                clearIncompatibleOverrides: false
            ),
            catalog: snapshot.models
        )
    }

    package var displayedModels: [CodexReviewSettings.ModelCatalogItem] {
        var displayedModels = models.filter { modelItem in
            modelItem.hidden == false || modelItem.model == effectiveModel
        }
        if let effectiveModel,
           displayedModels.contains(where: { $0.model == effectiveModel }) == false
        {
            displayedModels.append(
                .init(
                    id: effectiveModel,
                    model: effectiveModel,
                    displayName: effectiveModel,
                    hidden: false,
                    supportedReasoningEfforts: [],
                    defaultReasoningEffort: .medium,
                    supportedServiceTiers: []
                )
            )
        }
        return displayedModels
    }

    package var effectiveModel: String? {
        selectedModel ?? fallbackModel
    }

    package var effectiveModelItem: CodexReviewSettings.ModelCatalogItem? {
        models.first(where: { $0.model == effectiveModel })
    }

    package var availableReasoningOptions: [CodexReviewSettings.ReasoningOption] {
        effectiveModelItem?.supportedReasoningEfforts ?? []
    }

    package var availableServiceTiers: [CodexReviewSettings.ServiceTier] {
        effectiveModelItem?.supportedServiceTiers ?? []
    }

    package var effectiveReasoningEffort: CodexReviewSettings.ReasoningEffort? {
        selectedReasoningEffort ?? effectiveModelItem?.defaultReasoningEffort
    }

    package func loadForTesting(snapshot: CodexReviewSettings.Snapshot) {
        apply(snapshot: snapshot)
        lastErrorMessage = nil
        isLoading = false
    }

    package func beginLoading() {
        isLoading = true
    }

    package func finishLoading(errorMessage: String?) {
        lastErrorMessage = errorMessage
        isLoading = false
    }

    package func apply(snapshot: CodexReviewSettings.Snapshot) {
        fallbackModel = snapshot.fallbackModel
        models = snapshot.models
        applyNormalizedSelection(
            normalizeSelection(
                model: snapshot.model,
                reasoningEffort: snapshot.reasoningEffort,
                serviceTier: snapshot.serviceTier,
                catalog: snapshot.models,
                clearIncompatibleOverrides: false
            ),
            catalog: snapshot.models
        )
    }

    package func currentSelection() -> Selection {
        .init(
            model: selectedModel,
            reasoningEffort: selectedReasoningEffort,
            serviceTier: selectedServiceTier
        )
    }

    package func snapshot() -> CodexReviewSettings.Snapshot {
        snapshot(selection: currentSelection())
    }

    package func snapshot(selection: Selection) -> CodexReviewSettings.Snapshot {
        .init(
            model: selection.model,
            fallbackModel: fallbackModel,
            reasoningEffort: selection.reasoningEffort,
            serviceTier: selection.serviceTier,
            models: models
        )
    }

    package func normalizeSelection(
        model: String?,
        reasoningEffort: CodexReviewSettings.ReasoningEffort?,
        serviceTier: CodexReviewSettings.ServiceTier?,
        catalog: [CodexReviewSettings.ModelCatalogItem],
        clearIncompatibleOverrides: Bool
    ) -> Selection {
        let effectiveModel = model ?? fallbackModel
        guard let effectiveModel,
              let selectedModel = catalog.first(where: { $0.model == effectiveModel })
        else {
            return .init(
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier
            )
        }

        let supportedReasoningEfforts = selectedModel.supportedReasoningEfforts.map(\.reasoningEffort)
        let resolvedReasoningEffort: CodexReviewSettings.ReasoningEffort? = if supportedReasoningEfforts.isEmpty {
            clearIncompatibleOverrides ? nil : reasoningEffort
        } else if let reasoningEffort, supportedReasoningEfforts.contains(reasoningEffort) {
            reasoningEffort
        } else if clearIncompatibleOverrides {
            nil
        } else {
            reasoningEffort
        }

        let resolvedServiceTier: CodexReviewSettings.ServiceTier? = if let serviceTier,
            selectedModel.supportedServiceTiers.contains(serviceTier)
        {
            serviceTier
        } else if clearIncompatibleOverrides {
            nil
        } else {
            serviceTier
        }

        return .init(
            model: model,
            reasoningEffort: resolvedReasoningEffort,
            serviceTier: resolvedServiceTier
        )
    }

    package func applyNormalizedSelection(
        _ selection: Selection,
        catalog: [CodexReviewSettings.ModelCatalogItem]
    ) {
        models = catalog
        selectedModel = selection.model
        selectedReasoningEffort = selection.reasoningEffort
        selectedServiceTier = selection.serviceTier
    }

    package func selectionTriggers(
        previous: Selection,
        candidate: Selection
    ) -> [SelectionTrigger] {
        if previous.model != candidate.model {
            return [.model]
        }
        var triggers: [SelectionTrigger] = []
        if previous.reasoningEffort != candidate.reasoningEffort {
            triggers.append(.reasoningEffort)
        }
        if previous.serviceTier != candidate.serviceTier {
            triggers.append(.serviceTier)
        }
        return triggers
    }

    package func selectionAfterPersisting(
        trigger: SelectionTrigger,
        previous: Selection,
        candidate: Selection
    ) -> Selection {
        switch trigger {
        case .model:
            return candidate
        case .reasoningEffort:
            return .init(
                model: previous.model,
                reasoningEffort: candidate.reasoningEffort,
                serviceTier: previous.serviceTier
            )
        case .serviceTier:
            return .init(
                model: previous.model,
                reasoningEffort: previous.reasoningEffort,
                serviceTier: candidate.serviceTier
            )
        }
    }
}
