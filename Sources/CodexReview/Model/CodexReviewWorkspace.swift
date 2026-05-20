import Foundation
import Observation

@MainActor
@Observable
public final class CodexReviewWorkspace: Hashable {
    public nonisolated let cwd: String
    public package(set) var sortOrder: Double
    package var isExpanded: Bool

    public nonisolated var displayTitle: String {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        return title.isEmpty ? cwd : title
    }

    public init(cwd: String, sortOrder: Double = 0) {
        self.cwd = cwd
        self.sortOrder = sortOrder
        self.isExpanded = true
    }

    public nonisolated static func == (lhs: CodexReviewWorkspace, rhs: CodexReviewWorkspace) -> Bool {
        lhs.cwd == rhs.cwd
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(cwd)
    }
}
