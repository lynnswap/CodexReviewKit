import Foundation

package struct ReviewHistoryRecordError: LocalizedError, Sendable, Equatable {
    package var message: String

    package init(_ message: String) {
        self.message = message
    }

    package var errorDescription: String? {
        message
    }
}

package struct StartedReviewRecord: Sendable, Hashable {
    package var id: String
    package var cwd: String
    package var workspaceMetadata: ReviewWorkspaceMetadata?
    package var workspaceSortOrder: Double
    package var sortOrder: Double
    package var target: CodexReviewAPI.Target
    package var model: String?
    package var startedAt: Date

    package init(
        id: String,
        cwd: String,
        workspaceMetadata: ReviewWorkspaceMetadata? = nil,
        workspaceSortOrder: Double,
        sortOrder: Double,
        target: CodexReviewAPI.Target,
        model: String?,
        startedAt: Date
    ) throws {
        guard id.nilIfEmpty != nil else {
            throw ReviewHistoryRecordError("A persisted review requires a stable ID.")
        }
        guard cwd.nilIfEmpty != nil else {
            throw ReviewHistoryRecordError("A persisted review requires a workspace path.")
        }
        if let workspaceMetadata {
            guard workspaceMetadata.repositoryIdentity.nilIfEmpty != nil else {
                throw ReviewHistoryRecordError("Workspace metadata requires a repository identity.")
            }
            guard workspaceMetadata.displayTitle.nilIfEmpty != nil else {
                throw ReviewHistoryRecordError("Workspace metadata requires a display title.")
            }
        }
        guard workspaceSortOrder.isFinite, sortOrder.isFinite else {
            throw ReviewHistoryRecordError("Persisted review ordering must be finite.")
        }
        self.id = id
        self.cwd = cwd
        self.workspaceMetadata = workspaceMetadata
        self.workspaceSortOrder = workspaceSortOrder
        self.sortOrder = sortOrder
        self.target = target
        self.model = model?.nilIfEmpty
        self.startedAt = startedAt
    }
}

package struct PersistedParsedReviewResult: Sendable, Hashable {
    package struct Finding: Sendable, Hashable {
        package var ordinal: Int
        package var title: String
        package var body: String
        package var priority: Int?
        package var location: ParsedReviewResult.Finding.Location?

        package init(
            ordinal: Int,
            title: String,
            body: String,
            priority: Int?,
            location: ParsedReviewResult.Finding.Location?
        ) {
            self.ordinal = ordinal
            self.title = title
            self.body = body
            self.priority = priority
            self.location = location
        }
    }

    package var state: ParsedReviewResult.State
    package var findingCount: Int?
    package var findings: [Finding]
    package var source: ParsedReviewResult.Source
    package var parserVersion: Int

    package init(_ result: ParsedReviewResult) {
        state = result.state
        findingCount = result.findingCount
        findings = result.findings.enumerated().map { ordinal, finding in
            Finding(
                ordinal: ordinal,
                title: finding.title,
                body: finding.body,
                priority: finding.priority,
                location: finding.location
            )
        }
        source = result.source
        parserVersion = result.parserVersion
    }

    package init(
        state: ParsedReviewResult.State,
        findingCount: Int?,
        findings: [Finding],
        source: ParsedReviewResult.Source,
        parserVersion: Int
    ) throws {
        guard findings.map(\.ordinal) == Array(findings.indices) else {
            throw ReviewHistoryRecordError(
                "Persisted review findings require contiguous ordinal order."
            )
        }
        self.state = state
        self.findingCount = findingCount
        self.findings = findings
        self.source = source
        self.parserVersion = parserVersion
    }

    package func makeParsedResult() -> ParsedReviewResult {
        ParsedReviewResult(
            state: state,
            findingCount: findingCount,
            findings: findings.map { finding in
                ParsedReviewResult.Finding(
                    title: finding.title,
                    body: finding.body,
                    priority: finding.priority,
                    location: finding.location,
                    rawText: finding.rawText
                )
            },
            source: source,
            parserVersion: parserVersion
        )
    }
}

package struct TerminalReviewRecord: Sendable, Hashable {
    package var id: String
    package var model: String?
    package var terminal: ReviewTerminalRecord
    package var endedAt: Date?
    package var summary: String
    package var canonicalReview: String?
    package var parsedResult: PersistedParsedReviewResult?

    package init(
        id: String,
        model: String?,
        terminal: ReviewTerminalRecord,
        endedAt: Date?,
        summary: String,
        canonicalReview: String?,
        parsedResult: PersistedParsedReviewResult?
    ) throws {
        guard id.nilIfEmpty != nil else {
            throw ReviewHistoryRecordError("A terminal review requires a stable ID.")
        }
        let canonicalReview = canonicalReview?.nilIfEmpty
        switch terminal {
        case .completed:
            guard endedAt != nil else {
                throw ReviewHistoryRecordError("A completed review requires an end timestamp.")
            }
            guard let canonicalReview else {
                throw ReviewHistoryRecordError("A completed review requires its canonical result.")
            }
            guard canonicalReview.utf8.count <= ReviewFinalResult.maximumUTF8Bytes else {
                throw ReviewHistoryRecordError("A completed review exceeds the canonical result limit.")
            }
            guard parsedResult != nil else {
                throw ReviewHistoryRecordError("A completed review requires its parsed result projection.")
            }
        case .interrupted(.previousProcessExit):
            guard endedAt == nil, canonicalReview == nil, parsedResult == nil else {
                throw ReviewHistoryRecordError(
                    "A previous-process interruption has an unknown end and no final result."
                )
            }
        case .interrupted, .failed:
            guard endedAt != nil, canonicalReview == nil, parsedResult == nil else {
                throw ReviewHistoryRecordError(
                    "A non-completed terminal review cannot retain a canonical result."
                )
            }
        }
        self.id = id
        self.model = model?.nilIfEmpty
        self.terminal = terminal
        self.endedAt = endedAt
        self.summary = summary
        self.canonicalReview = canonicalReview
        self.parsedResult = parsedResult
    }
}

package struct RestoredReviewRecord: Sendable, Hashable {
    package var started: StartedReviewRecord
    package var terminal: TerminalReviewRecord

    package init(
        started: StartedReviewRecord,
        terminal: TerminalReviewRecord
    ) throws {
        guard started.id == terminal.id else {
            throw ReviewHistoryRecordError(
                "Restored review start and terminal identities do not match."
            )
        }
        self.started = started
        self.terminal = terminal
    }

    @MainActor
    package func makeRestoredJob() -> CodexReviewJob {
        let core = ReviewJobCore(
            run: .init(model: terminal.model ?? started.model),
            lifecycle: terminal.lifecycle(startedAt: started.startedAt),
            output: terminal.output
        )
        return CodexReviewJob(
            id: started.id,
            sessionID: "history:\(started.id)",
            cwd: started.cwd,
            sortOrder: started.sortOrder,
            targetSummary: started.target.displaySummary,
            target: started.target,
            origin: .restoredHistory,
            core: core,
            logEntries: terminal.compactLogEntries(startedAt: started.startedAt)
        )
    }
}

private extension PersistedParsedReviewResult.Finding {
    var rawText: String {
        var firstLine = title
        if let location {
            firstLine += " — \(location.path):\(location.startLine)-\(location.endLine)"
        }
        guard body.isEmpty == false else {
            return firstLine
        }
        return ([firstLine] + body.split(separator: "\n", omittingEmptySubsequences: false).map {
            "  \($0)"
        }).joined(separator: "\n")
    }
}

private extension TerminalReviewRecord {
    func lifecycle(startedAt: Date) -> ReviewJobCore.Lifecycle {
        let status: ReviewJobState
        let cancellation: ReviewCancellation?
        let errorMessage: String?
        switch terminal {
        case .completed:
            status = .succeeded
            cancellation = nil
            errorMessage = nil
        case .interrupted(.requested(let requested)):
            status = .cancelled
            cancellation = requested
            errorMessage = requested.message.nilIfEmpty
        case .interrupted(.server(let message)):
            status = .failed
            cancellation = nil
            errorMessage = message?.nilIfEmpty
        case .interrupted(.transport(let message)):
            status = .failed
            cancellation = nil
            errorMessage = message.nilIfEmpty
        case .interrupted(.previousProcessExit):
            status = .failed
            cancellation = nil
            errorMessage = "The previous review process exited before completion."
        case .failed(let message):
            status = .failed
            cancellation = nil
            errorMessage = message?.nilIfEmpty
        }
        return ReviewJobCore.Lifecycle(
            status: status,
            startedAt: startedAt,
            endedAt: endedAt,
            cancellation: cancellation,
            errorMessage: errorMessage,
            terminal: terminal
        )
    }

    var output: ReviewJobCore.Output {
        ReviewJobCore.Output(
            summary: summary,
            hasFinalReview: canonicalReview != nil,
            lastAgentMessage: canonicalReview,
            reviewResult: parsedResult?.makeParsedResult()
        )
    }

    func compactLogEntries(startedAt: Date) -> [ReviewLogEntry] {
        let timestamp = endedAt ?? startedAt
        if let canonicalReview {
            return [ReviewLogEntry(
                kind: .agentMessage,
                text: canonicalReview,
                metadata: .init(sourceType: "canonicalReviewResult"),
                timestamp: timestamp
            )]
        }
        let terminalMessage: String?
        switch terminal {
        case .completed:
            terminalMessage = nil
        case .interrupted(.requested):
            return []
        case .interrupted(.server(let message)):
            terminalMessage = message
        case .interrupted(.transport(let message)):
            terminalMessage = message
        case .interrupted(.previousProcessExit):
            terminalMessage = "The previous review process exited before completion."
        case .failed(let message):
            terminalMessage = message
        }
        let text = terminalMessage?.nilIfEmpty ?? summary.nilIfEmpty
        guard let text else {
            return []
        }
        return [ReviewLogEntry(
            kind: .error,
            text: text,
            metadata: .init(sourceType: "persistedReviewTerminal"),
            timestamp: timestamp
        )]
    }
}
