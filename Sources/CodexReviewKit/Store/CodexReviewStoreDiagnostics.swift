import Foundation

struct CodexReviewStoreDiagnosticsSnapshot: Encodable {
    struct Run: Encodable {
        var status: String
        var lifecycleMessage: String
    }

    var serverState: String
    var failureMessage: String?
    var serverURL: String?
    var childRuntimePath: String?
    var reviewRuns: [Run]
}
