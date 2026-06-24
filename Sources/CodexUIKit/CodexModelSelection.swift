import CodexAppServerKit
import Foundation

/// Describes why an option is present in a UI-facing selection list.
public enum CodexSelectionOptionSource: Equatable, Sendable {
    case catalog
    case currentSelection
}

/// A selectable Codex model derived from a model catalog or current selection.
public struct CodexModelOption: Identifiable, Equatable, Sendable {
    public var id: String { modelID }

    public var catalogID: String?
    public var modelID: String
    public var displayName: String
    public var isHidden: Bool
    public var source: CodexSelectionOptionSource

    public init(
        modelID: String,
        displayName: String? = nil,
        isHidden: Bool = false,
        source: CodexSelectionOptionSource = .catalog,
        catalogID: String? = nil
    ) {
        self.catalogID = catalogID
        self.modelID = modelID
        self.displayName = displayName ?? modelID
        self.isHidden = isHidden
        self.source = source
    }

    public init(catalogModel: CodexModel) {
        self.init(
            modelID: catalogModel.model,
            displayName: catalogModel.displayName,
            isHidden: catalogModel.hidden,
            source: .catalog,
            catalogID: catalogModel.id
        )
    }
}

/// A selectable reasoning effort with display metadata suitable for UI controls.
public struct CodexReasoningEffortOption: Identifiable, Equatable, Sendable {
    public var id: String { reasoningEffort.rawValue }

    public var reasoningEffort: CodexReasoningEffort
    public var localizedLabel: LocalizedStringResource
    public var description: String?
    public var source: CodexSelectionOptionSource

    public init(
        reasoningEffort: CodexReasoningEffort,
        description: String? = nil,
        source: CodexSelectionOptionSource = .catalog
    ) {
        self.reasoningEffort = reasoningEffort
        self.localizedLabel = reasoningEffort.localizedLabel
        self.description = description
        self.source = source
    }

    public init(catalogOption: CodexModel.ReasoningOption) {
        self.init(
            reasoningEffort: catalogOption.reasoningEffort,
            description: catalogOption.description,
            source: .catalog
        )
    }
}

/// A selectable service tier. Unknown tier identifiers are preserved as raw strings.
public struct CodexServiceTierOption: Identifiable, Equatable, Sendable {
    public var id: String { serviceTierID }

    public var serviceTierID: String
    public var localizedLabel: LocalizedStringResource
    public var source: CodexSelectionOptionSource

    public init(
        serviceTierID: String,
        source: CodexSelectionOptionSource = .catalog
    ) {
        self.serviceTierID = serviceTierID
        self.localizedLabel = Self.localizedLabel(for: serviceTierID)
        self.source = source
    }

    public static func localizedLabel(for serviceTierID: String) -> LocalizedStringResource {
        switch serviceTierID {
        case "fast":
            "Fast"
        case "flex":
            "Flex"
        default:
            LocalizedStringResource(stringLiteral: serviceTierID)
        }
    }
}

/// Builds UI-facing model, reasoning, and service tier options from a Codex model catalog.
public struct CodexModelSelection: Equatable, Sendable {
    public var models: [CodexModel]
    /// The selected Codex model string, matched against `CodexModel.model`.
    public var selectedModelID: String?
    /// The fallback Codex model string, matched against `CodexModel.model`.
    public var fallbackModelID: String?
    public var selectedReasoningEffort: CodexReasoningEffort?
    public var selectedServiceTierID: String?

    public init(
        models: [CodexModel],
        selectedModelID: String? = nil,
        fallbackModelID: String? = nil,
        selectedReasoningEffort: CodexReasoningEffort? = nil,
        selectedServiceTierID: String? = nil
    ) {
        self.models = models
        self.selectedModelID = selectedModelID
        self.fallbackModelID = fallbackModelID
        self.selectedReasoningEffort = selectedReasoningEffort
        self.selectedServiceTierID = selectedServiceTierID
    }

    public var effectiveModelID: String? {
        selectedModelID ?? fallbackModelID
    }

    public var effectiveModel: CodexModel? {
        guard let effectiveModelID else {
            return nil
        }
        return models.first { $0.model == effectiveModelID }
    }

    public var modelOptions: [CodexModelOption] {
        var options = models.compactMap { model -> CodexModelOption? in
            guard model.hidden == false || model.model == effectiveModelID else {
                return nil
            }
            return .init(catalogModel: model)
        }

        if let effectiveModelID,
           options.contains(where: { $0.modelID == effectiveModelID }) == false
        {
            options.append(
                .init(
                    modelID: effectiveModelID,
                    source: .currentSelection
                )
            )
        }

        return options
    }

    public var reasoningEffortOptions: [CodexReasoningEffortOption] {
        var options = effectiveModel?.supportedReasoningEfforts.map {
            CodexReasoningEffortOption(catalogOption: $0)
        } ?? []

        if let selectedReasoningEffort,
           options.contains(where: { $0.reasoningEffort == selectedReasoningEffort }) == false
        {
            options.append(
                .init(
                    reasoningEffort: selectedReasoningEffort,
                    source: .currentSelection
                )
            )
        }

        return options
    }

    public var effectiveReasoningEffort: CodexReasoningEffort? {
        selectedReasoningEffort ?? effectiveModel?.defaultReasoningEffort
    }

    public var serviceTierOptions: [CodexServiceTierOption] {
        let catalogServiceTierIDs = Set(effectiveModel?.supportedServiceTiers ?? [])
        var serviceTierIDs = effectiveModel?.supportedServiceTiers ?? []
        if let selectedServiceTierID {
            serviceTierIDs.append(selectedServiceTierID)
        }

        return serviceTierIDs
            .uniqueSorted()
            .map { serviceTierID in
                CodexServiceTierOption(
                    serviceTierID: serviceTierID,
                    source: catalogServiceTierIDs.contains(serviceTierID)
                        ? .catalog
                        : .currentSelection
                )
            }
    }
}

public extension CodexReasoningEffort {
    var localizedLabel: LocalizedStringResource {
        switch rawValue {
        case Self.none.rawValue:
            "None"
        case Self.minimal.rawValue:
            "Minimal"
        case Self.low.rawValue:
            "Low"
        case Self.medium.rawValue:
            "Medium"
        case Self.high.rawValue:
            "High"
        case Self.xhigh.rawValue:
            "Extra high"
        default:
            LocalizedStringResource(stringLiteral: rawValue)
        }
    }
}

private extension Array where Element == String {
    func uniqueSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
