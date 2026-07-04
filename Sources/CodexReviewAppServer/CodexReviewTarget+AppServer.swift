import CodexAppServerKit
import CodexReviewKit
import Foundation

extension CodexReviewAPI.Target {
    package var appServerReviewTarget: CodexReviewTarget {
        switch self {
        case .uncommittedChanges:
            .uncommittedChanges
        case .baseBranch(let branch):
            .baseBranch(branch)
        case .commit(let sha, let title):
            .commit(sha: sha, title: title)
        case .custom(let instructions):
            .custom(instructions: instructions)
        }
    }
}
