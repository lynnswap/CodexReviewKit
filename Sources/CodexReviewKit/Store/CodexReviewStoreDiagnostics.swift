import Foundation

public enum CodexReviewStoreTestEnvironment {
    public static let reviewModeKey = "REVIEW_MONITOR_REVIEW_MODE"
    public static let mockJobsKey = "REVIEW_MONITOR_MOCK_JOBS"
    public static let portKey = "REVIEW_MONITOR_TEST_PORT"
    public static let codexCommandKey = "REVIEW_MONITOR_TEST_CODEX_COMMAND"
    public static let diagnosticsPathKey = "REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH"
    public static let reviewModeArgument = "--review-monitor-review-mode"
    public static let mockJobsArgument = "--review-monitor-mock-jobs"
    public static let portArgument = "--review-monitor-test-port"
    public static let codexCommandArgument = "--review-monitor-test-codex-command"
    public static let diagnosticsPathArgument = "--review-monitor-test-diagnostics-path"
}

struct CodexReviewStoreDiagnosticsSnapshot: Encodable {
    struct Job: Encodable {
        var status: String
        var summary: String
        var logText: String
        var rawLogText: String
    }

    var serverState: String
    var failureMessage: String?
    var serverURL: String?
    var childRuntimePath: String?
    var jobs: [Job]
}
