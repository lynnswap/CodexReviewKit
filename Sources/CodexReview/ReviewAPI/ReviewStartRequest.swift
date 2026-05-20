import Foundation

package struct ReviewStartRequest: Codable, Hashable, Sendable {
    package var cwd: String
    package var target: ReviewTarget

    package init(cwd: String, target: ReviewTarget) {
        self.cwd = cwd
        self.target = target
    }

    package func validated() throws -> Self {
        let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCWD.isEmpty == false else {
            throw ReviewError.invalidArguments("`cwd` is required.")
        }
        var copy = self
        copy.cwd = trimmedCWD
        copy.target = try target.validated()
        return copy
    }

}
