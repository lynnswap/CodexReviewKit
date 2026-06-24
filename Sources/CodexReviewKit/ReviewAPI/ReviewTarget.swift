import Foundation

package extension CodexReviewAPI {
    enum Target: Hashable, Sendable {
        case uncommittedChanges
        case baseBranch(String)
        case commit(sha: String, title: String?)
        case custom(instructions: String)

        package func validated() throws -> Self {
            switch self {
            case .uncommittedChanges:
                return self
            case .baseBranch(let branch):
                guard branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    throw CodexReviewAPI.Error.invalidArguments("`target.branch` is required.")
                }
                return .baseBranch(branch.trimmingCharacters(in: .whitespacesAndNewlines))
            case .commit(let sha, let title):
                let trimmedSHA = sha.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedSHA.isEmpty == false else {
                    throw CodexReviewAPI.Error.invalidArguments("`target.sha` is required.")
                }
                return .commit(sha: trimmedSHA, title: title?.nilIfEmpty)
            case .custom(let instructions):
                let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedInstructions.isEmpty == false else {
                    throw CodexReviewAPI.Error.invalidArguments("`target.instructions` is required.")
                }
                return .custom(instructions: trimmedInstructions)
            }
        }

        package var displaySummary: String {
            switch self {
            case .uncommittedChanges:
                "Uncommitted changes"
            case .baseBranch(let branch):
                "Base branch: \(branch)"
            case .commit(let sha, let title):
                title?.nilIfEmpty.map { "Commit: \(sha) - \($0)" } ?? "Commit: \(sha)"
            case .custom(let instructions):
                "Custom: \(instructions)"
            }
        }
    }
}

extension CodexReviewAPI.Target: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case branch
        case sha
        case title
        case instructions
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "uncommittedChanges":
            self = .uncommittedChanges
        case "baseBranch":
            self = .baseBranch(try container.decode(String.self, forKey: .branch))
        case "commit":
            self = .commit(
                sha: try container.decode(String.self, forKey: .sha),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )
        case "custom":
            self = .custom(instructions: try container.decode(String.self, forKey: .instructions))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown review target type: \(type)"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .uncommittedChanges:
            try container.encode("uncommittedChanges", forKey: .type)
        case .baseBranch(let branch):
            try container.encode("baseBranch", forKey: .type)
            try container.encode(branch, forKey: .branch)
        case .commit(let sha, let title):
            try container.encode("commit", forKey: .type)
            try container.encode(sha, forKey: .sha)
            try container.encodeIfPresent(title, forKey: .title)
        case .custom(let instructions):
            try container.encode("custom", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
        }
    }
}
