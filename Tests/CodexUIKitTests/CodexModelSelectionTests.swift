import CodexAppServerKit
import CodexUIKit
import Foundation
import Testing

@Suite("CodexUIKit model selection")
struct CodexModelSelectionTests {
    @Test func hiddenSelectedModelIsPreservedInOptions() throws {
        let visible = makeModel(
            model: "gpt-visible",
            displayName: "GPT Visible"
        )
        let hidden = makeModel(
            model: "gpt-hidden",
            displayName: "GPT Hidden",
            hidden: true
        )

        let selection = CodexModelSelection(
            models: [visible, hidden],
            selectedModelID: "gpt-hidden"
        )

        #expect(selection.modelOptions.map(\.modelID) == ["gpt-visible", "gpt-hidden"])
        let hiddenOption = try #require(selection.modelOptions.last)
        #expect(hiddenOption.displayName == "GPT Hidden")
        #expect(hiddenOption.isHidden)
        #expect(hiddenOption.source == .catalog)
    }

    @Test func missingSelectedModelIsRepresentedInOptions() throws {
        let visible = makeModel(
            model: "gpt-visible",
            displayName: "GPT Visible"
        )

        let selection = CodexModelSelection(
            models: [visible],
            selectedModelID: "gpt-missing"
        )

        #expect(selection.modelOptions.map(\.modelID) == ["gpt-visible", "gpt-missing"])
        #expect(selection.effectiveModel == nil)

        let missingOption = try #require(selection.modelOptions.last)
        #expect(missingOption.displayName == "gpt-missing")
        #expect(missingOption.isHidden == false)
        #expect(missingOption.source == .currentSelection)
    }

    @Test func reasoningLabelsUseLocalizedStringResourcesAndPreserveUnknownValues() throws {
        let experimentalEffort = CodexReasoningEffort(rawValue: "experimental")
        let selectedEffort = CodexReasoningEffort(rawValue: "bespoke")
        let model = makeModel(
            model: "gpt-reasoning",
            reasoningOptions: [
                .init(reasoningEffort: .medium, description: "Balanced"),
                .init(reasoningEffort: experimentalEffort, description: "Experimental"),
            ],
            defaultReasoningEffort: .medium,
            serviceTiers: ["priority"]
        )

        let selection = CodexModelSelection(
            models: [model],
            selectedModelID: "gpt-reasoning",
            selectedReasoningEffort: selectedEffort,
            selectedServiceTierID: "priority"
        )

        let options = selection.reasoningEffortOptions
        #expect(options.map(\.reasoningEffort) == [.medium, experimentalEffort, selectedEffort])
        #expect(options.map(\.source) == [.catalog, .catalog, .currentSelection])
        #expect(options.first?.localizedLabel == LocalizedStringResource("Medium"))

        let experimentalOption = try #require(options.first { $0.reasoningEffort == experimentalEffort })
        #expect(String(localized: experimentalOption.localizedLabel) == "experimental")
        #expect(selection.selectedServiceTierID == "priority")
        #expect(selection.serviceTierOptions.map(\.serviceTierID) == ["priority"])
    }

    @Test func serviceTierIDsRemainRawStringsAndAreSorted() throws {
        let model = makeModel(
            model: "gpt-tiers",
            serviceTiers: ["priority", "flex", "fast", "batch", "fast"]
        )

        let selection = CodexModelSelection(
            models: [model],
            selectedModelID: "gpt-tiers",
            selectedServiceTierID: "zippy"
        )

        let options = selection.serviceTierOptions
        #expect(options.map(\.serviceTierID) == ["batch", "fast", "flex", "priority", "zippy"])
        #expect(options.map(\.id) == ["batch", "fast", "flex", "priority", "zippy"])
        #expect(options.first { $0.serviceTierID == "fast" }?.localizedLabel == LocalizedStringResource("Fast"))
        #expect(options.first { $0.serviceTierID == "flex" }?.localizedLabel == LocalizedStringResource("Flex"))

        let rawOption = try #require(options.first { $0.serviceTierID == "priority" })
        #expect(String(localized: rawOption.localizedLabel) == "priority")

        let selectedOnlyOption = try #require(options.first { $0.serviceTierID == "zippy" })
        #expect(selectedOnlyOption.source == .currentSelection)
    }
}

private func makeModel(
    model: String,
    displayName: String? = nil,
    hidden: Bool = false,
    reasoningOptions: [CodexModel.ReasoningOption] = [],
    defaultReasoningEffort: CodexReasoningEffort? = nil,
    serviceTiers: [String] = []
) -> CodexModel {
    CodexModel(
        id: model,
        model: model,
        displayName: displayName ?? model,
        hidden: hidden,
        supportedReasoningEfforts: reasoningOptions,
        defaultReasoningEffort: defaultReasoningEffort,
        supportedServiceTiers: serviceTiers
    )
}
