import CodexReview
import Foundation

package struct AppServerReviewTurnInvocation: Equatable, Sendable {
    package let prompt: String

    package init(
        codexHome: String?,
        target: CodexReviewAPI.Target
    ) throws {
        guard let codexHome,
              codexHome.hasPrefix("/")
        else {
            throw ReviewAttemptContractFailure(
                message: "Review execution requires an absolute Codex home from initialize."
            )
        }
        guard codexHome == codexHome.trimmingCharacters(in: .whitespacesAndNewlines),
              codexHome.rangeOfCharacter(from: .newlines) == nil,
              codexHome.contains(")") == false
        else {
            throw ReviewAttemptContractFailure(
                message: "Review execution cannot reference a Codex home with boundary whitespace, a line break, or `)`."
            )
        }
        // The app-server provisions built-in skills before returning initialize.
        // Build from its reported home so CodexReviewKit does not own a second skill copy.
        let skillPath = URL(fileURLWithPath: codexHome, isDirectory: true)
            .appending(path: "skills", directoryHint: .isDirectory)
            .appending(path: ".system", directoryHint: .isDirectory)
            .appending(path: "review-agent", directoryHint: .isDirectory)
            .appending(path: "SKILL.md", directoryHint: .notDirectory)
            .path
        prompt = "Use [$review-agent](\(skillPath)) for this review.\n\n\(Self.instruction(for: target))"
    }

    private static func instruction(for target: CodexReviewAPI.Target) -> String {
        switch target {
        case .uncommittedChanges:
            "Review the current code changes (staged, unstaged, and untracked files)."
        case .baseBranch(let branch):
            "Review the code changes against the base branch \(String(reflecting: branch))."
        case .commit(let sha, _):
            "Review the changes introduced by commit \(String(reflecting: sha))."
        case .custom(let instructions):
            instructions
        }
    }

}
