import Foundation

public enum CodexReviewStoreTestEnvironment {
    public static let reviewModeKey = "REVIEW_MONITOR_REVIEW_MODE"
    public static let mockJobsKey = "REVIEW_MONITOR_MOCK_JOBS"
    public static let portKey = "REVIEW_MONITOR_TEST_PORT"
    public static let codexCommandKey = "REVIEW_MONITOR_TEST_CODEX_COMMAND"
    public static let diagnosticsPathKey = "REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH"
    public static let historyPathKey = "REVIEW_MONITOR_TEST_HISTORY_PATH"
    public static let reviewModeArgument = "--review-monitor-review-mode"
    public static let mockJobsArgument = "--review-monitor-mock-jobs"
    public static let portArgument = "--review-monitor-test-port"
    public static let codexCommandArgument = "--review-monitor-test-codex-command"
    public static let diagnosticsPathArgument = "--review-monitor-test-diagnostics-path"
    public static let historyPathArgument = "--review-monitor-test-history-path"
}

struct CodexReviewStoreDiagnosticsSnapshot: Encodable {
    struct Job: Encodable {
        struct Terminal: Encodable {
            var kind: String
            var cause: String?
            var message: String?

            init(_ terminal: ReviewTerminalRecord) {
                kind = terminal.kind.rawValue
                switch terminal {
                case .completed:
                    cause = nil
                    message = nil
                case .failed(let failureMessage):
                    cause = nil
                    message = failureMessage
                case .interrupted(let interruption):
                    switch interruption {
                    case .requested(let cancellation):
                        cause = "requested.\(cancellation.source.rawValue)"
                        message = cancellation.message
                    case .server(let interruptionMessage):
                        cause = "server"
                        message = interruptionMessage
                    case .transport(let interruptionMessage):
                        cause = "transport"
                        message = interruptionMessage
                    case .previousProcessExit:
                        cause = "previousProcessExit"
                        message = nil
                    }
                }
            }
        }

        struct ParsedResult: Encodable {
            struct Finding: Encodable {
                var title: String
                var body: String
                var priority: Int?
                var location: ParsedReviewResult.Finding.Location?
            }

            var state: String
            var findingCount: Int?
            var findings: [Finding]
            var source: String
            var parserVersion: Int

            init(_ result: ParsedReviewResult) {
                state = result.state.rawValue
                findingCount = result.findingCount
                findings = result.findings.map {
                    Finding(
                        title: $0.title,
                        body: $0.body,
                        priority: $0.priority,
                        location: $0.location
                    )
                }
                source = result.source.rawValue
                parserVersion = result.parserVersion
            }
        }

        var id: String
        var cwd: String
        var origin: String
        var target: CodexReviewAPI.Target
        var targetSummary: String
        var model: String?
        var status: String
        var terminal: Terminal?
        var startedAt: Date?
        var endedAt: Date?
        var summary: String
        var canonicalReview: String?
        var parsedResult: ParsedResult?
    }

    var serverState: String
    var failureMessage: String?
    var serverURL: String?
    var childRuntimePath: String?
    var historyAvailability: String
    var historyFailureMessage: String?
    var jobs: [Job]
}
