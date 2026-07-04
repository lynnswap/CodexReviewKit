import Foundation

public enum CodexReviewStoreTestEnvironment {
    public static let reviewModeKey = "REVIEW_MONITOR_REVIEW_MODE"
    public static let portKey = "REVIEW_MONITOR_TEST_PORT"
    public static let codexCommandKey = "REVIEW_MONITOR_TEST_CODEX_COMMAND"
    public static let diagnosticsPathKey = "REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH"
    public static let reviewModeArgument = "--review-monitor-review-mode"
    public static let portArgument = "--review-monitor-test-port"
    public static let codexCommandArgument = "--review-monitor-test-codex-command"
    public static let diagnosticsPathArgument = "--review-monitor-test-diagnostics-path"
}

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
