import Foundation

package extension CodexReviewAPI {
    enum Error: Swift.Error, LocalizedError, Sendable {
        case invalidArguments(String)
        case runNotFound(String)
        case accessDenied(String)
        case spawnFailed(String)
        case bootstrapFailed(String)
        case io(String)

        package var errorDescription: String? {
            switch self {
            case .invalidArguments(let message),
                 .runNotFound(let message),
                 .accessDenied(let message),
                 .spawnFailed(let message),
                 .bootstrapFailed(let message),
                 .io(let message):
                message
            }
        }
    }
}
