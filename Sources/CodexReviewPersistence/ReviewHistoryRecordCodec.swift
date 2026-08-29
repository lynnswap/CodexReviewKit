import CodexReview
import Foundation

struct EncodedStartedReview {
    var workspace: ReviewWorkspaceRow
    var review: ReviewRecordRow
}

struct EncodedTerminalReview {
    var review: ReviewRecordRow
    var findings: [ReviewFindingRow]
}

enum DecodedReviewHistoryRow {
    case active(StartedReviewRecord)
    case terminal(RestoredReviewRecord)
}

enum ReviewHistoryRecordCodec {
    static func encodeStarted(
        _ record: StartedReviewRecord,
        createdAt: Date,
        updatedAt: Date
    ) throws -> EncodedStartedReview {
        let target = try validatedTarget(record.target, id: record.id)
        let targetColumns = targetColumns(target)
        return EncodedStartedReview(
            workspace: ReviewWorkspaceRow(
                cwd: record.cwd,
                sortOrder: record.workspaceSortOrder
            ),
            review: ReviewRecordRow(
                id: record.id,
                cwd: record.cwd,
                sortOrder: record.sortOrder,
                targetKind: targetColumns.kind,
                targetBranch: targetColumns.branch,
                targetCommitSHA: targetColumns.commitSHA,
                targetCommitTitle: targetColumns.commitTitle,
                targetInstructions: targetColumns.instructions,
                startedModel: record.model,
                startedAt: ReviewHistoryTimestamp.encode(record.startedAt),
                phase: "active",
                terminalModel: nil,
                terminalKind: nil,
                interruptionKind: nil,
                cancellationSource: nil,
                cancellationMessage: nil,
                terminalMessage: nil,
                endedAt: nil,
                summary: nil,
                canonicalReview: nil,
                parsedState: nil,
                parsedFindingCount: nil,
                parsedSource: nil,
                parserVersion: nil,
                terminalCommittedAt: nil,
                createdAt: ReviewHistoryTimestamp.encode(createdAt),
                updatedAt: ReviewHistoryTimestamp.encode(updatedAt)
            )
        )
    }

    static func encodeTerminal(
        _ record: TerminalReviewRecord,
        replacing existing: ReviewRecordRow,
        terminalCommittedAt: Date,
        updatedAt: Date
    ) throws -> EncodedTerminalReview {
        guard record.id == existing.id else {
            throw invalid(record.id, "terminal identity does not match the active row")
        }
        if let parsedResult = record.parsedResult {
            try validate(parsedResult, id: record.id)
        }

        let terminalColumns = terminalColumns(record.terminal)
        var review = existing
        review.phase = "terminal"
        review.terminalModel = record.model
        review.terminalKind = terminalColumns.kind
        review.interruptionKind = terminalColumns.interruptionKind
        review.cancellationSource = terminalColumns.cancellation?.source.rawValue
        review.cancellationMessage = terminalColumns.cancellation?.message
        review.terminalMessage = terminalColumns.message
        if let endedAt = record.endedAt {
            review.endedAt = ReviewHistoryTimestamp.encode(endedAt)
        } else {
            review.endedAt = nil
        }
        review.summary = record.summary
        review.canonicalReview = record.canonicalReview
        review.parsedState = record.parsedResult?.state.rawValue
        review.parsedFindingCount = record.parsedResult?.findingCount
        review.parsedSource = record.parsedResult?.source.rawValue
        review.parserVersion = record.parsedResult?.parserVersion
        review.terminalCommittedAt = ReviewHistoryTimestamp.encode(terminalCommittedAt)
        review.updatedAt = ReviewHistoryTimestamp.encode(updatedAt)

        let findings = try record.parsedResult?.findings.map {
            try encode($0, reviewID: record.id)
        } ?? []
        return EncodedTerminalReview(review: review, findings: findings)
    }

    static func decode(
        _ row: ReviewRecordRow,
        workspace: ReviewWorkspaceRow,
        findings: [ReviewFindingRow]
    ) throws -> DecodedReviewHistoryRow {
        switch row.phase {
        case "active":
            guard findings.isEmpty else {
                throw invalid(row.id, "active row contains terminal findings")
            }
            return .active(try decodeStarted(row, workspace: workspace))
        case "terminal":
            return .terminal(try decodeRestored(
                row,
                workspace: workspace,
                findings: findings
            ))
        default:
            throw invalid(row.id, "unknown persistence phase \(row.phase)")
        }
    }

    static func decodeStarted(
        _ row: ReviewRecordRow,
        workspace: ReviewWorkspaceRow
    ) throws -> StartedReviewRecord {
        guard row.cwd == workspace.cwd else {
            throw invalid(row.id, "workspace foreign key does not match loaded workspace")
        }
        let target = try decodeTarget(row)
        let started: StartedReviewRecord
        do {
            started = try StartedReviewRecord(
                id: row.id,
                cwd: row.cwd,
                workspaceSortOrder: workspace.sortOrder,
                sortOrder: row.sortOrder,
                target: target,
                model: row.startedModel,
                startedAt: ReviewHistoryTimestamp.decode(row.startedAt)
            )
        } catch {
            throw invalid(row.id, error.localizedDescription)
        }
        guard started.model == row.startedModel else {
            throw invalid(row.id, "started model is not canonical")
        }

        if row.phase == "active" {
            let reencoded = try encodeStarted(
                started,
                createdAt: ReviewHistoryTimestamp.decode(row.createdAt),
                updatedAt: ReviewHistoryTimestamp.decode(row.updatedAt)
            )
            guard reencoded.workspace == workspace, reencoded.review == row else {
                throw invalid(row.id, "active storage columns are not canonical")
            }
        }
        return started
    }

    static func decodeTarget(_ row: ReviewRecordRow) throws -> CodexReviewAPI.Target {
        let target: CodexReviewAPI.Target
        switch row.targetKind {
        case "uncommittedChanges":
            guard row.targetBranch == nil,
                  row.targetCommitSHA == nil,
                  row.targetCommitTitle == nil,
                  row.targetInstructions == nil
            else {
                throw invalid(row.id, "uncommitted target contains variant payload")
            }
            target = .uncommittedChanges
        case "baseBranch":
            guard let branch = row.targetBranch,
                  row.targetCommitSHA == nil,
                  row.targetCommitTitle == nil,
                  row.targetInstructions == nil
            else {
                throw invalid(row.id, "base-branch target payload is incompatible")
            }
            target = .baseBranch(branch)
        case "commit":
            guard row.targetBranch == nil,
                  let sha = row.targetCommitSHA,
                  row.targetInstructions == nil
            else {
                throw invalid(row.id, "commit target payload is incompatible")
            }
            target = .commit(sha: sha, title: row.targetCommitTitle)
        case "custom":
            guard row.targetBranch == nil,
                  row.targetCommitSHA == nil,
                  row.targetCommitTitle == nil,
                  let instructions = row.targetInstructions
            else {
                throw invalid(row.id, "custom target payload is incompatible")
            }
            target = .custom(instructions: instructions)
        default:
            throw invalid(row.id, "unknown target kind \(row.targetKind)")
        }
        return try validatedTarget(target, id: row.id)
    }

    private static func decodeRestored(
        _ row: ReviewRecordRow,
        workspace: ReviewWorkspaceRow,
        findings: [ReviewFindingRow]
    ) throws -> RestoredReviewRecord {
        guard let terminalCommittedAt = row.terminalCommittedAt else {
            throw invalid(row.id, "terminal row is missing its commit timestamp")
        }
        let started = try decodeStarted(row, workspace: workspace)
        let terminalValue = try decodeTerminal(row)
        let parsedResult = try decodeParsedResult(row, findings: findings)
        let terminal: TerminalReviewRecord
        do {
            terminal = try TerminalReviewRecord(
                id: row.id,
                model: row.terminalModel,
                terminal: terminalValue,
                endedAt: row.endedAt.map(ReviewHistoryTimestamp.decode),
                summary: row.summary ?? "",
                canonicalReview: row.canonicalReview,
                parsedResult: parsedResult
            )
        } catch {
            throw invalid(row.id, error.localizedDescription)
        }
        let restored: RestoredReviewRecord
        do {
            restored = try RestoredReviewRecord(started: started, terminal: terminal)
        } catch {
            throw invalid(row.id, error.localizedDescription)
        }

        let reencoded = try encodeTerminal(
            terminal,
            replacing: row,
            terminalCommittedAt: ReviewHistoryTimestamp.decode(terminalCommittedAt),
            updatedAt: ReviewHistoryTimestamp.decode(row.updatedAt)
        )
        guard reencoded.review == row,
              reencoded.findings.sorted(by: { $0.ordinal < $1.ordinal })
                == findings.sorted(by: { $0.ordinal < $1.ordinal })
        else {
            throw invalid(row.id, "terminal storage columns are not canonical")
        }
        return restored
    }

    private static func decodeTerminal(_ row: ReviewRecordRow) throws -> ReviewTerminalRecord {
        guard let terminalKind = row.terminalKind else {
            throw invalid(row.id, "terminal row is missing its typed terminal")
        }
        switch terminalKind {
        case ReviewTerminalKind.completed.rawValue:
            return .completed
        case ReviewTerminalKind.failed.rawValue:
            return .failed(message: row.terminalMessage)
        case ReviewTerminalKind.interrupted.rawValue:
            switch row.interruptionKind {
            case "requested":
                guard let sourceValue = row.cancellationSource,
                      let source = ReviewCancellation.Source(rawValue: sourceValue),
                      let message = row.cancellationMessage
                else {
                    throw invalid(row.id, "requested interruption is missing cancellation payload")
                }
                return .interrupted(.requested(.init(source: source, message: message)))
            case "server":
                return .interrupted(.server(message: row.terminalMessage))
            case "transport":
                guard let message = row.terminalMessage else {
                    throw invalid(row.id, "transport interruption is missing its message")
                }
                return .interrupted(.transport(message: message))
            case "previousProcessExit":
                return .interrupted(.previousProcessExit)
            case .some(let value):
                throw invalid(row.id, "unknown interruption kind \(value)")
            case nil:
                throw invalid(row.id, "interrupted terminal is missing its cause")
            }
        default:
            throw invalid(row.id, "unknown terminal kind \(terminalKind)")
        }
    }

    private static func decodeParsedResult(
        _ row: ReviewRecordRow,
        findings: [ReviewFindingRow]
    ) throws -> PersistedParsedReviewResult? {
        guard let stateValue = row.parsedState else {
            guard row.parsedFindingCount == nil,
                  row.parsedSource == nil,
                  row.parserVersion == nil,
                  findings.isEmpty
            else {
                throw invalid(row.id, "finding rows exist without parsed-result metadata")
            }
            return nil
        }
        guard let state = ParsedReviewResult.State(rawValue: stateValue),
              let sourceValue = row.parsedSource,
              let source = ParsedReviewResult.Source(rawValue: sourceValue),
              let parserVersion = row.parserVersion
        else {
            throw invalid(row.id, "parsed-result metadata contains an unknown value")
        }

        let orderedFindings = findings.sorted { $0.ordinal < $1.ordinal }
        let decodedFindings = try orderedFindings.map { finding in
            let location: ParsedReviewResult.Finding.Location?
            switch (finding.path, finding.startLine, finding.endLine) {
            case (nil, nil, nil):
                location = nil
            case let (path?, startLine?, endLine?):
                location = .init(path: path, startLine: startLine, endLine: endLine)
            default:
                throw invalid(row.id, "finding location columns are incomplete")
            }
            return PersistedParsedReviewResult.Finding(
                ordinal: finding.ordinal,
                title: finding.title,
                body: finding.body,
                priority: finding.priority,
                location: location
            )
        }
        let result: PersistedParsedReviewResult
        do {
            result = try PersistedParsedReviewResult(
                state: state,
                findingCount: row.parsedFindingCount,
                findings: decodedFindings,
                source: source,
                parserVersion: parserVersion
            )
        } catch {
            throw invalid(row.id, error.localizedDescription)
        }
        try validate(result, id: row.id)
        for finding in orderedFindings {
            guard finding.id == stableFindingID(
                reviewID: row.id,
                ordinal: finding.ordinal
            ), finding.reviewID == row.id else {
                throw invalid(row.id, "finding identity is not canonical")
            }
        }
        return result
    }

    private static func validate(
        _ parsedResult: PersistedParsedReviewResult,
        id: String
    ) throws {
        guard parsedResult.parserVersion > 0 else {
            throw invalid(id, "parser version must be positive")
        }
        switch (parsedResult.state, parsedResult.source) {
        case (.hasFindings, .parsedFinalReviewText):
            guard parsedResult.findings.isEmpty == false,
                  parsedResult.findingCount == parsedResult.findings.count
            else {
                throw invalid(id, "finding projection count is inconsistent")
            }
        case (.noFindings, .parsedFinalReviewText):
            guard parsedResult.findings.isEmpty, parsedResult.findingCount == 0 else {
                throw invalid(id, "no-findings projection contains findings")
            }
        case (.unknown, .unrecognizedFindingBlock), (.unknown, .notAvailable):
            guard parsedResult.findings.isEmpty, parsedResult.findingCount == nil else {
                throw invalid(id, "unknown parsed projection contains findings")
            }
        default:
            throw invalid(id, "parsed state and source are incompatible")
        }
    }

    private static func encode(
        _ finding: PersistedParsedReviewResult.Finding,
        reviewID: String
    ) throws -> ReviewFindingRow {
        guard finding.title.nilIfEmpty != nil else {
            throw invalid(reviewID, "finding \(finding.ordinal) has an empty title")
        }
        if let priority = finding.priority, (0...3).contains(priority) == false {
            throw invalid(reviewID, "finding \(finding.ordinal) has an invalid priority")
        }
        if let location = finding.location {
            guard location.path.nilIfEmpty != nil,
                  location.startLine > 0,
                  location.endLine >= location.startLine
            else {
                throw invalid(reviewID, "finding \(finding.ordinal) has an invalid location")
            }
        }
        return ReviewFindingRow(
            id: stableFindingID(reviewID: reviewID, ordinal: finding.ordinal),
            reviewID: reviewID,
            ordinal: finding.ordinal,
            priority: finding.priority,
            title: finding.title,
            body: finding.body,
            path: finding.location?.path,
            startLine: finding.location?.startLine,
            endLine: finding.location?.endLine
        )
    }

    private static func validatedTarget(
        _ target: CodexReviewAPI.Target,
        id: String
    ) throws -> CodexReviewAPI.Target {
        do {
            guard try target.validated() == target else {
                throw invalid(id, "target payload is not canonical")
            }
        } catch let error as ReviewHistoryDatabaseError {
            throw error
        } catch {
            throw invalid(id, "target payload failed validation: \(error.localizedDescription)")
        }
        return target
    }

    private static func targetColumns(
        _ target: CodexReviewAPI.Target
    ) -> (kind: String, branch: String?, commitSHA: String?, commitTitle: String?, instructions: String?) {
        switch target {
        case .uncommittedChanges:
            ("uncommittedChanges", nil, nil, nil, nil)
        case .baseBranch(let branch):
            ("baseBranch", branch, nil, nil, nil)
        case .commit(let sha, let title):
            ("commit", nil, sha, title, nil)
        case .custom(let instructions):
            ("custom", nil, nil, nil, instructions)
        }
    }

    private static func terminalColumns(
        _ terminal: ReviewTerminalRecord
    ) -> (kind: String, interruptionKind: String?, message: String?, cancellation: ReviewCancellation?) {
        switch terminal {
        case .completed:
            (ReviewTerminalKind.completed.rawValue, nil, nil, nil)
        case .failed(let message):
            (ReviewTerminalKind.failed.rawValue, nil, message, nil)
        case .interrupted(.requested(let cancellation)):
            (ReviewTerminalKind.interrupted.rawValue, "requested", nil, cancellation)
        case .interrupted(.server(let message)):
            (ReviewTerminalKind.interrupted.rawValue, "server", message, nil)
        case .interrupted(.transport(let message)):
            (ReviewTerminalKind.interrupted.rawValue, "transport", message, nil)
        case .interrupted(.previousProcessExit):
            (ReviewTerminalKind.interrupted.rawValue, "previousProcessExit", nil, nil)
        }
    }

    private static func stableFindingID(reviewID: String, ordinal: Int) -> String {
        "\(reviewID.utf8.count):\(reviewID):\(ordinal)"
    }

    private static func invalid(
        _ id: String,
        _ reason: String
    ) -> ReviewHistoryDatabaseError {
        .invalidRecord(id: id, reason: reason)
    }
}
