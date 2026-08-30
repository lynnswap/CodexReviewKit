import Foundation
import Testing
@_spi(Testing) @testable import CodexReview

@Suite("Codex review settings")
struct CodexReviewSettingsTests {
    @Test func reasoningEffortPreservesKnownAndModelDefinedWireValues() throws {
        let modelDefined = try #require(CodexReviewSettings.ReasoningEffort(rawValue: "future-effort"))
        let cases: [(CodexReviewSettings.ReasoningEffort, String, String)] = [
            (.none, "none", "None"),
            (.minimal, "minimal", "Minimal"),
            (.low, "low", "Light"),
            (.medium, "medium", "Medium"),
            (.high, "high", "High"),
            (.xhigh, "xhigh", "Extra High"),
            (.max, "max", "Max"),
            (.ultra, "ultra", "Ultra"),
            (.persistent, "persistent", "Persistent"),
            (modelDefined, "future-effort", "future-effort"),
        ]

        for (effort, rawValue, displayText) in cases {
            let encoded = try JSONEncoder().encode(effort)
            let expectedEncoding = try JSONEncoder().encode(rawValue)

            #expect(effort.rawValue == rawValue)
            #expect(effort.displayText == displayText)
            #expect(encoded == expectedEncoding)
            #expect(try JSONDecoder().decode(CodexReviewSettings.ReasoningEffort.self, from: encoded) == effort)
        }
    }

    @Test func reasoningEffortRejectsEmptyWireValues() throws {
        #expect(CodexReviewSettings.ReasoningEffort(rawValue: "") == nil)

        let encodedEmptyValue = try JSONEncoder().encode("")
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                CodexReviewSettings.ReasoningEffort.self,
                from: encodedEmptyValue
            )
        }
    }

    @Test func highestReasoningEffortsConsumeUsageLimitsFaster() {
        #expect(CodexReviewSettings.ReasoningEffort.max.consumesUsageLimitsFaster)
        #expect(CodexReviewSettings.ReasoningEffort.ultra.consumesUsageLimitsFaster)
        #expect(CodexReviewSettings.ReasoningEffort.xhigh.consumesUsageLimitsFaster == false)
    }

    @Test func modelCatalogUsesFirstAdvertisedEffortWhenDefaultIsMissing() throws {
        let data = Data("""
        {
          "id": "runtime-model",
          "model": "runtime-model",
          "displayName": "Runtime Model",
          "hidden": false,
          "supportedReasoningEfforts": [
            {"reasoningEffort": "future-effort", "description": "Model-defined"},
            {"reasoningEffort": "medium", "description": "Balanced"}
          ]
        }
        """.utf8)

        let model = try JSONDecoder().decode(CodexReviewSettings.ModelCatalogItem.self, from: data)

        #expect(model.defaultReasoningEffort.rawValue == "future-effort")
    }
}
