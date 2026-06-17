import Foundation

package enum CodexReviewSettings {}

package extension CodexReviewSettings {
enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh

    package var displayText: String {
        switch self {
        case .none:
            "None"
        case .minimal:
            "Minimal"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .xhigh:
            "Extra high"
        }
    }
}
}


package extension CodexReviewSettings {
enum ServiceTier: String, CaseIterable, Codable, Sendable {
    case fast
    case flex

    package var displayText: String {
        switch self {
        case .fast:
            "Fast"
        case .flex:
            "Flex"
        }
    }
}
}


package extension CodexReviewSettings {
struct ReasoningOption: Codable, Identifiable, Equatable, Sendable {
    package let reasoningEffort: CodexReviewSettings.ReasoningEffort
    package let description: String

    package var id: String {
        reasoningEffort.rawValue
    }

    package init(
        reasoningEffort: CodexReviewSettings.ReasoningEffort,
        description: String
    ) {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }
}
}


package extension CodexReviewSettings {
struct ModelCatalogItem: Codable, Identifiable, Equatable, Sendable {
    package let id: String
    package let model: String
    package let displayName: String
    package let hidden: Bool
    package let supportedReasoningEfforts: [CodexReviewSettings.ReasoningOption]
    package let defaultReasoningEffort: CodexReviewSettings.ReasoningEffort
    package let supportedServiceTiers: [CodexReviewSettings.ServiceTier]
    package let isDefault: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case model
        case displayName
        case hidden
        case supportedReasoningEfforts
        case defaultReasoningEffort
        case supportedServiceTiers = "additionalSpeedTiers"
        case serviceTiers
        case isDefault
    }

    private struct RawReasoningOption: Decodable {
        let reasoningEffort: String
        let description: String
    }

    private struct RawServiceTier: Decodable {
        let id: String
    }

    package var normalizedDisplayName: String {
        guard displayName.drop(while: \.isWhitespace).lowercased().hasPrefix("gpt") else {
            return displayName
        }
        var normalized = ""
        var currentRun = ""
        var currentRunIsWhitespace: Bool?

        func appendRun() {
            guard let currentRunIsWhitespace else {
                return
            }
            if currentRunIsWhitespace {
                normalized += currentRun
            } else {
                normalized += Self.normalizedDisplayNameComponent(currentRun)
            }
        }

        for character in displayName {
            let isWhitespace = character.isWhitespace
            if let currentRunIsWhitespace, currentRunIsWhitespace != isWhitespace {
                appendRun()
                currentRun = ""
            }
            currentRun += String(character)
            currentRunIsWhitespace = isWhitespace
        }
        appendRun()
        return normalized
    }

    package var compactDisplayName: String {
        let normalizedName = normalizedDisplayName
        let compactTokens = normalizedName
            .split { character in
                character == "-" || character.isWhitespace
            }
        guard compactTokens.first?.lowercased() == "gpt" else {
            return normalizedName
        }
        let visibleTokens = compactTokens
            .filter { token in
                !Self.compactDisplayNameOmittedTokens.contains(token.lowercased())
            }
        guard !visibleTokens.isEmpty else {
            return normalizedName
        }
        return visibleTokens.joined(separator: " ")
    }

    package init(
        id: String,
        model: String,
        displayName: String,
        hidden: Bool,
        supportedReasoningEfforts: [CodexReviewSettings.ReasoningOption],
        defaultReasoningEffort: CodexReviewSettings.ReasoningEffort,
        supportedServiceTiers: [CodexReviewSettings.ServiceTier],
        isDefault: Bool = false
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.hidden = hidden
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedServiceTiers = supportedServiceTiers
        self.isDefault = isDefault
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        model = try container.decode(String.self, forKey: .model)
        displayName = try container.decode(String.self, forKey: .displayName)
        hidden = try container.decode(Bool.self, forKey: .hidden)
        let rawReasoningEfforts = try container.decode(
            [RawReasoningOption].self,
            forKey: .supportedReasoningEfforts
        )
        supportedReasoningEfforts = rawReasoningEfforts.compactMap { item in
            guard let reasoningEffort = CodexReviewSettings.ReasoningEffort(rawValue: item.reasoningEffort) else {
                return nil
            }
            return .init(reasoningEffort: reasoningEffort, description: item.description)
        }
        let decodedDefaultReasoningEffort = try container.decodeIfPresent(
            String.self,
            forKey: .defaultReasoningEffort
        ).flatMap(CodexReviewSettings.ReasoningEffort.init(rawValue:))
        defaultReasoningEffort = decodedDefaultReasoningEffort
            ?? supportedReasoningEfforts.first?.reasoningEffort
            ?? .medium
        let additionalSpeedTiers = try container.decodeIfPresent(
            [String].self,
            forKey: .supportedServiceTiers
        ) ?? []
        let serviceTierIDs = try container.decodeIfPresent(
            [RawServiceTier].self,
            forKey: .serviceTiers
        )?.map(\.id) ?? []
        supportedServiceTiers = Array(Set(additionalSpeedTiers + serviceTierIDs))
            .sorted()
            .compactMap(CodexReviewSettings.ServiceTier.init(rawValue:))
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(model, forKey: .model)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
        try container.encode(defaultReasoningEffort, forKey: .defaultReasoningEffort)
        try container.encode(
            supportedServiceTiers.map(\.rawValue),
            forKey: .supportedServiceTiers
        )
        try container.encode(isDefault, forKey: .isDefault)
    }

    private static let compactDisplayNameOmittedTokens: Set<String> = [
        "codex",
        "gpt",
    ]

    private static func normalizedDisplayNameComponent(_ component: String) -> String {
        component
            .split(separator: "-", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, token in
                guard !token.isEmpty else {
                    return ""
                }
                switch token.lowercased() {
                case "gpt":
                    return "GPT"
                case "oai":
                    return "OAI"
                default:
                    guard index > 0 else {
                        return String(token)
                    }
                    return token.prefix(1).uppercased() + token.dropFirst()
                }
            }
            .joined(separator: "-")
    }
}
}


package extension CodexReviewSettings {
struct Snapshot: Equatable, Sendable {
    package var model: String?
    package var fallbackModel: String?
    package var reasoningEffort: CodexReviewSettings.ReasoningEffort?
    package var serviceTier: CodexReviewSettings.ServiceTier?
    package var models: [CodexReviewSettings.ModelCatalogItem]

    package init(
        model: String? = nil,
        fallbackModel: String? = nil,
        reasoningEffort: CodexReviewSettings.ReasoningEffort? = nil,
        serviceTier: CodexReviewSettings.ServiceTier? = nil,
        models: [CodexReviewSettings.ModelCatalogItem] = []
    ) {
        self.model = model
        self.fallbackModel = fallbackModel
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.models = models
    }
}
}
