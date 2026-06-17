import Foundation

package extension CodexReviewAPI.Start {
    struct Request: Codable, Hashable, Sendable {
        package var cwd: String
        package var target: CodexReviewAPI.Target

        package init(cwd: String, target: CodexReviewAPI.Target) {
            self.cwd = cwd
            self.target = target
        }

        package func validated() throws -> Self {
            let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedCWD.isEmpty == false else {
                throw CodexReviewAPI.Error.invalidArguments("`cwd` is required.")
            }
            var copy = self
            copy.cwd = trimmedCWD
            copy.target = try target.validated()
            return copy
        }
    }
}
